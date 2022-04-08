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

_M.post          = events.post
_M.post_local    = events.post_local

_M.register      = callback.register
_M.register_weak = callback.register_weak
_M.unregister    = callback.unregister

return _M
