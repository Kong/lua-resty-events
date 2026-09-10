# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 5);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

master_on();
workers(2);
run_tests();

__DATA__

=== TEST 1: rejected generation retains queued event for matching broker
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    lua_shared_dict generation_test 1m;
    init_by_lua_block {
        local protocol = require "resty.events.protocol"
        local connect = protocol.client.connect
        protocol.client.connect = function(self, addr, generation)
            local ok, err, mismatch = connect(self, addr, generation)
            if mismatch then
                ngx.shared.generation_test:incr("mismatches", 1, 0)
            end
            return ok, err, mismatch
        end

        local ev = require("resty.events").new({
            broker_id = 0,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        })
        _G.ev = ev
        _G.broker_generation = "broker-generation"
        _G.worker_generation = "worker-generation"
    }
    init_worker_by_lua_block {
        local ev = _G.ev
        local state = ngx.shared.generation_test
        local worker_id = ngx.worker.id()

        local ok, err = ev:init_worker()
        if not ok then
            ngx.log(ngx.ERR, "failed to init_worker events: ", err)
        end

        ev.opts._generation = worker_id == 1 and _G.worker_generation or
                                                  _G.broker_generation

        ev:subscribe("generation-test", "queued", function()
            state:set("delivered:" .. worker_id, true)
        end)

        if worker_id == 1 then
            ngx.timer.at(0, function(premature)
                if premature then
                    return
                end
                assert(ev:publish("all", "generation-test", "queued"))
                state:set("published", true)
            end)

            ngx.timer.at(0, function(premature)
                if premature then
                    return
                end
                for _ = 1, 500 do
                    if state:get("mismatches") and state:get("published") then
                        break
                    end
                    ngx.sleep(0.01)
                end
                assert(state:get("mismatches") and state:get("published"),
                       "mismatch and queued publication were not observed")
                ev.opts._generation = _G.broker_generation
                state:set("generation_restored", true)
            end)
        end
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
            local state = ngx.shared.generation_test
            local complete
            for _ = 1, 500 do
                complete = state:get("mismatches") and
                           state:get("published") and
                           state:get("generation_restored") and
                           state:get("delivered:0") and
                           state:get("delivered:1")
                if complete then
                    break
                end
                ngx.sleep(0.01)
            end

            ngx.say("generation mismatch rejected: ",
                    state:get("mismatches") and "yes" or "no")
            ngx.say("queued event deliveries: ",
                    state:get("delivered:0") and
                    state:get("delivered:1") and 2 or 0)
        }
    }
--- request
GET /test
--- timeout: 10
--- response_body
generation mismatch rejected: yes
queued event deliveries: 2
--- no_error_log
[error]
[crit]
[alert]
