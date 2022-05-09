-- compatible with lua-resty-worker-events 1.0.0

local ev

local ipairs = ipairs
local ngx = ngx
local log = ngx.log
local DEBUG = ngx.DEBUG
local sleep = ngx.sleep

-- store id for unsubscribe
local handlers = {}

local _configured

local _M = {
    _VERSION = '0.1.0',
}

function _M.poll()
    sleep(0.002) -- wait events sync by unix socket connect

    log(DEBUG, "worker-events: emulate poll method")

    return "done"
end

function _M.configure(opts)
    local ok, err

    ev = require("resty.events").new(opts)

    ok, err = ev:init_worker()

    if not ok then
        return nil, err
    end

    _configured = true

    return true
end

function _M.configured()
    return _configured
end

function _M.run()
    return ev:run()
end

_M.post = function(source, event, data, unique)
    local ok, err = ev:publish(unique or "all", source, event, data)

    if not ok then
        return nil, err
    end

    return "done"
end

_M.post_local = function(source, event, data)
    local ok, err = ev:publish("current", source, event, data)

    if not ok then
        return nil, err
    end

    return "done"
end

_M.register = function(callback, source, event, ...)
    local events = {event or "*", ...}

    for _, e in ipairs(events) do
        local id = ev:subscribe(source or "*", e or "*", callback)

        handlers[callback] = id
    end
end

_M.register_weak = _M.register

_M.unregister = function(callback, source, ...)
    local id = handlers[callback]

    if not id then
        return
    end

    handlers[callback] = nil

    return ev:unsubscribe(id)
end

return _M
