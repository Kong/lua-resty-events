local semaphore = require "ngx.semaphore"
local table_new = require "table.new"


local assert = assert
local setmetatable = setmetatable
local math_min = math.min


local MAX_QUEUE_PREALLOCATE = 4096


local _MT = {}
_MT.__index = _MT


function _MT:push(item)
    local last = self.last
    if last - self.first + 1 >= self.max then
        return nil, "queue overflow"
    end

    last = last + 1
    self.last = last
    self.elts[last] = item

    self.semaphore:post()

    return true
end


function _MT:push_front(item)
    local first = self.first
    if first > self.last then
        return self:push(item)
    end

    first = first - 1
    self.first = first
    self.elts[first] = item

    self.semaphore:post()

    return true
end


function _MT:pop()
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
    return item
end


local _M = {}


function _M.new(max_len)
    local self = setmetatable({
        semaphore = assert(semaphore.new()),
        max = max_len,

        elts = table_new(math_min(max_len, MAX_QUEUE_PREALLOCATE), 0),
        first = 0,
        last = -1,
    }, _MT)

    return self
end


return _M
