# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 6) + 2;

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
#master_on();
#workers(2);
run_tests();

__DATA__

=== TEST 1: registering and unregistering event handlers at different levels
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
    init_worker_by_lua_block {
        local ec = require "resty.events.compat.callback"
        local cb = function(extra, data, event, source, pid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                    ", data=", data, ", callback=",extra)
        end

        ngx.cb_global  = function(...) return cb("global", ...) end
        ngx.cb_source  = function(...) return cb("source", ...) end
        ngx.cb_event12 = function(...) return cb("event12", ...) end
        ngx.cb_event3  = function(...) return cb("event3", ...) end

        ec.register(ngx.cb_global)
        ec.register(ngx.cb_source,  "content_by_lua")
        ec.register(ngx.cb_event12, "content_by_lua", "request1", "request2")
        ec.register(ngx.cb_event3,  "content_by_lua", "request3")
    }
--- config
    location = /test {
        content_by_lua_block {
            local ec = require "resty.events.compat.callback"
            local pid = ngx.worker.pid()

            local post = function(s, e, d)
                ec.do_event({source = s, event = e, data = d, pid = pid})
            end

            post("content_by_lua","request1","123")
            post("content_by_lua","request2","123")
            post("content_by_lua","request3","123")

            ec.unregister(ngx.cb_global)

            post("content_by_lua","request1","124")
            post("content_by_lua","request2","124")
            post("content_by_lua","request3","124")

            ec.unregister(ngx.cb_source,  "content_by_lua")

            post("content_by_lua","request1","125")
            post("content_by_lua","request2","125")
            post("content_by_lua","request3","125")

            ec.unregister(ngx.cb_event12, "content_by_lua", "request1", "request2")
            post("content_by_lua","request1","126")
            post("content_by_lua","request2","126")
            post("content_by_lua","request3","126")

            ec.unregister(ngx.cb_event3,  "content_by_lua", "request3")
            post("content_by_lua","request1","127")
            post("content_by_lua","request2","127")
            post("content_by_lua","request3","127")

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
qr/^worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=123, callback=global
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=123, callback=source
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=123, callback=event12
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=123, callback=global
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=123, callback=source
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=123, callback=event12
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=global
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=source
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=124, callback=source
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=124, callback=event12
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=124, callback=source
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=124, callback=event12
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=124, callback=source
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=124, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=125, callback=event12
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=125, callback=event12
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=125, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=126, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+$/


=== TEST 2: registering and GC'ing weak event handlers at different levels
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
--- config
    location = /test {
        content_by_lua_block {
            local ec = require "resty.events.compat.callback"

            local post = function(s, e, d)
                ec.do_event({source = s, event = e, data = d, pid = pid})
            end

            local count = 0

            local cb = {
              global = function(source, event)
                ngx.log(ngx.DEBUG, "global handler: ", source, ", ", event)
                count = count + 1
              end,
              source = function(source, event)
                ngx.log(ngx.DEBUG, "global source: ", source, ", ", event)
                count = count + 1
              end,
              event12 = function(source, event)
                ngx.log(ngx.DEBUG, "global event12: ", source, ", ", event)
                count = count + 1
              end,
              event3 = function(source, event)
                ngx.log(ngx.DEBUG, "global event3: ", source, ", ", event)
                count = count + 1
              end,
            }

            ec.register_weak(cb.global)
            ec.register_weak(cb.source,  "content_by_lua")
            ec.register_weak(cb.event12, "content_by_lua", "request1", "request2")
            ec.register_weak(cb.event3,  "content_by_lua", "request3")

            post("content_by_lua","request1","123")
            post("content_by_lua","request2","123")
            post("content_by_lua","request3","123")

            ngx.say("before GC:", count)

            cb = nil
            collectgarbage()
            collectgarbage()
            count = 0

            post("content_by_lua","request1","123")
            post("content_by_lua","request2","123")
            post("content_by_lua","request3","123")

            ngx.say("after GC:", count) -- 0
        }
    }
--- request
GET /test
--- response_body
before GC:9
after GC:0
--- no_error_log
[error]
[crit]
[alert]
[emerg]


=== TEST 3: callback error handling
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
--- config
    location = /test {
        content_by_lua_block {
            local ec = require "resty.events.compat.callback"

            local post = function(s, e, d)
                ec.do_event({source = s, event = e, data = d, pid = pid})
            end

            local error_func = function()
              error("something went wrong here!")
            end
            local test_callback = function(source, event, data, pid)
              error_func() -- nested call to check stack trace
            end
            ec.register(test_callback)

            -- non-serializable test data containing a function value
            -- use "nil" as data, reproducing issue #5
            post("content_by_lua","test_event", nil)

            ngx.say("ok")
        }
    }
--- request
GET /test
--- response_body
ok
--- error_log
something went wrong here!
--- no_error_log
[crit]
[alert]
[emerg]


=== TEST 4: callback error stacktrace
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
--- config
    location = /test {
        content_by_lua_block {
            local ec = require "resty.events.compat.callback"

            local post = function(s, e, d)
                ec.do_event({source = s, event = e, data = d, pid = pid})
            end

            local error_func = function()
              error("something went wrong here!")
            end
            local in_between = function()
              error_func() -- nested call to check stack trace
            end
            local test_callback = function(source, event, data, pid)
              in_between() -- nested call to check stack trace
            end

            ec.register(test_callback)
            post("content_by_lua","test_event")

            ngx.say("ok")
        }
    }
--- request
GET /test
--- response_body
ok
--- error_log
something went wrong here!
in function 'error_func'
in function 'in_between'
--- no_error_log
[crit]
[alert]
[emerg]


