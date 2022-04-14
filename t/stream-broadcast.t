# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 7) + 2;

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
master_on();
workers(4);
run_tests();

__DATA__


=== TEST 1: posting events and handling events, broadcast
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
        init_worker_by_lua_block {
            local opts = {
                broker_id = 3,
                listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
            }

            local ev = require("resty.events").new()
            local ok, err = ev:configure(opts)
            if not ok then
                ngx.log(ngx.ERR, "failed to configure events: ", err)
            end

            ev:subscribe("*", "*", function(data, event, source, pid)
                ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                        ", data=", data)
                    end)

            _G.ev = ev
        }

        server {
            listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
            content_by_lua_block {
                 _G.ev:run()
            }
        }
        server {
            listen 1985;
            content_by_lua_block {
                local ev = _G.ev

                ev:publish("all", "content_by_lua","request1","01234567890")

                ngx.say("ok")
            }
    }
    }
--- config
    location = /test {
        content_by_lua_block {
            local sock, err = ngx.socket.tcp()
            assert(sock, err)

            local ok, err = sock:connect("127.0.0.1", 1985)
            if not ok then
                ngx.say("connect to stream server error: ", err)
                return
            end

            local data, err = sock:receive("*a")
            if not data then
                sock:close()
                ngx.say("receive stream response error: ", err)
                return
            end

            ngx.print(data)
        }
    }
--- request
GET /test
--- response_body
ok
--- error_log
event published to 4 workers
--- no_error_log
[error]
[crit]
[alert]
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890$/


=== TEST 2: posting events and handling events, local
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
        init_worker_by_lua_block {
            local opts = {
                broker_id = 3,
                listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
            }

            local ev = require("resty.events").new()
            local ok, err = ev:configure(opts)
            if not ok then
                ngx.log(ngx.ERR, "failed to configure events: ", err)
            end

            ev:subscribe("*", "*", function(data, event, source, pid)
                ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                        ", data=", data)
                    end)

            _G.ev = ev
        }

        server {
            listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
            content_by_lua_block {
                 _G.ev:run()
            }
        }
        server {
            listen 1985;
            content_by_lua_block {
                local ev = _G.ev

                ev:publish("current", "content_by_lua","request1","01234567890")
                ev:publish("current", "content_by_lua","request2","01234567890")
                ev:publish("all", "content_by_lua","request3","01234567890")

                ngx.say("ok")
            }
    }
    }
--- config
    location = /test {
        content_by_lua_block {
            local sock, err = ngx.socket.tcp()
            assert(sock, err)

            local ok, err = sock:connect("127.0.0.1", 1985)
            if not ok then
                ngx.say("connect to stream server error: ", err)
                return
            end

            local data, err = sock:receive("*a")
            if not data then
                sock:close()
                ngx.say("receive stream response error: ", err)
                return
            end

            ngx.print(data)
        }
    }
--- request
GET /test
--- response_body
ok
--- error_log
event published to 4 workers
--- no_error_log
[error]
[crit]
[alert]
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=content_by_lua, event=request1, pid=nil
worker-events: handler event;  source=content_by_lua, event=request1, pid=nil, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, pid=nil
worker-events: handler event;  source=content_by_lua, event=request2, pid=nil, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/


=== TEST 3: worker.events 'one' being done, and only once
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
        init_worker_by_lua_block {
            local opts = {
                unique_timeout = 0.04,
                --broker_id = 0,
                listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
            }

            local ev = require("resty.events").new()
            local ok, err = ev:configure(opts)
            if not ok then
                ngx.log(ngx.ERR, "failed to configure events: ", err)
            end

            ev:subscribe("*", "*", function(data, event, source, pid)
                ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                        ", data=", tostring(data))
                    end)

            _G.ev = ev
        }

        server {
            listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
            content_by_lua_block {
                 _G.ev:run()
            }
        }
        server {
            listen 1985;
            content_by_lua_block {
                local ev = _G.ev

                ev:publish("all", "content_by_lua","request1","01234567890")

                ngx.sleep(0.05) -- wait for logs

                ev:publish("unique_value", "content_by_lua","request2","01234567890")
                ev:publish("unique_value", "content_by_lua","request3","01234567890")

                ngx.sleep(0.1) -- wait for unique timeout to expire

                ev:publish("unique_value", "content_by_lua","request4","01234567890")
                ev:publish("unique_value", "content_by_lua","request5","01234567890")

                ngx.sleep(0.05) -- wait for logs

                ev:publish("all", "content_by_lua","request6","01234567890")

                ngx.say("ok")
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local sock, err = ngx.socket.tcp()
            assert(sock, err)

            local ok, err = sock:connect("127.0.0.1", 1985)
            if not ok then
                ngx.say("connect to stream server error: ", err)
                return
            end

            local data, err = sock:receive("*a")
            if not data then
                sock:close()
                ngx.say("receive stream response error: ", err)
                return
            end

            ngx.print(data)
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
--- no_error_log
[error]
[crit]
[alert]
--- grep_error_log eval: qr/worker-events: handler .*/
--- grep_error_log_out eval
qr/^worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request4, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request6, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request6, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request6, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request6, pid=\d+, data=01234567890$/



