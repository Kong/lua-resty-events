local cjson = require "cjson.safe"
local que = require "resty.events.queue"
local callback = require "resty.events.callback"
local client = require("resty.events.protocol").client

local type = type
local assert = assert
local str_sub = string.sub

local ngx = ngx
local sleep = ngx.sleep
local log = ngx.log
local exiting = ngx.worker.exiting
local ERR = ngx.ERR
--local DEBUG = ngx.DEBUG

local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local wait = ngx.thread.wait

local timer_at = ngx.timer.at

local encode = cjson.encode

local EMPTY_T = {}
local CONNECTION_DELAY = 0.1
local POST_RETRY_DELAY = 0.1

local _M = {
    _VERSION = '0.1.0',
}

local function is_timeout(err)
  return err and str_sub(err, -7) == "timeout"
end

local _worker_pid = ngx.worker.pid()

local _queue = que.new()
local _local_queue = que.new()

local _configured
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
    assert(timer_at(CONNECTION_DELAY, function(premature)
      communicate(premature)
    end))

    return
  end

  _configured = true

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

      -- got an event data, callback
      callback.do_event_json(data)

      ::continue::
    end -- while not exiting
  end)  -- read_thread

  local write_thread = spawn(function()
    while not exiting() do
      local payload, err = _queue:pop()

      if exiting() then
        return
      end

      if not payload then
        if not is_timeout(err) then
          return nil, "semaphore wait error: " .. err
        end

        -- timeout
        goto continue
      end

      local _, err = conn:send_frame(payload)
      if err then
        log(ERR, "failed to send event: ", err)

        -- try to post it again
        sleep(POST_RETRY_DELAY)

        local ok, err = _queue:push(payload)
        if not ok then
          log(ERR, "failed to publish event: ", err)
        end
      end

      ::continue::
    end -- while not exiting
  end)  -- write_thread

  local local_thread = spawn(function()
    while not exiting() do
      local data, err = _local_queue:pop()

      if exiting() then
        return
      end

      if not data then
        if not is_timeout(err) then
          return nil, "semaphore wait error: " .. err
        end

        -- timeout
        goto continue
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

  _configured = nil

  if not ok then
    log(ERR, "event worker failed: ", err)
  end

  if perr then
    log(ERR, "event worker failed: ", perr)
  end

  if not exiting() then
    assert(timer_at(CONNECTION_DELAY, function(premature)
      communicate(premature)
    end))
  end
end

function _M.configure(opts)
  _opts = opts

  assert(timer_at(0, function(premature)
    communicate(premature)
  end))

  return true
end

-- posts a new event
local function post_event(source, event, data, spec)
  local json, err

  -- encode event info
  json, err = encode({
    source = source,
    event = event,
    data = data,
    pid = _worker_pid,
  })

  if not json then
    return nil, err
  end

  -- encode spec info
  json, err = encode({
    spec = spec or EMPTY_T,
    data = json,
  })

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
  if not _configured then
    return nil, "not initialized yet"
  end

  if type(source) ~= "string" or source == "" then
    return nil, "source is required"
  end

  if type(event) ~= "string" or event == "" then
    return nil, "event is required"
  end

  local ok, err = post_event(source, event, data, {unique = unique})
  if not ok then
    log(ERR, "post event: ", err)
    return nil, err
  end

  return true
end

function _M.post_local(source, event, data)
  if not _configured then
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
