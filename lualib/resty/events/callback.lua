local cjson = require "cjson.safe"


local xpcall = xpcall
local type = type
local pairs = pairs
local tostring = tostring
local setmetatable = setmetatable
local traceback = debug.traceback


local ngx = ngx
local log = ngx.log
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG


local encode = cjson.encode


local _MT = {}
_MT.__index = _MT


local function get_callback_list(self, source, event)
    return self._callbacks[source] and self._callbacks[source][event]
end


local function prepare_callback_list(self, source, event)
    local callbacks = self._callbacks
    if not callbacks[source] then
        callbacks[source] = {
            [event] = {}
        }
    elseif not callbacks[source][event] then
        callbacks[source][event] = {}
    end
    return callbacks[source][event]
end


local function do_handlerlist(funcs, list, source, event, data, wid)
    if not list then
        return
    end

    for id in pairs(list) do
        local handler = funcs[id]
        if type(handler) ~= "function" then
            list[id] = nil
            goto continue
        end

        local ok, err = xpcall(handler, traceback, data, event, source, wid)
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

        ::continue::
    end
end


-- subscribe('*', '*', func)
-- subscribe('s', '*', func)
-- subscribe('s', 'e', func)
function _MT:subscribe(source, event, callback)
    local list = prepare_callback_list(self, source, event)

    local count = self._counter + 1
    self._counter = count

    local id = tostring(count)

    self._funcs[id] = callback
    list[id] = true

    return id
end


function _MT:unsubscribe(id)
    self._funcs[tostring(id)] = nil
end


-- Handle incoming table based event
function _MT:do_event(d)
    local source = d.source
    local event  = d.event
    local data   = d.data
    local wid    = d.wid

    log(DEBUG, "worker-events: handling event; source=", source,
               ", event=", event, ", wid=", wid)

    local funcs = self._funcs

    -- global callback
    local list = get_callback_list(self, "*", "*")
    do_handlerlist(funcs, list, source, event, data, wid)

    -- source callback
    list = get_callback_list(self, source, "*")
    do_handlerlist(funcs, list, source, event, data, wid)

    -- source+event callback
    list = get_callback_list(self, source, event)
    do_handlerlist(funcs, list, source, event, data, wid)
end


local _M = {}


function _M.new()
    local self = setmetatable({
        _callbacks = {},
        _funcs = {},
        _counter = 0,
    }, _MT)

    return self
end


return _M
