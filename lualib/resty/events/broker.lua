local codec = require "resty.events.codec"
local lrucache = require "resty.lrucache"

local que = require "resty.events.queue"
local server = require("resty.events.protocol").server

local pairs = pairs
local setmetatable = setmetatable
local str_sub = string.sub

local ngx = ngx
local log = ngx.log
local exit = ngx.exit
local exiting = ngx.worker.exiting
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG

local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local wait = ngx.thread.wait

local decode = codec.decode

local MAX_UNIQUE_EVENTS = 1024

local _M = {
    _VERSION = '0.1.0',
}
local _MT = { __index = _M, }

local function is_timeout(err)
    return err and str_sub(err, -7) == "timeout"
end

function _M.new()
    local self = {
        _opts = nil,
        _uniques = nil,
        _clients = nil,
    }

    return setmetatable(self, _MT)
end

function _M:configure(opts)
    assert(not self._opts)

    self._opts = opts

    local _uniques, err = lrucache.new(MAX_UNIQUE_EVENTS)
    if not _uniques then
        return nil, "failed to create the events cache: " .. (err or "unknown")
    end

    local _clients = setmetatable({}, { __mode = "k", })

    self._uniques = _uniques
    self._clients = _clients

    return true
end

function _M:run()
    local conn, err = server:new()

    if not conn then
        log(ERR, "failed to init socket: ", err)
        exit(444)
    end

    local queue = que.new()

    self._clients[conn] = queue

    local read_thread = spawn(function()
        while not exiting() do
            local data, err = conn:recv_frame()

            if err then
                if not is_timeout(err) then
                  return nil, err
                end

                -- timeout
                goto continue
            end

            if not data then
                return nil, "did not receive event from worker"
            end

            local d, err

            d, err = decode(data)
            if not d then
                log(ERR, "worker-events: failed decoding event data: ", err)
                goto continue
            end

            -- unique event
            local unique = d.spec.unique
            if unique then
                if self._uniques:get(unique) then
                    log(DEBUG, "unique event is duplicate: ", unique)
                    goto continue
                end

                self._uniques:set(unique, 1, self._opts.unique_timeout)
            end

            -- broadcast to all/unique workers
            local n = 0
            for _, q in pairs(self._clients) do
                local ok, err = q:push(d.data)

                if not ok then
                    log(ERR, "failed to publish event: ", err)

                else
                    n = n + 1

                    if unique then
                        break
                    end
                end

            end  -- for q in pairs(_clients)

            log(DEBUG, "event published to ", n, " workers")

            ::continue::
        end -- while not exiting
    end)  -- read_thread

    local write_thread = spawn(function()
        while not exiting() do
            local payload, err = queue:pop()

            if not payload then
                if not is_timeout(err) then
                    return nil, "semaphore wait error: " .. err
                end

                goto continue
            end

            if exiting() then
                return
            end

            local _, err = conn:send_frame(payload)
            if err then
                log(ERR, "failed to send event: ", err)
            end

            ::continue::
        end -- while not exiting
    end)  -- write_thread

    local ok, err, perr = wait(write_thread, read_thread)

    self._clients[conn] = nil

    kill(write_thread)
    kill(read_thread)

    if not ok then
        log(ERR, "event broker failed: ", err)
        return exit(ngx.ERROR)
    end

    if perr then
        log(ERR, "event broker failed: ", perr)
        return exit(ngx.ERROR)
    end

    return exit(ngx.OK)
end

return _M

