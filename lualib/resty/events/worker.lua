local cjson = require "cjson.safe"
local codec = require "resty.events.codec"
local queue = require "resty.events.queue"
local callback = require "resty.events.callback"

local frame_validate = require("resty.events.frame").validate
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
    _VERSION = '0.2.0',
}
local _MT = { __index = _M, }

-- gen a random number [0.01, 0.05]
-- it means that delay will be 10ms~50ms
local function random_delay()
    return random(10, 50) / 1000
end

local function communicate(premature, self)
    if premature then
        return
    end

    self:communicate()
end

local function start_timer(self, delay)
    assert(timer_at(delay, communicate, self))
end

local function terminating(self)
    return not self._connected or exiting()
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
        _pub_queue = queue.new(max_queue_len),
        _sub_queue = queue.new(max_queue_len),
        _callback = callback.new(),
        _connected = nil,
        _opts = opts,
    }

    return setmetatable(self, _MT)
end

local function read_thread(self, broker_connection)
    while not terminating(self) do
        local data, err = broker_connection:recv_frame()
        if err then
            if not is_timeout(err) then
                return nil, "failed to read event: " .. err
            end

            -- timeout
            goto continue
        end

        if not data then
            if not exiting() then
                log(ERR, "did not receive event from broker")
            end
            goto continue
        end

        local event_data, err = decode(data)
        if err then
            if not exiting() then
                log(ERR, "failed to decode event data: ", err)
            end
            goto continue
        end

        -- got an event data, push to queue, callback in events_thread
        local _, err = self._sub_queue:push(event_data)
        if err then
            if not exiting() then
                log(ERR, "failed to store event: ", err, ". data is: ",
                         cjson_encode(event_data))
            end
            goto continue
        end

        ::continue::
    end -- while not terminating

    return true
end

local function write_thread(self, broker_connection)
    local counter = 0

    while not terminating(self) do
        local payload, err = self._pub_queue:pop()
        if err then
            if not is_timeout(err) then
                return nil, "semaphore wait error: " .. err
            end

            -- timeout
            goto continue
        end

        local _, err = broker_connection:send_frame(payload)
        if err then
            return nil, "failed to send event: " .. err
        end

        -- events rate limiting
        counter = counter + 1
        if counter >= EVENTS_COUNT_LIMIT then
            sleep(EVENTS_SLEEP_TIME)
            counter = 0
        end

        ::continue::
    end -- while not terminating

    return true
end

local function events_thread(self)
    while not terminating(self) do
        local data, err = self._sub_queue:pop()
        if err then
            if not is_timeout(err) then
                return nil, "semaphore wait error: " .. err
            end

            -- timeout
            goto continue
        end

        -- got an event data, callback
        self._callback:do_event(data)

        -- yield, not block other threads
        sleep(0)

        ::continue::
    end -- while not terminating

    return true
end

function _M:communicate()
    -- only for testing, skip read/write/events threads
    if self._opts.testing == true then
        self._connected = true
        return
    end

    local listening = self._opts.listening

    if not check_sock_exist(listening) then
        log(DEBUG, "unix domain sock(", listening, ") is not ready")

        -- try to reconnect broker, avoid crit error log
        start_timer(self, 0.002)
        return
    end

    local broker_connection = assert(client.new())

    local ok, err = broker_connection:connect(listening)

    if exiting() then
        return
    end

    if not ok then
        log(ERR, "failed to connect: ", err)

        -- try to reconnect broker
        start_timer(self, random_delay())

        return
    end

    log(DEBUG, _worker_id, " on (", listening, ") is ready")

    self._connected = true

    local read_thread_co = spawn(read_thread, self, broker_connection)
    local write_thread_co = spawn(write_thread, self, broker_connection)
    local events_thread_co = spawn(events_thread, self)

    local ok, err, perr = wait(read_thread_co, write_thread_co, events_thread_co)

    self._connected = nil

    if exiting() then
        kill(read_thread_co)
        kill(write_thread_co)
        kill(events_thread_co)
        return
    end

    if not ok then
        log(ERR, "event worker failed: ", err)
    end

    if perr then
        log(ERR, "event worker failed: ", perr)
    end

    wait(read_thread_co)
    wait(write_thread_co)
    wait(events_thread_co)

    start_timer(self, random_delay())
end

function _M:init()
    assert(self._opts)

    start_timer(self, 0)

    return true
end

-- posts a new event
local function post_event(self, source, event, data, spec)
    local str, ok, len, err

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

    len, err = frame_validate(str)
    if not len then
        return nil, err
    end
    if len > self._opts.max_payload_len then
        return nil, "payload exceeds the limitation " ..
                    "(" .. self._opts.max_payload_len .. ")"
    end

    ok, err = self._pub_queue:push(str)
    if not ok then
        return nil, err
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
        log(DEBUG, "event published to 1 workers")

        self._callback:do_event({
            source = source,
            event = event,
            data = data,
        })

        return true
    end

    if target == "current" then
        ok, err = self._sub_queue:push({
            source = source,
            event = event,
            data = data,
        })

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
    assert(type(callback) == "function", "expected function, got: " ..
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
