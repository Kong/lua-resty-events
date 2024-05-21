# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
master_process_enabled(1);
#log_level('warn');

repeat_each(2);

plan tests => repeat_each() * (blocks() * 10);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
#master_on();
#workers(2);
check_accum_error_log();
run_tests();

__DATA__

=== TEST 1: sanity: send_frame, recv_frame (with privileged agent)
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
        init_by_lua_block {
            local process = require "ngx.process"
            process.enable_privileged_agent(100)
        }
        init_worker_by_lua_block {
            local process = require "ngx.process"
            if process.type() ~= "privileged agent" then
                return
            end
            ngx.timer.at(0, function()
                local conn = require("resty.events.protocol").client.new()

                local ok, err = conn:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.log(ngx.ERR, "failed to connect: ", err)
                    return
                end

                local bytes, err = conn:send_frame("hello")
                if err then
                    ngx.log(ngx.ERR, "failed to send data: ", err)
                end

                local data, err = conn:recv_frame()
                if not data or err then
                    ngx.log(ngx.ERR, "failed to recv data: ", err)
                    return
                end

                ngx.log(ngx.DEBUG, data)
                ngx.log(ngx.DEBUG, "cli recv len: ", #data)
            end)
        }
        server {
            listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
            content_by_lua_block {
                local conn, err = require("resty.events.protocol").server.new()
                if not conn then
                    ngx.say("failed to init socket: ", err)
                    return
                end

                ngx.log(ngx.DEBUG, "Worker ID: ", conn.info.id)

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
            ngx.say("world")
        }
    }
--- request
GET /test
--- response_body
world
--- error_log
Worker ID: -1
srv recv data: hello
srv send data: world
world
cli recv len: 5
--- no_error_log
[error]
[crit]
[alert]
