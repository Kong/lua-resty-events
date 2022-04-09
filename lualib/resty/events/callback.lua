local cjson = require "cjson.safe"

local xpcall = xpcall
local type = type
local pairs = pairs
local assert = assert
local tostring = tostring
local traceback = debug.traceback

local ngx = ngx
local log = ngx.log
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG

local encode = cjson.encode

local _M = {
  _VERSION = '0.1.0',
}

local _callbacks = {}

local function get_callback_list(source, event)
    if not _callbacks[source] then
        _callbacks[source] = {}
    end

    if not _callbacks[source][event] then
        _callbacks[source][event] = {}

        local count_key = event .. "n"
        _callbacks[source][count_key] = 0
    end

    return _callbacks[source][event]
end

-- subscribe('*', '*', func)
-- subscribe('s', '*', func)
-- subscribe('s', 'e', func)
function _M.subscribe(source, event, callback)
    assert(type(callback) == "function", "expected function, got: "..
           type(callback))

    local list = get_callback_list(source, event)

    local count_key = event .. "n"
    local count = _callbacks[source][count_key] + 1

    _callbacks[source][count_key] = count

    local id = tostring(count)
    list[id] = callback

    return id
end

function _M.unsubscribe(source, event, id)
    assert(source, "expect source")

    -- clear source callbacks
    if not event and not id then
        _callbacks[source] = {}
        return
    end

    -- clear source/event callbacks
    if not id then
        assert(_callbacks[source])
        _callbacks[source][event] = {}
        return
    end

    -- clear one handler

    local list = get_callback_list(source, event)

    list[tostring(id)] = nil
end

local function do_handlerlist(list, source, event, data, pid)
    local ok, err

    --log(DEBUG, "source=", source, "event=", event)

    for _, handler in pairs(list) do
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
    end
end

-- Handle incoming table based event
function _M.do_event(d)
    local source = d.source
    local event  = d.event
    local data   = d.data
    local pid    = d.pid

    log(DEBUG, "worker-events: handling event; source=", source,
        ", event=", event, ", pid=", pid)

    local list

    -- global events
    list = get_callback_list("*", "*")
    do_handlerlist(list, source, event, data, pid)

    -- source events
    list = get_callback_list(source, "*")
    do_handlerlist(list, source, event, data, pid)

    -- source/event events
    list = get_callback_list(source, event)
    do_handlerlist(list, source, event, data, pid)
end

return _M
