-- string.buffer is introduced since openresty 1.21.4.1

local ok, buffer = pcall(require, "string.buffer")
if not ok then
    return require "cjson.safe"
end


local options = {
  dict = {
    "spec", "data",
    "source", "event", "wid", "unique",
  },
}


local buf_enc = buffer.new(options)
local buf_dec = buffer.new(options)


local _M = {}


function _M.encode(obj)
  return buf_enc:reset():encode(obj):get()
end


function _M.decode(str)
  return buf_dec:set(str):decode()
end


return _M
