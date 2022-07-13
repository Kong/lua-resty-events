local cjson = require "cjson.safe"
local nkeys = require "table.nkeys"
local codec = require "resty.events.codec"
local lrucache = require "resty.lrucache"

local que = require "resty.events.queue"
local server = require("resty.events.protocol").server
local is_timeout = server.is_timeout

local pairs = pairs
local setmetatable = setmetatable
local str_sub = string.sub
local random = math.random

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

local cjson_encode = cjson.encode

local MAX_UNIQUE_EVENTS = 1024

local function is_closed(err)
    return err and
           (str_sub(err, -6) == "closed" or
            str_sub(err, -11) == "broken pipe")
end

-- broadcast to all/unique workers
local function broadcast_events(self, unique, data)
    local n = 0

    -- if unique, schedule to a random worker
    local idx = unique and random(1, nkeys(self._clients))

    for _, q in pairs(self._clients) do
        local ok, err

        -- skip some and broadcast to one workers
        if unique then
            idx = idx - 1

            if idx > 0 then
                goto continue
            end

            ok, err = q:push(data)

        -- broadcast to all workers
        else
            ok, err = q:push(data)
        end

        if not ok then
            log(ERR, "failed to publish event: ", err, ". ",
                     "data is :", cjson_encode(decode(data)))

        else
            n = n + 1

            if unique then
                break
            end
        end

        ::continue::
    end  -- for q in pairs(_clients)

    log(DEBUG, "event published to ", n, " workers")
end

local _M = {
    _VERSION = '0.1.2',
}
local _MT = { __index = _M, }

function _M.new(opts)
    local self = {
        _opts = opts,
        _uniques = nil,
        _clients = nil,
    }

    return setmetatable(self, _MT)
end

function _M:init()
    assert(self._opts)

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

    local queue = que.new(self._opts.max_queue_len)

    self._clients[conn] = queue

    local read_thread = spawn(function()
        while not exiting() do
            local data, err = conn:recv_frame()

            if exiting() then
                return
            end

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
                log(ERR, "failed to decode event data: ", err)
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
            broadcast_events(self, unique, d.data)

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

            if is_closed(err) then
                return
            end

            ::continue::
        end -- while not exiting
    end)  -- write_thread

    local ok, err, perr = wait(write_thread, read_thread)

    self._clients[conn] = nil

    kill(write_thread)
    kill(read_thread)

    if not ok and not is_closed(err) then
        log(ERR, "event broker failed: ", err)
        return exit(ngx.ERROR)
    end

    if perr and not is_closed(perr) then
        log(ERR, "event broker failed: ", perr)
        return exit(ngx.ERROR)
    end

    return exit(ngx.OK)
end

return _M

