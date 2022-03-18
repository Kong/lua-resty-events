# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

repeat_each(2);

plan tests => repeat_each() * (blocks() * 5);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
master_on();
workers(2);
run_tests();

__DATA__

=== TEST 1: sanity: send_frame, recv_frame
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
    init_worker_by_lua_block {
        local opts = {
            worker_id = 1,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        }
        local ok, err = require("resty.events.broker").configure(opts)
        if not ok then
            ngx.log(ngx.ERR, "failed to configure broker: ", err)
        end
    }

    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                 require("resty.events.broker").run()
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- request
GET /test
--- response_body
ok
--- no_error_log
[error]
[crit]
[alert]

