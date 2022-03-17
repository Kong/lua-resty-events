local ffi = require "ffi"
local cjson = require "cjson.safe"
local lrucache = require "resty.lrucache"
--local semaphore = require "ngx.semaphore"
local que = require "resty.events.queue"
local server = require("resty.events.protocol").server

local type = type
local assert = assert
local pairs = pairs
local setmetatable = setmetatable
local str_sub  = string.sub
--local table_insert = table.insert
--local table_remove = table.remove
--local random = math.random

local ngx = ngx
local log = ngx.log
local exit = ngx.exit
local exiting = ngx.worker.exiting
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG

local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local wait = ngx.thread.wait

local C = ffi.C
local ffi_new = ffi.new

ffi.cdef[[
void
ngx_http_lua_kong_ffi_socket_close_unix_listening(ngx_str_t *sock_name);
]]

local function close_listening(sock_name)
    if type(sock_name) == "string" then
        local UNIX_PREFIX = "unix:"

        if str_sub(sock_name, 1, #UNIX_PREFIX) ~= UNIX_PREFIX then
            return nil, "sock_name must start with " .. UNIX_PREFIX
        end

        sock_name = str_sub(sock_name, #UNIX_PREFIX + 1)

        local sock_name_str = ffi_new("ngx_str_t[1]")

        sock_name_str[0].data = sock_name
        sock_name_str[0].len = #sock_name

        C.ngx_http_lua_kong_ffi_socket_close_unix_listening(sock_name_str)

        return true
    end

    if type(sock_name) == "number" then
        return nil, "inet port is not supported now"
    end

    return nil, "sock_name must be number or string"
end

--local worker_pid = ngx.worker.pid
--local worker_count = ngx.worker.count

local _worker_id = ngx.worker.id()
--local _worker_pid = worker_pid()
--local _worker_count = worker_count()

local DEFAULT_SERVER_ID = 0
local DEFAULT_UNIX_SOCK = "unix:" .. ngx.config.prefix() ..
                          "worker_events.sock"
local DEFAULT_UNIQUE_TIMEOUT = 5
local MAX_UNIQUE_EVENTS = 1024

local _opts
local _clients
local _uniques

local _M = {
    _VERSION = '0.0.1',
}
--local mt = { __index = _M, }

local function is_timeout(err)
  return err and str_sub(err, -7) == "timeout"
end

-- opts = {server_id = n, listening = 'unix:...', timeout = n,}
function _M.configure(opts)
  assert(type(opts) == "table", "Expected a table, got "..type(opts))

  _opts = opts

  if not _opts.server_id then
    _opts.server_id = DEFAULT_SERVER_ID
  end

  if not _opts.listening then
    _opts.listening = DEFAULT_UNIX_SOCK
  end

  -- only enable listening on special worker id
  if _worker_id ~= _opts.server_id then
      close_listening(_opts.listening)
      return true
  end

  local err

  _uniques, err = lrucache.new(MAX_UNIQUE_EVENTS)
  if not _uniques then
    error("failed to create the events cache: " .. (err or "unknown"))
  end

  _clients = setmetatable({}, { __mode = "k", })

  return true
end

function _M.run()
  local conn, err = server:new()

  if not conn then
      log(ERR, "failed to init socket: ", err)
      exit(444)
  end

  local queue = que.new()

  _clients[conn] = queue

  local read_thread = spawn(function()
    while not exiting() do
      local data, err = conn:recv_frame()

      if exiting() then
        -- try to close ASAP
        close_listening(_opts.listening)
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
        return nil, "did not receive frame from client"
      end

      local d, err

      d, err = cjson.decode(data)
      if not d then
        log(ERR, "worker-events: failed decoding json event data: ", err)
        goto continue
      end

      local typ = d.typ

      -- unique event
      local unique = typ.unique
      if unique then
        if _uniques:get(unique) then
          --log(DEBUG, "unique event is duplicate: ", unique)
          goto continue
        end

        _uniques:set(unique, 1, _opts.timeout or DEFAULT_UNIQUE_TIMEOUT)
      end

      -- broadcast to all/unique workers
      local n = 0
      for _, q in pairs(_clients) do
        q.enqueue(d.data)
        n = n + 1

        if unique then
          break
        end
      end

      log(DEBUG, "event published to ", n, " workers")

      ::continue::
    end -- while not exiting
  end)  -- read_thread

  local write_thread = spawn(function()
    while not exiting() do
      local payload, err = queue.wait(5)

      if exiting() then
        return
      end

      if not payload then
        if not is_timeout(err) then
          return nil, "semaphore wait error: " .. err
        end

        -- timeout, send ping?
        goto continue
      end

      local _, err = conn:send_frame(payload)
      if err then
          log(ERR, "failed to send: ", err)
      end

      ::continue::
    end -- while not exiting
  end)  -- write_thread

  local ok, err, perr = wait(write_thread, read_thread)

  _clients[conn] = nil

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

