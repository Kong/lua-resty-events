require "resty.core.base"

local broker    = require "resty.events.broker"
local worker    = require("resty.events.worker").new()

local ngx = ngx
local type = type
local str_sub = string.sub

local _M = {
    _VERSION = '0.1.0',
}

local disable_listening
do
    local ffi = require "ffi"
    local C = ffi.C

    local NGX_OK = ngx.OK

    ffi.cdef[[
        int ngx_lua_ffi_disable_listening_unix_socket(ngx_str_t *sock_name);
    ]]

    local sock_name_str = ffi.new("ngx_str_t[1]")

    disable_listening = function(sock_name)
        sock_name_str[0].data = sock_name
        sock_name_str[0].len = #sock_name

        local rc = C.ngx_lua_ffi_disable_listening_unix_socket(sock_name_str)

        if rc ~= NGX_OK then
            return nil, "failed to disable listening: " .. sock_name
        end

        return true
    end
end

-- opts = {broker_id = n, listening = 'unix:...', unique_timeout = x,}
function _M.configure(opts)
    assert(type(opts) == "table", "Expected a table, got " .. type(opts))

    local UNIX_PREFIX = "unix:"
    local DEFAULT_UNIQUE_TIMEOUT = 5

    local worker_id = ngx.worker.id()
    local worker_count = ngx.worker.count()

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
        ok, err = broker.configure(opts)

    else
        ok, err = disable_listening(opts.listening)
    end

    if not ok then
        return nil, err
    end

    ok, err = worker:configure(opts)
    if not ok then
        return nil, err
    end

    return true
end

_M.run          = broker.run

--_M.publish      = worker.publish

--_M.subscribe    = worker.subscribe
--_M.unsubscribe  = worker.unsubscribe

function _M.publish(target, source, event, data)
    return worker:publish(target, source, event, data)
end

function _M.subscribe(source, event, callback)
    return worker:subscribe(source, event, callback)
end

function _M.unsubscribe(source, event, id)
    return worker:unsubscribe(source, event, id)
end
-- for test only
_M.disable_listening = disable_listening

return _M
