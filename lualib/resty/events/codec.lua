-- string.buffer is introduced since openresty 1.21.4.1

local ok, buffer = pcall(require, "string.buffer")
if not ok then
    return require "cjson.safe"

else
    return buffer
end

