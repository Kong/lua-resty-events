-- compatible with lua-resty-worker-events

local ev = require("resty.events").new()

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
    return ev:publish(unique or "all", source, event, data)
end

_M.post_local = function(source, event, data)
    return ev:publish("current", source, event, data)
end

_M.register = function(callback, source, event, ...)
    return ev:subscribe(source or "*", event or "*", callback)
end

_M.register_weak = _M.register

_M.unregister = function(callback, source, ...)
end

return _M
