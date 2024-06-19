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
master_on();
workers(1);
run_tests();

__DATA__

=== TEST 1: retains events on connection failure
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    init_by_lua_block {
        _G.protocol = require("resty.events.protocol")
        local opts = {
            broker_id = 0,
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
            ngx.log(ngx.DEBUG, data)
        end)
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
            ev:publish("all", "source", "event", "eventdata#1")
            ngx.sleep(2)
            local protocol = _G.protocol
            local send_frame = protocol.client.send_frame
            protocol.client.send_frame = function()
                return nil, "lost the broker connection"
            end
            ev:publish("all", "source", "event", "eventdata#2")
            ngx.sleep(0)
            protocol.client.send_frame = send_frame
        }
    }
--- request
GET /test
--- wait: 10
--- error_log eval
[
    qr/eventdata#1/,
    qr/event worker failed to communicate with broker \(failed to send event: lost the broker connection\)/,
    qr/eventdata#2/,
]
--- no_error_log
[crit]
[alert]
