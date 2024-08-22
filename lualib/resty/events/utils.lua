local str_sub = string.sub
local ngx_worker_id = ngx.worker.id


local function is_timeout(err)
    return err and str_sub(err, -7) == "timeout"
end


local function is_closed(err)
    return err and (str_sub(err, -6) == "closed" or
                    str_sub(err, -11) == "broken pipe")
end


local function get_worker_id()
    return ngx_worker_id() or -1
end


local function get_worker_name(worker_id)
    return worker_id == -1 and
           "privileged agent" or "worker #" .. worker_id
end


return {
    is_timeout = is_timeout,
    is_closed = is_closed,

    get_worker_id = get_worker_id,
    get_worker_name = get_worker_name,
}
