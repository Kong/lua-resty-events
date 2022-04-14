local events_broker = require "resty.events.broker"
local events_worker = require "resty.events.worker"

local disable_listening = require "resty.events.disable_listening"

local ngx = ngx
local type = type
local setmetatable = setmetatable
local str_sub = string.sub

local worker_id = ngx.worker.id()
local worker_count = ngx.worker.count()

local _M = {
    _VERSION = '0.1.0',
}
local _MT = { __index = _M, }

function _M.new()
    local self = {
        broker = events_broker.new(),
        worker = events_worker.new(),
    }

    return setmetatable(self, _MT)
end

-- opts = {broker_id = n, listening = 'unix:...', unique_timeout = x,}
function _M:configure(opts)
    assert(type(opts) == "table", "Expected a table, got " .. type(opts))

    local UNIX_PREFIX = "unix:"
    local DEFAULT_UNIQUE_TIMEOUT = 5

    opts.broker_id = opts.broker_id or 0

    if type(opts.broker_id) ~= "number" then
        return nil, '"worker_id" option must be a number'
    end

    if opts.broker_id < 0 or opts.broker_id >= worker_count then
        return nil, '"worker_id" option is invalid'
    end

    if not opts.listening then
        return nil, '"listening" option required to start'
    end

    if type(opts.listening) ~= "string" then
        return nil, '"listening" option must be a string'
    end

    if str_sub(opts.listening, 1, #UNIX_PREFIX) ~= UNIX_PREFIX then
        return nil, '"listening" option must start with ' .. UNIX_PREFIX
    end

    opts.unique_timeout = opts.unique_timeout or DEFAULT_UNIQUE_TIMEOUT

    if type(opts.unique_timeout) ~= "number" then
        return nil, 'optional "unique_timeout" option must be a number'
    end

    if opts.unique_timeout <= 0 then
        return nil, '"unique_timeout" must be greater than 0'
    end

    local is_broker = worker_id == opts.broker_id

    local ok, err

    -- only enable listening on special worker id
    if is_broker then
        ok, err = self.broker:configure(opts)

    else
        ok, err = disable_listening(opts.listening)
    end

    if not ok then
        return nil, err
    end

    ok, err = self.worker:configure(opts)
    if not ok then
        return nil, err
    end

    return true
end

function _M:run()
    return self.broker:run()
end

function _M:publish(target, source, event, data)
    return self.worker:publish(target, source, event, data)
end

function _M:subscribe(source, event, callback)
    return self.worker:subscribe(source, event, callback)
end

function _M:unsubscribe(id)
    return self.worker:unsubscribe(id)
end

return _M
