local str_sub = string.sub


local function is_timeout(err)
    return err and str_sub(err, -7) == "timeout"
end


local function is_closed(err)
    return err and (str_sub(err, -6) == "closed" or
                    str_sub(err, -11) == "broken pipe")
end


return {
    is_timeout = is_timeout,
    is_closed = is_closed,
}
