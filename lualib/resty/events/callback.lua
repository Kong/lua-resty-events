local cjson = require "cjson.safe"

local xpcall = xpcall
local type = type
local pairs = pairs
local assert = assert
local tostring = tostring
local setmetatable = setmetatable
local traceback = debug.traceback

local ngx = ngx
local log = ngx.log
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG

local encode = cjson.encode

local _M = {
  _VERSION = '0.1.0',
}
local _MT = { __index = _M, }

function _M.new()
    local self = {
        _callbacks = {},
        _funcs = {},
        _counter = 0,
    }

    return setmetatable(self, _MT)
end

local function get_callback_list(self, source, event)
    local _callbacks = self._callbacks

    if not _callbacks[source] then
        _callbacks[source] = {}
    end

    if not _callbacks[source][event] then
        _callbacks[source][event] = {}
    end

    return _callbacks[source][event]
end

-- subscribe('*', '*', func)
-- subscribe('s', '*', func)
-- subscribe('s', 'e', func)
function _M:subscribe(source, event, callback)
    local list = get_callback_list(self, source, event)

    local count = self._counter + 1
    self._counter = count

    local id = tostring(count)

    self._funcs[id] = callback
    list[id] = true

    return id
end

function _M:unsubscribe(id)
    self._funcs[tostring(id)] = nil
end

local function do_handlerlist(funcs, list, source, event, data, wid)
    local ok, err

    --log(DEBUG, "source=", source, "event=", event)

    for id, _ in pairs(list) do
        local handler = funcs[id]

        if type(handler) ~= "function" then
            list[id] = nil
            goto continue
        end

        assert(type(handler) == "function")

        ngx.update_time()
        local now = ngx.now()

        ok, err = xpcall(handler, traceback, data, event, source, wid)

        if not ok then
            local str, e

            if type(data) == "table" then
                str, e = encode(data)
                if not str then
                    str = tostring(e)
                end

            else
                str = tostring(data)
            end

            log(ERR, "worker-events: event callback failed; source=", source,
                     ", event=", event,", wid=", wid, " error='", tostring(err),
                     "', data=", str)
        end

        ngx.update_time()
        local delta = ngx.now() - now
        if delta > 0.09 then
          log(DEBUG, "worker-events [callback] : time=", delta,
                     ", info=", require("inspect")(debug.getinfo(handler)))
        end

        ::continue::
    end
end

-- Handle incoming table based event
function _M:do_event(d)
    local source = d.source
    local event  = d.event
    local data   = d.data
    local wid    = d.wid
    local time   = d.time

    ngx.update_time()
    local now = ngx.now()

    if time then
      log(DEBUG, "worker-events [receive]: source=", source,
          ", event=", event, ", wid=", wid, ", time=", now - time,
          ", data=", require("inspect")(data))
    end

    log(DEBUG, "worker-events: handling event; source=", source,
        ", event=", event, ", wid=", wid, ", data=", require("inspect")(data))

    local funcs = self._funcs
    local list

    -- global callback
    list = get_callback_list(self, "*", "*")
    do_handlerlist(funcs, list, source, event, data, wid)

    -- source callback
    list = get_callback_list(self, source, "*")
    do_handlerlist(funcs, list, source, event, data, wid)

    -- source+event callback
    list = get_callback_list(self, source, event)
    do_handlerlist(funcs, list, source, event, data, wid)

    ngx.update_time()
    log(DEBUG, "worker-events [done] : source=", source,
        ", event=", event, ", wid=", wid, ", time=", ngx.now() - now,
        ", data=", encode(data))

end

return _M
