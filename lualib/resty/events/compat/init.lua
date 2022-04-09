local events = require "resty.events"
local callback = require "resty.events.compat.callback"

local _M = {
    _VERSION = '0.1.0',
}

-- compatible with lua-resty-worker-events
function _M.poll()
    return "done"
end

_M.configure     = events.configure
_M.run           = events.run

--_M.post          = events.post
_M.post = function(source, event, data, unique)
    return events.publish(unique or "all", source, event, data)
end

--_M.post_local    = events.post_local
_M.post_local = function(source, event, data)
    return events.publish("current", source, event, data)
end

-- only for test
_M.register = function(callback, source, event, ...)
    return events.subscribe(source or "*", event or "*", callback)
end

--_M.register_weak = callback.register_weak

-- only for test
_M.unregister = function(callback, source, ...)
end

return _M
