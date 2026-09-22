# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 9);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

check_accum_error_log();
master_on();
workers(4);
worker_connections(256);
run_tests();

__DATA__

=== TEST 1: broadcast during a reload reaches the new worker generation only
--- main_config
    worker_shutdown_timeout 15s;
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    lua_shared_dict reload_test 1m;

    init_by_lua_block {
        local ffi = require "ffi"
        ffi.cdef[[int kill(int pid, int sig);]]

        local ev = require("resty.events").new({
            broker_id = 0,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        })
        assert(ev, "failed to new events object")

        _G.ev = ev
        _G.kill = ffi.C.kill
    }

    init_worker_by_lua_block {
        local generation = require "resty.events.generation"
        local ev = _G.ev
        local state = ngx.shared.reload_test
        local worker_id = ngx.worker.id()
        local mine = generation.mine()

        local ok, err = ev:init_worker()
        if not ok then
            ngx.log(ngx.ERR, "failed to init_worker events: ", err)
        end

        state:set("pid:" .. mine .. ":" .. worker_id, ngx.worker.pid())

        ev:subscribe("reload_test", "broadcast", function()
            state:set("delivered:" .. mine .. ":" .. worker_id, true)
            ngx.log(ngx.INFO, "reload event delivered to worker #", worker_id,
                              " in generation ", mine)
        end)

        local original = state:get("original_generation")
        if not original then
            state:set("original_generation", mine)
            original = mine
        end

        if mine == original then
            -- a pending timer keeps a worker from exiting: hold every worker
            -- of this generation so the reload overlap is deterministic
            local function keep_alive()
                if state:get("release") then
                    return
                end

                if not ngx.timer.at(0.2, keep_alive) then
                    return
                end
            end

            ngx.timer.at(0.2, keep_alive)
            return
        end

        state:set("new_generation", mine)

        if worker_id ~= 0 then
            return
        end

        -- the old generation is still alive: it must not receive this event
        ngx.timer.at(0.5, function(premature)
            if premature then
                return
            end

            for id = 0, 3 do
                local pid = state:get("pid:" .. original .. ":" .. id)
                if not pid or _G.kill(pid, 0) ~= 0 then
                    ngx.log(ngx.ERR, "original worker #", id,
                                      " was not alive before publish")
                    return
                end
            end

            state:set("overlap_confirmed", true)

            local ok, err = ev:publish("all", "reload_test", "broadcast")
            if not ok then
                ngx.log(ngx.ERR, "failed to publish reload event: ", err)
            end
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
            local state = ngx.shared.reload_test
            local master_pid = require("ngx.process").get_master_pid()

            assert(_G.kill(master_pid, 1) == 0, "failed to reload nginx")

            local generation
            for _ = 1, 500 do
                generation = state:get("new_generation")
                if generation then
                    break
                end

                ngx.sleep(0.01)
            end

            assert(generation, "the new worker generation did not start")

            local delivered
            for _ = 1, 500 do
                delivered = 0
                for id = 0, 3 do
                    if state:get("delivered:" .. generation .. ":" .. id) then
                        delivered = delivered + 1
                    end
                end

                if delivered == 4 then
                    break
                end

                ngx.sleep(0.01)
            end

            assert(state:get("overlap_confirmed"),
                   "the previous generation was not alive when publishing")

            local original = state:get("original_generation")
            local original_delivered = 0
            for id = 0, 3 do
                if state:get("delivered:" .. original .. ":" .. id) then
                    original_delivered = original_delivered + 1
                end
            end

            -- let the workers of the previous generation exit
            state:set("release", true)

            ngx.say("new generation deliveries: ", delivered)
            ngx.say("original generation deliveries: ", original_delivered)
        }
    }
--- request
GET /test
--- timeout: 20
--- response_body
new generation deliveries: 4
original generation deliveries: 0
--- error_log eval
[
    qr/reload event delivered to worker #0 in generation/,
    qr/reload event delivered to worker #1 in generation/,
    qr/reload event delivered to worker #2 in generation/,
    qr/reload event delivered to worker #3 in generation/,
]
--- no_error_log
[error]
[crit]
[alert]
