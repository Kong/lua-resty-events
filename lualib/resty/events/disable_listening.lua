require "resty.core.base" -- for ngx_str_t

local ffi = require "ffi"
local C = ffi.C

local NGX_OK = ngx.OK

ffi.cdef[[
    int ngx_lua_ffi_disable_listening_unix_socket(ngx_str_t *sock_name);
]]

local sock_name_str = ffi.new("ngx_str_t[1]")

local disabled

return function(sock_name)
    if disabled then
        return true
    end

    sock_name_str[0].data = sock_name
    sock_name_str[0].len = #sock_name

    local rc = C.ngx_lua_ffi_disable_listening_unix_socket(sock_name_str)
    if rc ~= NGX_OK then
        return nil, "failed to disable listening: " .. sock_name
    end

    disabled = true

    return true
end
