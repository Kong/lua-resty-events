# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 7);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
#master_on();
#workers(2);
run_tests();

__DATA__

=== TEST 1: posting events and handling events, broadcast and local
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    init_worker_by_lua_block {
        local opts = {
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

        assert(not ev:is_ready())

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

            assert(ev:is_ready())

            ev:publish("all", "content_by_lua","request1","01234567890")
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
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    init_worker_by_lua_block {
        local opts = {
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

        assert(not ev:is_ready())

        ev:subscribe("*", "*", function(data, event, source, wid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", wid=", wid,
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

            assert(ev:is_ready())

            ev:publish("all", "content_by_lua","request1","01234567890")
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
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
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

        assert(not ev:is_ready())

        ev:subscribe("*", "*", function(data, event, source, wid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", wid=", wid,
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

            assert(ev:is_ready())

            ev:publish("all", "content_by_lua","request1","01234567890")
            ev:publish("unique_value", "content_by_lua","request2","01234567890")
            ev:publish("unique_value", "content_by_lua","request3","01234567890")

            ngx.sleep(0.1) -- wait for unique timeout to expire

            ev:publish("unique_value", "content_by_lua","request4","01234567890")
            ev:publish("unique_value", "content_by_lua","request5","01234567890")
            ev:publish("all", "content_by_lua","request6","01234567890")

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


=== TEST 4: publish events at anywhere
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    init_worker_by_lua_block {
        local opts = {
            --broker_id = 0,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        }

        local ev = require("resty.events").new(opts)
        if not ev then
            ngx.log(ngx.ERR, "failed to new events")
        end

        ev:publish("all", "content_by_lua","request1","01234567890")

        local ok, err = ev:init_worker()
        if not ok then
            ngx.log(ngx.ERR, "failed to init_worker events: ", err)
        end

        assert(not ev:is_ready())

        ev:publish("current", "content_by_lua","request2","01234567890")

        ev:subscribe("*", "*", function(data, event, source, wid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", wid=", wid,
                    ", data=", tostring(data))
                end)

        ev:publish("all", "content_by_lua","request3","01234567890")

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
            ngx.say("ok")
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


=== TEST 5: configure with wrong params
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
--- config
    location = /test {
        content_by_lua_block {
            local function trim(str)
                return string.sub(str, #"lualib/resty/events/init.lua:62: " + 1)
            end

            local ev = require("resty.events")

            local ok, err = pcall(ev.new, {broker_id = "1"})
            assert(not ok)
            ngx.say(trim(err))

            local ok, err = pcall(ev.new, {broker_id = -1})
            assert(not ok)
            ngx.say(trim(err))

            local ok, err = pcall(ev.new, {broker_id = 2})
            assert(not ok)
            ngx.say(trim(err))

            local ok, err = pcall(ev.new, {})
            assert(not ok)
            ngx.say(trim(err))

            local ok, err = pcall(ev.new, {listening = 123})
            assert(not ok)
            ngx.say(trim(err))

            local ok, err = pcall(ev.new, {listening = "/tmp/xxx.sock"})
            assert(not ok)
            ngx.say(trim(err))

            local ok, err = pcall(ev.new, {listening = "unix:x", unique_timeout = '1'})
            assert(not ok)
            ngx.say(trim(err))

            local ok, err = pcall(ev.new, {listening = "unix:x", unique_timeout = -1})
            assert(not ok)
            ngx.say(trim(err))

            local ok, err = pcall(ev.new, {listening = "unix:x", max_queue_len = "1"})
            assert(not ok)
            ngx.say(trim(err))

            local ok, err = pcall(ev.new, {listening = "unix:x", max_queue_len = -1})
            assert(not ok)
            ngx.say(trim(err))
        }
    }
--- request
GET /test
--- response_body
"worker_id" option must be a number
"worker_id" option is invalid
"worker_id" option is invalid
"listening" option required to start
"listening" option must be a string
"listening" option must start with unix:
optional "unique_timeout" option must be a number
"unique_timeout" must be greater than 0
"max_queue_len" option must be a number
"max_queue_len" option is invalid
--- no_error_log
[error]
[crit]
[alert]
[emerg]


=== TEST 6: publish events exceeding 65535 bytes
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    init_worker_by_lua_block {
        local opts = {
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

        assert(not ev:is_ready())

        ev:subscribe("*", "*", function(data, event, source, wid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", wid=", wid,
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

            assert(ev:is_ready())

            local ok, err = ev:publish("all", "content_by_lua", "request1",
                                       string.rep("a", 65537))
            ngx.say(err)

            ok, err = ev:publish("unique_hash", "content_by_lua", "request2",
                                       string.rep("a", 65537))
            ngx.say(err)

            ok, err = ev:publish("current", "content_by_lua","request3","01234567890")
            ngx.say(err)

            ngx.say("ok")
        }
    }
--- request
GET /test
--- response_body
nil
nil
nil
ok
--- no_error_log
[warn]
[error]
[crit]
[alert]
[emerg]


