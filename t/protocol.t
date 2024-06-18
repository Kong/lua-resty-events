# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

repeat_each(2);

plan tests => repeat_each() * (blocks() * 9) - 6;

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
#master_on();
#workers(2);
run_tests();

__DATA__

=== TEST 1: sanity: send_frame, recv_frame
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                local conn, err = require("resty.events.protocol").server.new()
                if not conn then
                    ngx.say("failed to init socket: ", err)
                    return
                end

                ngx.log(ngx.DEBUG, "Upgrade: ", ngx.var.http_upgrade)

                local data, err = conn:recv_frame()
                if not data or err then
                    ngx.say("failed to recv data: ", err)
                    return
                end
                ngx.log(ngx.DEBUG, "srv recv data: ", data)

                local bytes, err = conn:send_frame("world")
                if err then
                    ngx.say("failed to send data: ", err)
                    return
                end

                ngx.log(ngx.DEBUG, "srv send data: world")
            }
        }
    }

--- config
    location = /test {
        content_by_lua_block {
            local conn = require("resty.events.protocol").client.new()

            local ok, err = conn:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            local bytes, err = conn:send_frame("hello")
            if err then
                ngx.say("failed to send data: ", err)
            end

            local data, err = conn:recv_frame()
            if not data or err then
                ngx.say("failed to recv data: ", err)
                return
            end

            ngx.say(data)
            ngx.log(ngx.DEBUG, "cli recv len: ", #data)
        }
    }
--- request
GET /test
--- response_body
world
--- error_log
Upgrade: Kong-Worker-Events/1
srv recv data: hello
srv send data: world
cli recv len: 5
--- no_error_log
[error]
[crit]
[alert]



=== TEST 2: client checks unix prefix
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
--- config
    location = /test {
        content_by_lua_block {
            local conn = require("resty.events.protocol").client.new()

            ngx.log(ngx.DEBUG, "addr is nginx.sock")

            local ok, err = conn:connect("nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("ok")
        }
    }
--- request
GET /test
--- response_body
failed to connect: addr must start with "unix:"
--- error_log
addr is nginx.sock
--- no_error_log
[error]
[crit]
[alert]
