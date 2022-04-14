local cjson = require "cjson.safe"

local ok, buffer = pcall(require, "string.buffer")
if not ok then
    return cjson

else
    return buffer
end

