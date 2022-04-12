local semaphore = require "ngx.semaphore"

local assert = assert
local setmetatable = setmetatable
local table_insert = table.insert
local table_remove = table.remove


local _M = {}
local _MT = { __index = _M, }

local MAX_QUEUE_LEN = 1024

function _M.new()
    local self = {
        semaphore = assert(semaphore.new()),
        count = 0,
    }

    return setmetatable(self, _MT)
end


function _M:push(item)
    if self.count >= MAX_QUEUE_LEN then
        return nil, "queue overflow"
    end

    table_insert(self, item)
    self.count = self.count + 1

    self.semaphore:post()

    return true
end


function _M:pop()
    local ok, err = self.semaphore:wait(5)
    if not ok then
        return nil, err
    end

    local item = assert(table_remove(self, 1))
    self.count = self.count - 1

    return item
end


return _M
