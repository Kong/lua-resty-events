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
local exiting = ngx.worker.exiting
local ERR = ngx.ERR
--local DEBUG = ngx.DEBUG

local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local wait = ngx.thread.wait

local timer_at = ngx.timer.at

local encode = codec.encode
local decode = codec.decode

local EMPTY_T = {}

local EVENT_T = {
    source = '',
    event = '',
    data = '',
    pid = '',
}

local SPEC_T = {
    unique = '',
}

local PAYLOAD_T = {
    spec = EMPTY_T,
    data = '',
}

local _worker_pid = ngx.worker.pid()

local _M = {
    _VERSION = '0.1.0',
}
local _MT = { __index = _M, }

-- gen a random number [0.2, 2.0]
local function random_delay()
    return random(2, 20) / 10
end

local function do_event(self, d)
    self._callback:do_event(d)
end

local function start_timer(self, delay)
    assert(timer_at(delay, function(premature)
        self:communicate(premature)
    end))
end

function _M.new()
    local self = {
        _queue = que.new(),
        _local_queue = que.new(),
        _callback = callback.new(),
        _connected = nil,
        _opts = nil,
    }

    return setmetatable(self, _MT)
end

function _M:communicate(premature)
    if premature then
        -- worker wants to exit
        return
    end

    local conn = assert(client:new())

    local ok, err = conn:connect(self._opts.listening)
    if not ok then
        log(ERR, "failed to connect: ", err)

        -- try to reconnect broker
        start_timer(self, random_delay())

        return
    end

    self._connected = true

    local read_thread = spawn(function()
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
                return nil, "worker-events: failed decoding event data: " .. err
            end

            -- got an event data, callback
            do_event(self, d)

            ::continue::
        end -- while not exiting
    end)  -- read_thread

    local write_thread = spawn(function()
        while not exiting() do
            local payload, err = self._queue:pop()

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

            ::continue::
        end -- while not exiting
    end)  -- write_thread

    local local_thread = spawn(function()
        while not exiting() do
            local data, err = self._local_queue:pop()

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

            ::continue::
        end -- while not exiting
    end)  -- local_thread

    local ok, err, perr = wait(write_thread, read_thread, local_thread)

    kill(write_thread)
    kill(read_thread)
    kill(local_thread)

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

function _M:configure(opts)
    assert(not self._opts)

    self._opts = opts

    start_timer(self, 0)

    return true
end

-- posts a new event
local function post_event(self, source, event, data, spec)
    local str, err

    EVENT_T.source = source
    EVENT_T.event = event
    EVENT_T.data = data
    EVENT_T.pid = _worker_pid

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

    local ok, err = self._queue:push(str)
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

    if type(target) ~= "string" or target == "" then
        return nil, "target is required"
    end

    if type(source) ~= "string" or source == "" then
        return nil, "source is required"
    end

    if type(event) ~= "string" or event == "" then
        return nil, "event is required"
    end

    if target == "current" then
        ok, err = self._local_queue:push({
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
    if type(source) ~= "string" or source == "" then
        return nil, "source is required"
    end

    if type(event) ~= "string" or event == "" then
        return nil, "event is required"
    end

    assert(type(callback) == "function", "expected function, got: "..
           type(callback))

    return self._callback:subscribe(source, event, callback)
end

function _M:unsubscribe(id)
    if type(id) ~= "string" or id == "" then
        return nil, "id is required"
    end

    return self._callback:unsubscribe(id)
end

function _M:is_ready()
    return self._connected
end

return _M
