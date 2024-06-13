-- compatible with lua-resty-worker-events 1.0.0
local events = require("resty.events")


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
    _VERSION = events._VERSION,
}


function _M.poll()
    sleep(0.002) -- wait events sync by unix socket connect

    log(DEBUG, "worker-events: emulate poll method")

    return "done"
end


function _M.configure(opts)
    ev = events.new(opts)

    local ok, err = ev:init_worker()
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


function _M.post(source, event, data, unique)
    local ok, err = ev:publish(unique or "all", source, event, data)
    if not ok then
        return nil, err
    end

    return "done"
end


function _M.post_local(source, event, data)
    local ok, err = ev:publish("current", source, event, data)
    if not ok then
        return nil, err
    end

    return "done"
end


function _M.register(callback, source, event, ...)
    local events = {event or "*", ...}
    for _, e in ipairs(events) do
        local id = ev:subscribe(source or "*", e or "*", callback)
        handlers[callback] = id
    end
end
_M.register_weak = _M.register


function _M.unregister(callback)
    local id = handlers[callback]
    if not id then
        return
    end

    handlers[callback] = nil

    return ev:unsubscribe(id)
end


return _M
