local cjson = require "cjson.safe"
local codec = require "resty.events.codec"
local lrucache = require "resty.lrucache"
local queue = require "resty.events.queue"
local server = require("resty.events.protocol").server
local is_timeout = server.is_timeout
local is_closed = server.is_closed

local setmetatable = setmetatable
local random = math.random

local ngx = ngx
local log = ngx.log
local exit = ngx.exit
local exiting = ngx.worker.exiting
local ngx_worker_id = ngx.worker.id
local worker_count = ngx.worker.count
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG
local NOTICE = ngx.NOTICE

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

    local queues = self._queues

    local first_worker_id = self._first_worker_id
    local last_worker_id = self._last_worker_id

    if unique then
        -- if unique, schedule to a random worker
        local worker_id = random(first_worker_id, last_worker_id)
        local worker_queue = queues[worker_id]
        local ok, err = worker_queue:push(data)
        if not ok then
            if worker_id == -1 then
                log(ERR, "failed to publish unique event to privileged agent: ", err,
                         ". data is :", cjson_encode(decode(data)))
            else
                log(ERR, "failed to publish unique event to worker #", worker_id,
                         ": ", err, ". data is :", cjson_encode(decode(data)))
            end

        else
            n = n + 1
        end

    else
        for worker_id = first_worker_id, last_worker_id do
            local worker_queue = queues[worker_id]
            local ok, err = worker_queue:push(data)
            if not ok then
                if worker_id == -1 then
                    log(ERR, "failed to publish event to privileged agent: ", err,
                             ". data is :", cjson_encode(decode(data)))
                else
                    log(ERR, "failed to publish event to worker #", worker_id,
                            ": ", err, ". data is :", cjson_encode(decode(data)))
                end

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
                if worker_id == -1 then
                    log(ERR, "did not receive event from privileged agent")
                else
                    log(ERR, "did not receive event from worker #", worker_id)
                end
            end
            goto continue
        end

        local event_data, err = decode(data)
        if not event_data then
            if not exiting() then
                if worker_id == -1 then
                    log(ERR, "failed to decode event data on privileged agent: ", err)
                else
                    log(ERR, "failed to decode event data on worker #", worker_id, ": ", err)
                end
            end
            goto continue
        end

        -- unique event
        local unique = event_data.spec.unique
        if unique then
            if self._uniques:get(unique) then
                if worker_id == -1 then
                    log(DEBUG, "unique event is duplicate on privileged agent: ", unique)
                else
                    log(DEBUG, "unique event is duplicate on worker #", worker_id, ": ", unique)
                end
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
                if worker_id == -1 then
                    log(ERR, "failed to retain event for privileged agent: ",
                             push_err, ". data is :", cjson_encode(decode(payload)))
                else
                    log(ERR, "failed to retain event for worker #", worker_id, ": ",
                             push_err, ". data is :", cjson_encode(decode(payload)))
                end
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
        _first_worker_id = nil,
        _last_worker_id = nil,
    }, _MT)
end

function _M:init()
    local opts = self._opts

    assert(opts)

    local _uniques, err = lrucache.new(MAX_UNIQUE_EVENTS)
    if not _uniques then
        return nil, "failed to create the events cache: " .. (err or "unknown")
    end

    local queues = {}

    local first_worker_id = opts.enable_privileged_agent == true and -1 or 0
    local last_worker_id = worker_count() - 1

    for i = first_worker_id, last_worker_id do
        queues[i] = queue.new(opts.max_queue_len)
    end

    self._uniques = _uniques
    self._clients = setmetatable({}, WEAK_KEYS_MT)
    self._queues = queues
    self._first_worker_id = first_worker_id
    self._last_worker_id = last_worker_id

    log(NOTICE, "event broker is ready to accept connections on worker #", opts.broker_id)

    return true
end

function _M:run()
    local broker_id = ngx_worker_id()
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

    if worker_id == -1 and not queues[-1] then
        -- TODO: this is for backward compatibility
        --
        -- Queue for the privileged agent is dynamically
        -- created because it is not always enabled or
        -- does not always connect to broker. This also
        -- means that privileged agent may miss some
        -- events on a startup.
        --
        -- It is suggested to instead explicitly pass
        -- an option: enable_privileged_agent=true|false.
        queues[-1] = queue.new(self._opts.max_queue_len)
        self._first_worker_id = -1
    end

    clients[worker_connection] = true

    local read_thread_co = spawn(read_thread, self, worker_connection)
    local write_thread_co = spawn(write_thread, self, worker_connection, queues[worker_id])

    if worker_id == -1 then
        log(NOTICE, "privileged agent connected to events broker (worker pid: ",
                    worker_pid, ")")
    else
        log(NOTICE, "worker #", worker_id, " connected to events broker (worker pid: ",
                    worker_pid, ")")
    end

    local ok, err, perr = wait(read_thread_co, write_thread_co)

    clients[worker_connection] = nil

    if exiting() then
        kill(read_thread_co)
        kill(write_thread_co)
        return
    end

    if not ok and not is_closed(err) then
        if worker_id == -1 then
            log(ERR, "event broker failed on worker privileged agent: ", err,
                     " (worker pid: ", worker_pid, ")")
        else
            log(ERR, "event broker failed on worker #", worker_id, ": ", err,
                     " (worker pid: ", worker_pid, ")")
        end
        return exit(ngx.ERROR)
    end

    if perr and not is_closed(perr) then
        if worker_id == -1 then
            log(ERR, "event broker failed on worker privileged agent: ", perr,
                     " (worker pid: ", worker_pid, ")")
        else
            log(ERR, "event broker failed on worker #", worker_id, ": ", perr,
                     " (worker pid: ", worker_pid, ")")
        end
        return exit(ngx.ERROR)
    end

    wait(read_thread_co)
    wait(write_thread_co)

    return exit(ngx.OK)
end

return _M
