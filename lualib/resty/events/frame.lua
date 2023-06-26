local bit = require "bit"
local tablepool = require "tablepool"


local byte = string.byte
local char = string.char
local band = bit.band
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local tablepool_fetch = tablepool.fetch
local tablepool_release = tablepool.release


local type = type
local assert = assert
local tostring = tostring


local _M = {
    _VERSION = "0.2.0",
}


-- frame format: Len(3 bytes) + Payload(max to 2^24 - 1 bytes)


local MAX_PAYLOAD_LEN = 2^24 - 1    -- 16MB
local UINT_HEADER_LEN = 3


local POOL_EVENTS_FRAME = "RESTY_EVENTS_FRAME"


local function uint_to_bytes(num)
    if num < 0 or num > MAX_PAYLOAD_LEN then
        error("number " .. tostring(num) .. " out of range", 2)
    end

    return char(band(rshift(num, 16), 0xFF),
                band(rshift(num, 8 ), 0xFF),
                band(num, 0xFF))
end


local function bytes_to_uint(str)
    assert(#str == UINT_HEADER_LEN)

    local b1, b2, b3 = byte(str, 1, UINT_HEADER_LEN)

    return bor(lshift(b1, 16),
               bor(lshift(b2, 8), b3))
end


function _M.recv(sock)
    local data, err = sock:receive(UINT_HEADER_LEN)
    if not data then
        return nil, "failed to receive the header bytes: " .. err
    end

    local payload_len = bytes_to_uint(data)

    data, err = sock:receive(payload_len)
    if not data then
        return nil, "failed to read payload: " .. (err or "unknown")
    end

    return data
end


local function validate(payload)
    if type(payload) ~= "string" then
        return nil, "payload must be string"
    end

    local payload_len = #payload

    if payload_len > MAX_PAYLOAD_LEN then
        return nil, "payload too big"
    end

    return payload_len
end
_M.validate = validate


function _M.send(sock, payload)
    local payload_len, err = validate(payload)
    if not payload_len then
        return nil, err
    end

    local data = tablepool_fetch(POOL_EVENTS_FRAME, 2, 0)
    data[1] = uint_to_bytes(payload_len)
    data[2] = payload

    local bytes, err = sock:send(data)

    tablepool_release(POOL_EVENTS_FRAME, data, true)

    if not bytes then
        return nil, "failed to send frame: " .. err
    end

    return bytes
end


return _M
