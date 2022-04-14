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

local function do_handlerlist(funcs, list, source, event, data, pid)
    local ok, err

    --log(DEBUG, "source=", source, "event=", event)

    for id, _ in pairs(list) do
        local handler = funcs[id]

        if type(handler) ~= "function" then
            list[id] = nil
            goto continue
        end

        assert(type(handler) == "function")

        ok, err = xpcall(handler, traceback, data, event, source, pid)

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
                     ", event=", event,", pid=",pid, " error='", tostring(err),
                     "', data=", str)
        end

        ::continue::
    end
end

-- Handle incoming table based event
function _M:do_event(d)
    local source = d.source
    local event  = d.event
    local data   = d.data
    local pid    = d.pid

    log(DEBUG, "worker-events: handling event; source=", source,
        ", event=", event, ", pid=", pid)

    local funcs = self._funcs
    local list

    -- global events
    list = get_callback_list(self, "*", "*")
    do_handlerlist(funcs, list, source, event, data, pid)

    -- source events
    list = get_callback_list(self, source, "*")
    do_handlerlist(funcs, list, source, event, data, pid)

    -- source/event events
    list = get_callback_list(self, source, event)
    do_handlerlist(funcs, list, source, event, data, pid)
end

return _M
