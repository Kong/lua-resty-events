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

=== TEST 1: registering and unregistering event handlers at different levels
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
    init_worker_by_lua_block {
        local ec = require "resty.events.callback"
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
            local cjson = require "cjson.safe"
            local ec = require "resty.events.callback"
            local pid = ngx.worker.pid()

            local post = function(s, e, d)
                ec.do_event_json(
                    cjson.encode{source = s, event = e, data = d, pid = pid})
            end

            post("content_by_lua","request1","123")
            post("content_by_lua","request2","123")
            post("content_by_lua","request3","123")

            --ec.unregister(ngx.cb_global)

            --post("content_by_lua","request1","124")
            --post("content_by_lua","request2","124")
            --post("content_by_lua","request3","124")

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
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=event3$/
--- ONLY


