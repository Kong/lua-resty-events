local cjson = require "cjson.safe"
local codec = require "resty.events.codec"
local que = require "resty.events.queue"
local callback = require "resty.events.callback"

local client = require("resty.events.protocol").client
local is_timeout = client.is_timeout

local type = type
local assert = assert
local setmetatable = setmetatable
local random = math.random

local ngx = ngx
local log = ngx.log
local sleep = ngx.sleep
local exiting = ngx.worker.exiting
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG

local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local wait = ngx.thread.wait

local timer_at = ngx.timer.at

local encode = codec.encode
local decode = codec.decode
local cjson_encode = cjson.encode

local EVENTS_COUNT_LIMIT = 100
local EVENTS_SLEEP_TIME  = 0.05

local EMPTY_T = {}

local EVENT_T = {
    source = '',
    event = '',
    data = '',
    wid = '',
}

local SPEC_T = {
    unique = '',
}

local PAYLOAD_T = {
    spec = EMPTY_T,
    data = '',
}

--local _worker_pid = ngx.worker.pid()
local _worker_id = ngx.worker.id() or -1

local _M = {
    _VERSION = '0.1.4',
}
local _MT = { __index = _M, }

-- gen a random number [0.1, 1.0]
local function random_delay()
    return random(1, 10) / 10
end

local function do_event(self, d)
    self._callback:do_event(d)
end

local function start_timer(self, delay)
    assert(timer_at(delay, function(premature)
        self:communicate(premature)
    end))
end

local check_sock_exist
do
    local ffi = require "ffi"
    local C = ffi.C
    ffi.cdef [[
    int access(const char *pathname, int mode);
    ]]

    -- remove prefix 'unix:'
    check_sock_exist = function(fpath)
        local rc = C.access(fpath:sub(6), 0)
        return rc == 0
    end
end

function _M.new(opts)
    local max_queue_len = opts.max_queue_len

    local self = {
        _pub_queue = que.new(max_queue_len),
        _sub_queue = que.new(max_queue_len),
        _callback = callback.new(),
        _connected = nil,
        _opts = opts,
    }

    return setmetatable(self, _MT)
end

function _M:communicate(premature)
    if premature then
        -- worker wants to exit
        return
    end

    local listening
    local conn
    local ok, err, perr
    local write_thread, read_thread, events_thread

    if self._opts.testing == true then
        self._connected = true
        goto local_events_only
    end

    listening = self._opts.listening

    if not check_sock_exist(listening) then
        log(DEBUG, "unix domain sock(", listening, ") is not ready")

        -- try to reconnect broker, avoid crit error log
        start_timer(self, 0.002)
        return
    end

    conn = assert(client:new())

    ok, err = conn:connect(listening)
    if not ok then
        log(ERR, "failed to connect: ", err)

        -- try to reconnect broker
        start_timer(self, random_delay())

        return
    end

    self._connected = true
    log(DEBUG, _worker_id, " on (", listening, ") is ready")

    read_thread = spawn(function()
        while not exiting() do
            local data, err = conn:recv_frame()

            if err then
                if not is_timeout(err) then
                    return nil, err
                end

                -- timeout
                goto continue
            end

            if not data then
                return nil, "did not receive event from broker"
            end

            if exiting() then
                return
            end

            local d, err = decode(data)
            if not d then
                return nil, "failed to decode event data: " .. err
            end

            -- got an event data, push to queue, callback in events_thread
            local ok, err = self._sub_queue:push(d)
            if not ok then
                log(ERR, "failed to store event: ", err, ". ",
                         "data is :", cjson_encode(d))
            end

            ::continue::
        end -- while not exiting
    end)  -- read_thread

    write_thread = spawn(function()
        local counter = 0

        while not exiting() do
            local payload, err = self._pub_queue:pop()

            if not payload then
                if not is_timeout(err) then
                    return nil, "semaphore wait error: " .. err
                end

                -- timeout
                goto continue
            end

            if exiting() then
                return
            end

            local _, err = conn:send_frame(payload)
            if err then
                log(ERR, "failed to send event: ", err)
                return
            end

            -- events rate limiting
            counter = counter + 1
            if counter >= EVENTS_COUNT_LIMIT then
                sleep(EVENTS_SLEEP_TIME)
                counter = 0
            end

            ::continue::
        end -- while not exiting
    end)  -- write_thread

    ::local_events_only::

    events_thread = spawn(function()
        while not exiting() do
            local data, err = self._sub_queue:pop()

            if not data then
                if not is_timeout(err) then
                    return nil, "semaphore wait error: " .. err
                end

                -- timeout
                goto continue
            end

            if exiting() then
                return
            end

            -- got an event data, callback
            do_event(self, data)

            -- yield, not block other threads
            sleep(0)

            ::continue::
        end -- while not exiting
    end)  -- events_thread

    if write_thread and read_thread then
        ok, err, perr = wait(write_thread, read_thread, events_thread)

        kill(write_thread)
        kill(read_thread)
    else

        ok, err, perr = wait(events_thread)
    end

    kill(events_thread)

    self._connected = nil

    if not ok then
        log(ERR, "event worker failed: ", err)
    end

    if perr then
        log(ERR, "event worker failed: ", perr)
    end

    if not exiting() then
        start_timer(self, random_delay())
    end
end

function _M:init()
    assert(self._opts)

    start_timer(self, 0)

    return true
end

-- posts a new event
local function post_event(self, source, event, data, spec)
    local str, err

    EVENT_T.source = source
    EVENT_T.event = event
    EVENT_T.data = data
    EVENT_T.wid = _worker_id

    -- encode event info
    str, err = encode(EVENT_T)

    if not str then
        return nil, err
    end

    PAYLOAD_T.spec = spec or EMPTY_T
    PAYLOAD_T.data = str

    -- encode spec info
    str, err = encode(PAYLOAD_T)

    if not str then
        return nil, err
    end

    local ok, err = self._pub_queue:push(str)
    if not ok then
        return nil, "failed to publish event: " .. err
    end

    return true
end

function _M:publish(target, source, event, data)
    local ok, err

    -- if not self._connected then
    --     return nil, "not initialized yet"
    -- end

    assert(type(target) == "string" and target ~= "", "target is required")
    assert(type(source) == "string" and source ~= "", "source is required")
    assert(type(event) == "string" and event ~= "", "event is required")

    -- fall back to local events
    if self._opts.testing == true then
        target = "current"
    end

    if target == "current" then
        ok, err = self._sub_queue:push({
            source = source,
            event = event,
            data = data,
        })

        log(DEBUG, "event published to 1 workers")
    else
        -- add unique hash string
        SPEC_T.unique = target ~= "all" and target or nil

        ok, err = post_event(self, source, event, data, SPEC_T)
    end

    if not ok then
        return nil, "failed to publish event: " .. err
    end

    return true
end

function _M:subscribe(source, event, callback)
    assert(type(source) == "string" and source ~= "", "source is required")
    assert(type(event) == "string" and event ~= "", "event is required")
    assert(type(callback) == "function", "expected function, got: "..
           type(callback))

    return self._callback:subscribe(source, event, callback)
end

function _M:unsubscribe(id)
    assert(type(id) == "string" and id ~= "", "id is required")

    return self._callback:unsubscribe(id)
end

function _M:is_ready()
    return self._connected
end

return _M
