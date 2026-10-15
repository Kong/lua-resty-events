local frame = require "resty.events.frame"
local codec = require "resty.events.codec"
local utils = require "resty.events.utils"


local _recv_frame = frame.recv
local _send_frame = frame.send
local encode = codec.encode
local decode = codec.decode
local is_timeout = utils.is_timeout
local is_closed = utils.is_closed


local ngx = ngx -- luacheck: ignore
local worker_pid = ngx.worker.pid
local tcp = ngx.socket.tcp
local req_sock = ngx.req.socket
local ngx_header = ngx.header
local send_headers = ngx.send_headers
local flush = ngx.flush
local subsystem = ngx.config.subsystem
local get_worker_id = utils.get_worker_id


local type = type
local str_sub = string.sub
local str_find = string.find
local setmetatable = setmetatable


-- for high traffic pressure
local DEFAULT_TIMEOUT = 5000 -- 5000ms
-- A graceful upgrade runs workers of the previous version next to the new ones,
-- so the handshake has to stay readable by both: the markers below and
-- WORKER_INFO.ack are the compatibility, ACCEPT_TIMEOUT bounds the wait.
local ACCEPT_TIMEOUT = 100 -- 100ms
local ACCEPT_FRAME = "\1"
local UPGRADE_VERSION = "Kong-Worker-Events/2"
local WORKER_INFO = {
    id = 0,
    pid = 0,
    ack = true,
}


local function recv_frame(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized yet"
    end

    return _recv_frame(sock)
end

local function send_frame(self, payload)
    local sock = self.sock
    if not sock then
        return nil, "not initialized yet"
    end

    return _send_frame(sock, payload)
end

-- tells the client that it reached the broker of its own generation
local function ack(self)
    if not self.info.ack then
        -- an older client does not expect it
        return true
    end

    return _send_frame(self.sock, ACCEPT_FRAME)
end

local _Server = {
    recv_frame = recv_frame,
    send_frame = send_frame,
    ack = ack,
}

local _SERVER_MT = { __index = _Server, }

function _Server.new()
    if subsystem == "http" then
        if ngx.headers_sent then
            return nil, "response header already sent"
        end

        ngx_header["Upgrade"] = UPGRADE_VERSION
        ngx_header["Content-Type"] = nil
        ngx.status = 101

        local ok, err = send_headers()
        if not ok then
            return nil, "failed to send response header: " .. (err or "unknown")
        end

        ok, err = flush(true)
        if not ok then
            return nil, "failed to flush response header: " .. (err or "unknown")
        end
    end -- subsystem == "http"

    local sock, err = req_sock(true)
    if not sock then
        return nil, err
    end

    sock:settimeout(DEFAULT_TIMEOUT)

    local data, err = _recv_frame(sock)
    if err then
        return nil, "failed to read worker info: " .. err
    end

    local info, err = decode(data)
    if err then
        return nil, "invalid worker info received: " .. err
    end

    return setmetatable({
        info = info,
        sock = sock,
    }, _SERVER_MT)
end

local _Client = {
    recv_frame = recv_frame,
    send_frame = send_frame,
}

local _CLIENT_MT = { __index = _Client, }

function _Client.new()
    local sock, err = tcp()
    if not sock then
        return nil, err
    end

    sock:settimeout(DEFAULT_TIMEOUT)

    return setmetatable({
        sock = sock,
    }, _CLIENT_MT)
end

function _Client:connect(addr)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    if type(addr) ~= "string" then
        return nil, "addr must be a string"
    end

    if str_sub(addr, 1, 5) ~= "unix:" then
        return nil, "addr must start with \"unix:\""
    end

    local ok, err = sock:connect(addr)
    if not ok then
        return nil, "failed to connect: " .. err
    end

    -- whether to wait for the acknowledgement, and for how long
    local wait_for_ack = true
    local ack_timeout = DEFAULT_TIMEOUT

    if subsystem == "http" then
        local req = "GET / HTTP/1.1\r\n" ..
                    "Host: localhost\r\n" ..
                    "Connection: Upgrade\r\n" ..
                    "Upgrade: Kong-Worker-Events/1\r\n\r\n"

        local bytes, err = sock:send(req)
        if not bytes then
            return nil, "failed to send the handshake request: " .. err
        end

        local header_reader = sock:receiveuntil("\r\n\r\n")
        local header, err, _ = header_reader()
        if not header then
            if is_closed(err) then
                -- how a broker refuses us: dropped handshake, retry later
                return nil, "broker dropped the handshake: " .. err, true
            end

            return nil, "failed to receive response header: " .. err
        end

        if str_find(header, "HTTP/1.1 101", nil, true) ~= 1 then
            -- anything that is not an events broker upgrade
            return nil, "bad HTTP response status line: " .. header, true
        end

        if not str_find(header, UPGRADE_VERSION, nil, true) then
            -- an older broker: nothing to wait for
            wait_for_ack = false
        end

    else
        ack_timeout = ACCEPT_TIMEOUT
    end -- subsystem == "http"

    WORKER_INFO.id = get_worker_id()
    WORKER_INFO.pid = worker_pid()

    local _, err = _send_frame(sock, encode(WORKER_INFO))
    if err then
        if is_closed(err) then
            -- same as above (stream has no response header to carry it)
            return nil, "broker dropped the handshake: " .. err, true
        end

        return nil, "failed to send worker info: " .. err
    end

    if not wait_for_ack then
        return true
    end

    -- a broker that refuses us drops the connection instead, so the caller
    -- retries without having published anything
    sock:settimeout(ack_timeout)
    local data, err = _recv_frame(sock)
    sock:settimeout(DEFAULT_TIMEOUT)

    if not data then
        if is_timeout(err) then
            -- an older broker never acknowledges, go on
            return true
        end

        return nil, "broker dropped the handshake: " .. err, true
    end

    if data ~= ACCEPT_FRAME then
        return nil, "unexpected handshake response: " .. data, true
    end

    return true
end

function _Client:close()
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    local ok, err = sock:close()
    if not ok then
        return nil, err
    end

    return true
end

return {
    server = _Server,
    client = _Client,
    ACCEPT_FRAME = ACCEPT_FRAME,
}
