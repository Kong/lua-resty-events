local cjson = require "cjson.safe"
local codec = require "resty.events.codec"
local semaphore = require "ngx.semaphore"

local table_new = require "table.new"

local assert = assert
local setmetatable = setmetatable
local math_min = math.min

local decode = codec.decode
local cjson_encode = cjson.encode

local _M = {}
local _MT = { __index = _M, }

local DEFAULT_QUEUE_LEN = 4096

function _M.new(max_len, name)
    local self = {
        semaphore = assert(semaphore.new()),
        max = max_len,

        elts = table_new(math_min(max_len, DEFAULT_QUEUE_LEN), 0),
        first = 0,
        last = -1,

        -- debug
        name = name,
        outcome = 0,
        income = 0,
    }

    ngx.log(ngx.DEBUG, "events-debug [init queue]: name=", name, ", max_len=", self.max_len)

    return setmetatable(self, _MT)
end


function _M:push(item)
    local last = self.last

    local count = last - self.first + 1

    ngx.log(ngx.DEBUG, "events-debug [enqueue]: name=", self.name, ", len=", count,
            ", income=", self.income, ", outcome=", self.outcome)

    if count >= self.max then
        return nil, "queue overflow"
    end

    last = last + 1
    self.last = last
    self.elts[last] = item

    self.income = self.income + 1

    self.semaphore:post()

    return true
end


function _M:pop()
    local ok, err = self.semaphore:wait(1)
    if not ok then
        return nil, err
    end

    local first = self.first

    if first > self.last then
        return nil, "queue is empty"
    end

    local item = self.elts[first]
    self.elts[first] = nil
    self.first = first + 1

    self.outcome = self.outcome + 1

    local count = self.last - self.first + 1

    ngx.log(ngx.DEBUG, "events-debug [dequeue]: name=", self.name, ", len=", count,
            ", income=", self.income, ", outcome=", self.outcome)

    return item
end


return _M
