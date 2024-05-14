local semaphore = require "ngx.semaphore"
local table_new = require "table.new"


local assert = assert
local setmetatable = setmetatable
local math_min = math.min


local _M = {}
local _MT = { __index = _M, }


local MAX_QUEUE_PREALLOCATE = 4096


function _M.new(max_len)
    local self = {
        semaphore = assert(semaphore.new()),
        max = max_len,

        elts = table_new(math_min(max_len, MAX_QUEUE_PREALLOCATE), 0),
        first = 0,
        last = -1,
    }

    return setmetatable(self, _MT)
end


function _M:push(item)
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
    return item
end


return _M
