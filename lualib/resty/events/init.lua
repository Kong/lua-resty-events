local callback  = require "resty.events.callback"
local broker    = require "resty.events.broker"
local worker    = require "resty.events.worker"

local ngx = ngx
local str_sub  = string.sub

local _M = {
    _VERSION = '0.1.0',
}

local UNIX_PREFIX = "unix:"

local _worker_id = ngx.worker.id()
local _worker_count = ngx.worker.count()

local close_listening
do
  local ffi = require "ffi"
  local C = ffi.C

  local UNIX_PREFIX = "unix:"
  local NGX_OK = ngx.OK

  ffi.cdef[[
    typedef struct {
        size_t           len;
        unsigned char   *data;
    } ngx_str_t;

    int ngx_lua_ffi_close_listening_unix_socket(ngx_str_t *sock_name);
  ]]

  local sock_name_str = ffi.new("ngx_str_t[1]")

  close_listening = function(sock_name)
    sock_name = str_sub(sock_name, #UNIX_PREFIX + 1)

    sock_name_str[0].data = sock_name
    sock_name_str[0].len = #sock_name

    local rc = C.ngx_lua_ffi_close_listening_unix_socket(sock_name_str)

    return rc == NGX_OK
  end
end

-- opts = {worker_id = n, listening = 'unix:...', timeout = n,}
function _M.configure(opts)
  assert(type(opts) == "table", "Expected a table, got "..type(opts))

  if not opts.worker_id then
    return nil, '"worker_id" option required to start'
  end

  if type(opts.worker_id) ~= "number" then
    return nil, '"worker_id" option must be a number'
  end

  if opts.worker_id < 0 or opts.worker_id >= _worker_count then
    return nil, '"worker_id" option is invalid'
  end

  if not opts.listening then
    return nil, '"listening" option required to start'
  end

  if type(opts.listening) ~= "string" then
    return nil, '"listening" option must be a string'
  end

  if str_sub(opts.listening, 1, #UNIX_PREFIX) ~= UNIX_PREFIX then
    return nil, '"listening" option must start with' .. UNIX_PREFIX
  end

  local is_broker = _worker_id == opts.worker_id

  local ok, err

  -- only enable listening on special worker id
  if is_broker then
    ok, err = broker.configure(opts)
    if not ok then
      return nil, err
    end
  else
    ok, err = close_listening(opts.listening)
    if not ok then
      return nil, err
    end
  end

  ok, err = worker.configure(opts)
  if not ok then
    return nil, err
  end

  return true
end

-- compatible with lua-resty-worker-events
function _M.poll()
  return "done"
end

_M.run = broker.run

_M.post = worker.post
_M.post_local = worker.post_local
_M.poll = worker.poll

_M.register = callback.register
_M.register_weak = callback.register_weak
_M.unregister = callback.unregister

-- for test only
_M.close_listening = close_listening

return _M
