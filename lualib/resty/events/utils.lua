local str_sub = string.sub


local ngx = ngx -- luacheck: ignore
local ngx_worker_id = ngx.worker.id
local ngx_worker_count = ngx.worker.count


local function is_timeout(err)
    return err and str_sub(err, -7) == "timeout"
end


local function is_closed(err)
    return err and (str_sub(err, -6) == "closed" or
                    str_sub(err, -11) == "broken pipe")
end


local function get_worker_id()
    return ngx_worker_id() or -1  -- -1 represents priviledged worker
end


local function get_worker_name(worker_id)
    return worker_id == -1 and    -- -1 represents priviledged worker
           "privileged agent" or "worker #" .. worker_id
end


local function get_worker_count()
    return ngx_worker_count()
end


return {
    is_timeout = is_timeout,
    is_closed = is_closed,

    get_worker_id = get_worker_id,
    get_worker_name = get_worker_name,
    get_worker_count = get_worker_count,
}
