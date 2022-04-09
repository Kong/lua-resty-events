-- compatible with lua-resty-worker-events

local events = require "resty.events"

local _M = {
    _VERSION = '0.1.0',
}

function _M.poll()
    return "done"
end

_M.configure     = events.configure
_M.run           = events.run

_M.post = function(source, event, data, unique)
    return events.publish(unique or "all", source, event, data)
end

_M.post_local = function(source, event, data)
    return events.publish("current", source, event, data)
end

_M.register = function(callback, source, event, ...)
    return events.subscribe(source or "*", event or "*", callback)
end

_M.register_weak = _M.register

_M.unregister = function(callback, source, ...)
end

return _M
