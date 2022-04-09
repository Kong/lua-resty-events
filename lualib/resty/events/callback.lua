local cjson = require "cjson.safe"

local xpcall = xpcall
local type = type
local assert = assert
local tostring = tostring
local table_insert = table.insert
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

-- subscribe('*', '*', func)
-- subscribe('s', '*', func)
-- subscribe('s', 'e', func)
function _M.subscribe(source, event, callback)
    assert(type(callback) == "function", "expected function, got: "..
           type(callback))

    if not _callbacks[source] then
        _callbacks[source] = {count = 0,}
    end

    if not _callbacks[source][event] then
        _callbacks[source][event] = {count = 0,}
    end

    --local count = #_callbacks[source][event]
    table_insert(_callbacks[source][event], callback)

    return true
end

local function do_handlerlist(handler_list, source, event, data, pid)
    local ok, err

    for _, handler in ipairs(handler_list) do
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

          log(ERR, "worker-events: event callback failed; source=",source,
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
    list = _callbacks['*']['*']
    do_handlerlist(list, source, event, data, pid)

    -- source events
    list = _callbacks[source]['*']
    do_handlerlist(list, source, event, data, pid)

    -- source/event events
    list = _callbacks[source][event]
    do_handlerlist(list, source, event, data, pid)
end

return _M
