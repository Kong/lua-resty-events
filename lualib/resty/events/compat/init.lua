-- compatible with lua-resty-worker-events 1.0.0

local ev = require("resty.events").new()

-- store id for unsubscribe
local handlers = {}

local _M = {
    _VERSION = '0.1.0',
}

function _M.poll()
    return "done"
end

function _M.configure(opts)
    return ev:configure(opts)
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
