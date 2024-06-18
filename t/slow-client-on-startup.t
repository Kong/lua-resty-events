# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 7);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

check_accum_error_log();
master_on();
workers(3);
run_tests();

__DATA__

=== TEST 1: slow client on node start won't miss the events
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    lua_shared_dict dict 1m;
    init_by_lua_block {
        require("ngx.process").enable_privileged_agent(4096)
        local opts = {
            broker_id = 2,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
            enable_privileged_agent = true,
        }

        local ev = require("resty.events").new(opts)
        if not ev then
            ngx.log(ngx.ERR, "failed to new events")
        end

        _G.ev = ev
    }
    init_worker_by_lua_block {
        local ev = _G.ev
        local id = ngx.worker.id() or "privileged"
        local function initialize()
            local ok, err = ev:init_worker()
            if not ok then
                ngx.log(ngx.ERR, "failed to init_worker events: ", err)
            end
            ev:subscribe("content_by_lua", "first", function()
                ngx.log(ngx.INFO, "#", id, " first handler")
            end)
        end

        if id == 1 then
            -- need to disable listening here as we are postponing the initialization
            require("resty.events.disable_listening")(ev.opts.listening)
            -- slow client
            ngx.timer.at(5, initialize)
        else
            initialize()
        end

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
        access_by_lua_block {
            local ev = _G.ev
            ev:publish("all", "content_by_lua", "first")
            ngx.sleep(0)
            ngx.say("ok")
        }
    }
--- request
GET /test
--- wait: 10
--- response_body
ok
--- no_error_log
[crit]
--- error_log eval
[
    qr/#privileged first handler/,
    qr/#0 first handler/,
    qr/#1 first handler/,
    qr/#2 first handler/,
]
--- skip_nginx
7: < 1.21.4
