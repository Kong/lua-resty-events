local cjson = require "cjson.safe"
local codec = require "resty.events.codec"
local lrucache = require "resty.lrucache"
local queue = require "resty.events.queue"
local server = require("resty.events.protocol").server
local is_timeout = server.is_timeout
local is_closed = server.is_closed


local setmetatable = setmetatable
local random = math.random
local assert = assert


local ngx = ngx
local log = ngx.log
local exit = ngx.exit
local exiting = ngx.worker.exiting
local worker_count = ngx.worker.count
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG


local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local wait = ngx.thread.wait


local decode = codec.decode
local cjson_encode = cjson.encode


local MAX_UNIQUE_EVENTS = 1024
local WEAK_KEYS_MT = { __mode = "k", }


local function terminating(self, worker_connection)
    return not self._clients[worker_connection] or exiting()
end


-- broadcast to all/unique workers
local function broadcast_events(self, unique, data)
    local n = 0

    local workers = self._workers

    local first_worker_id = self._first_worker_id
    local last_worker_id = self._last_worker_id

    if unique then
        -- if unique, schedule to a random worker
        local worker_id = random(first_worker_id, last_worker_id)
        local q = workers[worker_id]
        local ok, err = q:push(data)
        if not ok then
            log(ERR, "failed to publish event: ", err, ". ",
                     "data is :", cjson_encode(decode(data)))
        end

        n = n + 1

    else
        for worker_id = first_worker_id, last_worker_id do
            local q = workers[worker_id]
            local ok, err = q:push(data)
            if not ok then
                log(ERR, "failed to publish event: ", err, ". ",
                         "data is :", cjson_encode(decode(data)))
            end

            n = n + 1
        end
    end

    log(DEBUG, "event published to ", n, " workers")
end


local function read_thread(self, worker_connection)
    while not terminating(self, worker_connection) do
        local event_data, err = worker_connection:recv_frame()
        if err then
            if not is_timeout(err) then
                return nil, err
            end

            -- timeout
            goto continue
        end

        if not event_data then
            if not exiting() then
                log(ERR, "did not receive event from worker")
            end
            goto continue
        end

        event_data, err = decode(event_data)
        if not event_data then
            if not exiting() then
                log(ERR, "failed to decode event data: ", err)
            end
            goto continue
        end

        -- unique event
        local unique = event_data.spec.unique
        if unique then
            if self._uniques:get(unique) then
                log(DEBUG, "unique event is duplicate: ", unique)
                goto continue
            end

            self._uniques:set(unique, 1, self._opts.unique_timeout)
        end

        -- broadcast to all/unique workers
        broadcast_events(self, unique, event_data.data)

        ::continue::
    end -- while not terminating

    return true
end


local function write_thread(self, worker_connection, q)
    while not terminating(self, worker_connection) do
        local data, err = q:pop()
        if not data then
            if not is_timeout(err) then
                return nil, "semaphore wait error: " .. err
            end

            goto continue
        end

        local _, err = worker_connection:send_frame(data)
        if err then
            local ok, push_err = q:push_front(data)
            if not ok then
                log(ERR, "failed to retain event: ", push_err, ". ",
                         "data is :", cjson_encode(decode(data)))
            end
            return nil, "failed to send event: " .. err
        end

        ::continue::
    end -- while not terminating

    return true
end


local _MT = {}
_MT.__index = _MT


function _MT:init()
    assert(self._opts)

    local _uniques, err = lrucache.new(MAX_UNIQUE_EVENTS)
    if not _uniques then
        return nil, "failed to create the events cache: " .. (err or "unknown")
    end

    local workers = {}
    local first_worker_id = 0 -- worker ids are zero based
    local last_worker_id = worker_count() - 1
    for i = first_worker_id, last_worker_id do
        workers[i] = queue.new(self._opts.max_queue_len)
    end

    self._uniques = _uniques
    self._clients = setmetatable({}, WEAK_KEYS_MT)
    self._workers = workers
    self._first_worker_id = first_worker_id
    self._last_worker_id = last_worker_id

    return true
end


function _MT:run()
    local worker_connection, err = server.new()
    if not worker_connection then
        log(ERR, "failed to init socket: ", err)
        exit(444)
    end

    local clients = self._clients
    local workers = self._workers
    local worker_id = worker_connection.info.id
    if worker_id == -1 and not workers[-1] then
        -- TODO: init level detection of privileged agent
        -- Queue for the privileged agent is dynamically
        -- created because it is not always enabled
        -- or does not always connect to broker.
        -- This also means that privileged agent may
        -- miss some events on a startup.
        workers[-1] = queue.new(self._opts.max_queue_len)
        self._first_worker_id = -1
    end

    clients[worker_connection] = true

    local read_thread_co = spawn(read_thread, self, worker_connection)
    local write_thread_co = spawn(write_thread, self, worker_connection, workers[worker_id])

    if worker_id == -1 then
        log(DEBUG, "privileged agent connected to events broker (worker pid: ",
                   worker_connection.info.pid, ")")
    else
        log(DEBUG, "worker #", worker_id, " connected to events broker (worker pid: ",
                   worker_connection.info.pid, ")")
    end

    local ok, err, perr = wait(read_thread_co, write_thread_co)

    clients[worker_connection] = nil

    if exiting() then
        kill(read_thread_co)
        kill(write_thread_co)
        return
    end

    if not ok and not is_closed(err) then
        log(ERR, "event broker failed (", err, ")")
        return exit(ngx.ERROR)
    end

    if perr and not is_closed(perr) then
        log(ERR, "event broker failed (", perr, ")")
        return exit(ngx.ERROR)
    end

    wait(read_thread_co)
    wait(write_thread_co)

    return exit(ngx.OK)
end


local _M = {}


function _M.new(opts)
    local self = setmetatable({
        _opts = opts,
        _uniques = nil,
        _clients = nil,
        _workers = nil,
    }, _MT)

    return self
end


return _M
