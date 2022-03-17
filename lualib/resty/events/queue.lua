local semaphore = require "ngx.semaphore"

local assert = assert
local setmetatable = setmetatable
local table_insert = table.insert
local table_remove = table.remove


local _M = {}
local _MT = { __index = _M, }


function _M.new()
  local self = {
    semaphore = assert(semaphore.new()),
  }

  return setmetatable(self, _MT)
end


function _M:push(item)
  table_insert(self, item)
  self.semaphore:post()
end


function _M:pop()
  local ok, err = self.semaphore:wait(5)
  if not ok then
    return nil, err
  end

  return assert(table_remove(self, 1))
end


return _M
