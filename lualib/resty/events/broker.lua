local codec = require "resty.events.codec"
local lrucache = require "resty.lrucache"
local queue = require "resty.events.queue"
local utils = require "resty.events.utils"
local server = require("resty.events.protocol").server


local is_timeout = utils.is_timeout
local is_closed = utils.is_closed
local get_worker_id = utils.get_worker_id
local get_worker_name = utils.get_worker_name


local setmetatable = setmetatable
local random = math.random


local ngx = ngx   -- luacheck: ignore
local log = ngx.log
local exit = ngx.exit
local exiting = ngx.worker.exiting
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG
local NOTICE = ngx.NOTICE


local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local wait = ngx.thread.wait


local decode = codec.decode


local MAX_UNIQUE_EVENTS = 1024
local WEAK_KEYS_MT = { __mode = "k", }


local get_json
do
    local cjson_encode = require("cjson.safe").encode

    get_json = function(data)
        return cjson_encode(decode(data))
    end
end


local function terminating(self, worker_connection)
    return not self._clients[worker_connection] or exiting()
end

-- broadcast to all/unique workers
local function broadcast_events(self, unique, data)
    local n = 0

    local queues = self._queues

    if unique then
        -- if unique, schedule to a random worker
        local worker_id = self._workers[random(self._workers[0])]
        local worker_queue = queues[worker_id]
        local ok, err = worker_queue:push(data)
        if not ok then
            log(ERR, "failed to publish unique event to ",
                     get_worker_name(worker_id),
                     ": ", err,
                     ". data is :", get_json(data))

        else
            n = n + 1
        end

    else
        for i = 1, self._workers[0] do
            local worker_id = self._workers[i]
            local worker_queue = queues[worker_id]
            local ok, err = worker_queue:push(data)
            if not ok then
                log(ERR, "failed to publish event to ",
                         get_worker_name(worker_id),
                         ": ", err,
                         ". data is :", get_json(data))

            else
                n = n + 1
            end
        end
    end

    log(DEBUG, "event published to ", n, " workers")
end

local function read_thread(self, worker_connection)
    local worker_id = worker_connection.info.id
    while not terminating(self, worker_connection) do
        local data, err = worker_connection:recv_frame()
        if err then
            if not is_timeout(err) then
                return nil, "failed to read event from worker: " .. err
            end

            -- timeout
            goto continue
        end

        if not data then
            if not exiting() then
                log(ERR, "did not receive event from ", get_worker_name(worker_id))
            end
            goto continue
        end

        local event_data, err = decode(data)
        if not event_data then
            if not exiting() then
                log(ERR, "failed to decode event data on ",
                          get_worker_name(worker_id), ": ", err)
            end
            goto continue
        end

        -- unique event
        local unique = event_data.spec.unique
        if unique then
            if self._uniques:get(unique) then
                log(DEBUG, "unique event is duplicate on ",
                            get_worker_name(worker_id), ": ", unique)
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

local function write_thread(self, worker_connection, worker_queue)
    local worker_id = worker_connection.info.id
    while not terminating(self, worker_connection) do
        local payload, err = worker_queue:pop()
        if not payload then
            if not is_timeout(err) then
                return nil, "semaphore wait error: " .. err
            end

            goto continue
        end

        local _, err = worker_connection:send_frame(payload)
        if err then
            local ok, push_err = worker_queue:push_front(payload)
            if not ok then
                log(ERR, "failed to retain event for ",
                          get_worker_name(worker_id), ": ", push_err,
                          ". data is :", get_json(payload))
            end
            return nil, "failed to send event: " .. err
        end

        ::continue::
    end -- while not terminating

    return true
end

local _M = {}
local _MT = { __index = _M, }

function _M.new(opts)
    return setmetatable({
        _opts = opts,
        _queues = nil,
        _uniques = nil,
        _clients = nil,
    }, _MT)
end

function _M:init()
    local opts = self._opts

    assert(opts)

    local _uniques, err = lrucache.new(MAX_UNIQUE_EVENTS)
    if not _uniques then
        return nil, "failed to create the events cache: " .. (err or "unknown")
    end

    self._uniques = _uniques
    self._clients = setmetatable({}, WEAK_KEYS_MT)
    self._queues = {}
    self._workers = {
        [0] = 0, -- self length
    }

    log(NOTICE, "event broker is ready to accept connections on worker #", opts.broker_id)

    return true
end

function _M:run()
    local broker_id = get_worker_id()
    if broker_id ~= self._opts.broker_id then
        log(ERR, "broker got connection from worker on non-broker worker #", broker_id)
        return exit(444)
    end

    local clients = self._clients
    if not clients then
        log(ERR, "broker is not (yet) ready to accept connections on worker #", broker_id)
        return exit(444)
    end

    local worker_connection, err = server.new()
    if not worker_connection then
        log(ERR, "failed to init socket: ", err)
        return exit(444)
    end

    local queues = self._queues
    local worker_id = worker_connection.info.id
    local worker_pid = worker_connection.info.pid

    if not queues[worker_id] then
        local worker_queue, err = queue.new(self._opts.max_queue_len)
        if not worker_queue then
            log(ERR, "failed to create queue for worker #", worker_id, ": ", err)
            return exit(ngx.ERROR)
        end

        queues[worker_id] = worker_queue
        self._workers[0] = self._workers[0] + 1
        self._workers[self._workers[0]] = worker_id
    end

    clients[worker_connection] = true

    local read_thread_co = spawn(read_thread, self, worker_connection)
    local write_thread_co = spawn(write_thread, self, worker_connection, queues[worker_id])

    log(NOTICE, get_worker_name(worker_id),
                " connected to events broker (worker pid: ", worker_pid, ")")

    local ok, err, perr = wait(read_thread_co, write_thread_co)

    clients[worker_connection] = nil

    if exiting() then
        kill(read_thread_co)
        kill(write_thread_co)
        return
    end

    if not ok and not is_closed(err) then
        log(ERR, "event broker failed on ", get_worker_name(worker_id),
                  ": ", err, " (worker pid: ", worker_pid, ")")
        return exit(ngx.ERROR)
    end

    if perr and not is_closed(perr) then
        log(ERR, "event broker failed on ", get_worker_name(worker_id),
                 ": ", perr, " (worker pid: ", worker_pid, ")")
        return exit(ngx.ERROR)
    end

    wait(read_thread_co)
    wait(write_thread_co)

    return exit(ngx.OK)
end

return _M
