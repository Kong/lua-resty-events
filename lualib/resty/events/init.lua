local callback  = require "resty.events.callback"
local broker    = require "resty.events.broker"
local worker    = require "resty.events.worker"

local _M = {
    _VERSION = '0.1.0',
}

function _M.configure(opts)
    local ok, err = broker.configure(opts)
    if not ok then
      return nil, err
    end

    return worker.configure(opts)
end

_M.run = broker.run

_M.post = worker.post
_M.post_local = worker.post_local
_M.poll = worker.poll

_M.register = callback.register
_M.register_weak = callback.register_weak
_M.unregister = callback.unregister

return _M
