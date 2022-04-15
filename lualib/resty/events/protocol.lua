local frame = require "resty.events.frame"

local _recv_frame = frame.recv
local _send_frame = frame.send

local ngx = ngx
local tcp = ngx.socket.tcp
local re_match = ngx.re.match
local req_sock = ngx.req.socket
local ngx_header = ngx.header
local send_headers = ngx.send_headers
local flush = ngx.flush
local subsystem = ngx.config.subsystem

local type = type
local str_sub = string.sub
local setmetatable = setmetatable

local DEFAULT_TIMEOUT = 5000     -- 5000ms

local function is_timeout(err)
    return err and str_sub(err, -7) == "timeout"
end

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


local _Server = {
    _VERSION = "0.1.0",
    is_timeout = is_timeout,
    recv_frame = recv_frame,
    send_frame = send_frame,
}

local _SERVER_MT = { __index = _Server, }


function _Server.new(self)

    if subsystem == "http" then
        if ngx.headers_sent then
            return nil, "response header already sent"
        end

        ngx_header["Upgrade"] = "Kong-Worker-Events/1"
        ngx_header["Content-Type"] = nil
        ngx.status = 101

        local ok, err = send_headers()
        if not ok then
            return nil, "failed to send response header: " .. (err or "unknonw")
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

    return setmetatable({
        sock = sock,
    }, _SERVER_MT)
end


local _Client = {
    _VERSION = "0.1.0",
    is_timeout = is_timeout,
    recv_frame = recv_frame,
    send_frame = send_frame,
}

local _CLIENT_MT = { __index = _Client, }


function _Client.new(self)
    local sock, err = tcp()
    if not sock then
        return nil, err
    end

    sock:settimeout(DEFAULT_TIMEOUT)

    return setmetatable({
        sock = sock,
    }, _CLIENT_MT)
end


function _Client.connect(self, addr)
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
            return nil, "failed to receive response header: " .. err
        end

        local m, _ = re_match(header, [[^\s*HTTP/1\.1\s+]], "jo")
        if not m then
            return nil, "bad HTTP response status line: " .. header
        end
    end -- subsystem == "http"

    return true
end


return {
    server = _Server,
    client = _Client,
}
