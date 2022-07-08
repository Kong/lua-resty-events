# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 8) + 2;

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
master_on();
workers(3);
run_tests();

__DATA__


=== TEST 1: posting events and handling events, broadcast
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    init_by_lua_block {
        local process = require "ngx.process"
        process.enable_privileged_agent(100)
    }
    init_worker_by_lua_block {
        local opts = {
            broker_id = 2,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        }

        local ev = require("resty.events").new(opts)
        if not ev then
            ngx.log(ngx.ERR, "failed to new events")
        end

        local ok, err = ev:init_worker()
        if not ok then
            ngx.log(ngx.ERR, "failed to init_worker events: ", err)
        end

        ev:subscribe("*", "*", function(data, event, source, wid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", wid=", wid,
                    ", data=", data)
                end)

        _G.ev = ev
    }

    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                 _G.ev:run()
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local ev = _G.ev

            ev:publish("all", "content_by_lua", "request1", "01234567890")

            ngx.say("ok")
        }
    }
--- request
GET /test
--- response_body
ok
--- error_log
event published to 4 workers
setproctitle: "nginx: privileged agent process"
--- no_error_log
[error]
[crit]
[alert]
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=content_by_lua, event=request1, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request1, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request1, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request1, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890$/


=== TEST 2: posting events and handling events, local
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    init_by_lua_block {
        local process = require "ngx.process"
        process.enable_privileged_agent(100)
    }
    init_worker_by_lua_block {
        local opts = {
            broker_id = 2,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        }

        local ev = require("resty.events").new(opts)
        if not ev then
            ngx.log(ngx.ERR, "failed to new events")
        end

        local ok, err = ev:init_worker()
        if not ok then
            ngx.log(ngx.ERR, "failed to init_worker events: ", err)
        end

        ev:subscribe("*", "*", function(data, event, source, wid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ", "source=", source,", event=", event, ", wid=", wid,
                    ", data=", data)
                end)

        _G.ev = ev
    }

    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                 _G.ev:run()
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local ev = _G.ev

            ev:publish("current", "content_by_lua","request1","01234567890")
            ev:publish("current", "content_by_lua","request2","01234567890")
            ev:publish("all", "content_by_lua","request3","01234567890")

            ngx.say("ok")
        }
    }
--- request
GET /test
--- response_body
ok
--- error_log
event published to 4 workers
setproctitle: "nginx: privileged agent process"
--- no_error_log
[error]
[crit]
[alert]
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=content_by_lua, event=request1, wid=nil
worker-events: handler event;  source=content_by_lua, event=request1, wid=nil, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, wid=nil
worker-events: handler event;  source=content_by_lua, event=request2, wid=nil, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, wid=\d+, data=01234567890$/


=== TEST 3: worker.events 'one' being done, and only once
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    init_by_lua_block {
        local process = require "ngx.process"
        process.enable_privileged_agent(100)
    }
    init_worker_by_lua_block {
        local opts = {
            unique_timeout = 0.04,
            --broker_id = 0,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        }

        local ev = require("resty.events").new(opts)
        if not ev then
            ngx.log(ngx.ERR, "failed to new events")
        end

        local ok, err = ev:init_worker()
        if not ok then
            ngx.log(ngx.ERR, "failed to init_worker events: ", err)
        end

        ev:subscribe("*", "*", function(data, event, source, wid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ", "source=", source, ", event=", event, ", wid=", wid,
                    ", data=", tostring(data))
                end)

        _G.ev = ev
    }

    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                 _G.ev:run()
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local ev = _G.ev

            ev:publish("all", "content_by_lua","request1","01234567890")

            ngx.sleep(0.05) -- wait for logs

            ev:publish("unique_value", "content_by_lua", "request2", "01234567890")
            ev:publish("unique_value", "content_by_lua", "request3", "01234567890")

            ngx.sleep(0.1) -- wait for unique timeout to expire

            ev:publish("unique_value", "content_by_lua", "request4", "01234567890")
            ev:publish("unique_value", "content_by_lua", "request5", "01234567890")

            ngx.sleep(0.05) -- wait for logs

            ev:publish("all", "content_by_lua", "request6", "01234567890")

            ngx.say("ok")
        }
    }
--- request
GET /test
--- response_body
ok
--- error_log
event published to 1 workers
unique event is duplicate: unique_value
event published to 4 workers
setproctitle: "nginx: privileged agent process"
--- no_error_log
[error]
[crit]
[alert]
--- grep_error_log eval: qr/worker-events: handler .*/
--- grep_error_log_out eval
qr/^worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request2, wid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request4, wid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request6, wid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request6, wid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request6, wid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request6, wid=\d+, data=01234567890$/



