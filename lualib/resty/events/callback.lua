local cjson = require "cjson.safe"


local type = type
local assert = assert
local table_insert = table.insert

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

return _M
