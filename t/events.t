# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 6);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
#master_on();
#workers(2);
run_tests();

__DATA__

=== TEST 1: posting events and handling events, broadcast and local
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
    init_worker_by_lua_block {
        local opts = {
            worker_id = 0,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        }

        local eb = require "resty.events.broker"
        local ok, err = eb.configure(opts)
        if not ok then
            ngx.log(ngx.ERR, "failed to configure broker: ", err)
        end

        local ew = require "resty.events.worker"
        local ok, err = ew.configure(opts)
        if not ok then
            ngx.log(ngx.ERR, "failed to configure worker: ", err)
        end

        ew.register(function(data, event, source, pid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                    ", data=", data)
                end)
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
            local ew = require "resty.events.worker"

            ew.post("content_by_lua","request1","01234567890")
            ew.post_local("content_by_lua","request2","01234567890")
            ew.post("content_by_lua","request3","01234567890")

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
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=content_by_lua, event=request2, pid=nil
worker-events: handler event;  source=content_by_lua, event=request2, pid=nil, data=01234567890
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/

