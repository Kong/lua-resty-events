# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 7) + 1;

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
#master_on();
#workers(2);
run_tests();

__DATA__

=== TEST 1: posting events and handling events, broadcast and local
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
        init_by_lua_block {
            local opts = {
                --broker_id = 0,
                listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
            }

            local ev = require("resty.events").new(opts)
            if not ev then
                ngx.log(ngx.ERR, "failed to new events")
            end

            _G.ev = ev
        }
        init_worker_by_lua_block {
            local ev = _G.ev
            local ok, err = ev:init_worker()
            if not ok then
                ngx.log(ngx.ERR, "failed to init_worker events: ", err)
            end

            ev:subscribe("*", "*", function(data, event, source, wid)
                ngx.log(ngx.DEBUG, "worker-events: handler event;  ", "source=",source,", event=",event, ", wid=", wid,
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

                ev:publish("all", "content_by_lua", "request1", "01234567890")
                ev:publish("current", "content_by_lua", "request2", "01234567890")
                ev:publish("all", "content_by_lua", "request3", "01234567890")

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
--- no_error_log
[error]
[crit]
[alert]
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=content_by_lua, event=request2, wid=nil
worker-events: handler event;  source=content_by_lua, event=request2, wid=nil, data=01234567890
worker-events: handling event; source=content_by_lua, event=request1, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, wid=\d+, data=01234567890$/



=== TEST 2: worker.events handling remote events
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
        init_by_lua_block {
            local opts = {
                --broker_id = 0,
                listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
            }

            local ev = require("resty.events").new(opts)
            if not ev then
                ngx.log(ngx.ERR, "failed to new events")
            end

            _G.ev = ev
        }
        init_worker_by_lua_block {
            local ev = _G.ev
            local ok, err = ev:init_worker()
            if not ok then
                ngx.log(ngx.ERR, "failed to init_worker events: ", err)
            end

            ev:subscribe("*", "*", function(data, event, source, wid)
                ngx.log(ngx.DEBUG, "worker-events: handler event;  ", "source=",source,", event=",event, ", wid=", wid,
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

                ev:publish("all", "content_by_lua", "request1", "01234567890")
                ev:publish("current", "content_by_lua", "request2", "01234567890")
                ev:publish("all", "content_by_lua", "request3", "01234567890")

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
--- no_error_log
[error]
[crit]
[alert]
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=content_by_lua, event=request2, wid=nil
worker-events: handler event;  source=content_by_lua, event=request2, wid=nil, data=01234567890
worker-events: handling event; source=content_by_lua, event=request1, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, wid=\d+, data=01234567890$/



=== TEST 3: worker.events 'one' being done, and only once
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
        init_by_lua_block {
            local opts = {
                unique_timeout = 0.04,
                --broker_id = 0,
                listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
            }

            local ev = require("resty.events").new(opts)
            if not ev then
                ngx.log(ngx.ERR, "failed to new events")
            end

            _G.ev = ev
        }
        init_worker_by_lua_block {
            local ev = _G.ev
            local ok, err = ev:init_worker()
            if not ok then
                ngx.log(ngx.ERR, "failed to init_worker events: ", err)
            end

            ev:subscribe("*", "*", function(data, event, source, wid)
                ngx.log(ngx.DEBUG, "worker-events: handler event;  ", "source=",source,", event=",event, ", wid=", wid,
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

                ev:publish("all", "content_by_lua", "request1", "01234567890")
                ev:publish("unique_value", "content_by_lua", "request2", "01234567890")
                ev:publish("unique_value", "content_by_lua", "request3", "01234567890")

                ngx.sleep(0.1) -- wait for unique timeout to expire

                ev:publish("unique_value", "content_by_lua", "request4", "01234567890")
                ev:publish("unique_value", "content_by_lua", "request5", "01234567890")
                ev:publish("all", "content_by_lua", "request6", "01234567890")

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
unique event is duplicate on worker #0: unique_value
--- no_error_log
[error]
[crit]
[alert]
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=content_by_lua, event=request1, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request2, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request4, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request4, wid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request6, wid=\d+
worker-events: handler event;  source=content_by_lua, event=request6, wid=\d+, data=01234567890$/
