local cjson = require "cjson.safe"
local que = require "resty.events.queue"
local callback = require "resty.events.callback"
local client = require("resty.events.protocol").client

local type = type
local assert = assert
local str_sub = string.sub
local random = math.random

local ngx = ngx
local log = ngx.log
local exiting = ngx.worker.exiting
local ERR = ngx.ERR
--local DEBUG = ngx.DEBUG

local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local wait = ngx.thread.wait

local timer_at = ngx.timer.at

local encode = cjson.encode
local decode = cjson.decode

local EMPTY_T = {}

local EVENT_T = {
  source = '',
  event = '',
  data = '',
  pid = '',
}

local PAYLOAD_T = {
  spec = EMPTY_T,
  data = '',
}

local SPEC_T = {
  unique = '',
}

local _M = {
  _VERSION = '0.1.0',
}

-- gen a random number [0.2, 2.0]
local function random_delay()
  return random(2, 20) / 10
end

local function is_timeout(err)
  return err and str_sub(err, -7) == "timeout"
end

local _worker_pid = ngx.worker.pid()

local _queue = que.new()
local _local_queue = que.new()

local _connected
local _opts

local communicate

communicate = function(premature)
  if premature then
    -- worker wants to exit
    return
  end

  local conn = assert(client:new())

  local ok, err = conn:connect(_opts.listening)
  if not ok then
    log(ERR, "failed to connect: ", err)

    -- try to reconnect broker
    assert(timer_at(random_delay(), function(premature)
      communicate(premature)
    end))

    return
  end

  _connected = true

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
        return nil, "did not receive event from broker"
      end

      local d, err = decode(data)
      if not d then
        return nil, "worker-events: failed decoding json event data: " .. err
      end

      -- got an event data, callback
      callback.do_event(d)

      ::continue::
    end -- while not exiting
  end)  -- read_thread

  local write_thread = spawn(function()
    while not exiting() do
      local payload, err = _queue:pop()

      if not payload then
        if not is_timeout(err) then
          return nil, "semaphore wait error: " .. err
        end

        -- timeout
        goto continue
      end

      if exiting() then
        return
      end

      local _, err = conn:send_frame(payload)
      if err then
        log(ERR, "failed to send event: ", err)
        return
      end

      ::continue::
    end -- while not exiting
  end)  -- write_thread

  local local_thread = spawn(function()
    while not exiting() do
      local data, err = _local_queue:pop()

      if not data then
        if not is_timeout(err) then
          return nil, "semaphore wait error: " .. err
        end

        -- timeout
        goto continue
      end

      if exiting() then
        return
      end

      -- got an event data, callback
      callback.do_event(data)

      ::continue::
    end -- while not exiting
  end)  -- local_thread

  local ok, err, perr = wait(write_thread, read_thread, local_thread)

  kill(write_thread)
  kill(read_thread)
  kill(local_thread)

  _connected = nil

  if not ok then
    log(ERR, "event worker failed: ", err)
  end

  if perr then
    log(ERR, "event worker failed: ", perr)
  end

  if not exiting() then
    assert(timer_at(random_delay(), function(premature)
      communicate(premature)
    end))
  end
end

function _M.configure(opts)
  assert(not _opts)

  _opts = opts

  assert(timer_at(0, function(premature)
    communicate(premature)
  end))

  return true
end

-- posts a new event
local function post_event(source, event, data, spec)
  local json, err

  EVENT_T.source = source
  EVENT_T.event = event
  EVENT_T.data = data
  EVENT_T.pid = _worker_pid

  -- encode event info
  json, err = encode(EVENT_T)

  if not json then
    return nil, err
  end

  PAYLOAD_T.spec = spec or EMPTY_T
  PAYLOAD_T.data = json

  -- encode spec info
  json, err = encode(PAYLOAD_T)

  if not json then
    return nil, err
  end

  local ok, err = _queue:push(json)
  if not ok then
    return nil, "failed to publish event: " .. err
  end

  return true
end

function _M.post(source, event, data, unique)
  if not _connected then
    return nil, "not initialized yet"
  end

  if type(source) ~= "string" or source == "" then
    return nil, "source is required"
  end

  if type(event) ~= "string" or event == "" then
    return nil, "event is required"
  end

  SPEC_T.unique = unique

  local ok, err = post_event(source, event, data, SPEC_T)
  if not ok then
    log(ERR, "post event: ", err)
    return nil, err
  end

  return true
end

function _M.post_local(source, event, data)
  if not _connected then
    return nil, "not initialized yet"
  end

  if type(source) ~= "string" or source == "" then
    return nil, "source is required"
  end

  if type(event) ~= "string" or event == "" then
    return nil, "event is required"
  end

  local ok, err = _local_queue:push({
    source = source,
    event = event,
    data = data,
  })

  if not ok then
    return nil, "failed to publish event: " .. err
  end

  return true
end

-- only for test
-- _M.register = callback.register
-- _M.register_weak = callback.register_weak
-- _M.unregister = callback.unregister

return _M
