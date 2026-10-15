local ffi = require "ffi"


ffi.cdef[[
    unsigned int ngx_lua_ffi_events_generation(void);
    unsigned int ngx_lua_ffi_events_pid_generation(int pid);
]]


local C = ffi.C


local _M = {}


-- the generation shared by every worker of this configuration cycle
function _M.mine()
    return C.ngx_lua_ffi_events_generation()
end


-- the generation of worker `pid`, or 0 when unknown
function _M.of_pid(pid)
    return C.ngx_lua_ffi_events_pid_generation(pid)
end


return _M
