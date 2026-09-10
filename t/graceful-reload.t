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

=== TEST 1: broadcast during graceful reload reaches the new worker generation
--- main_config
    worker_shutdown_timeout 15s;
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    lua_shared_dict reload_test 1m;
    init_by_lua_block {
        local ffi = require "ffi"
        ffi.cdef [[int kill(int pid, int sig);]]

        local opts = {
            broker_id = 0,
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        }

        local ev = require("resty.events").new(opts)
        if not ev then
            ngx.log(ngx.ERR, "failed to new events")
        end

        _G.ev = ev
        _G.kill = ffi.C.kill
    }
    init_worker_by_lua_block {
        local ev = _G.ev
        local worker_id = ngx.worker.id()
        local state = ngx.shared.reload_test

        local ok, err = ev:init_worker()
        if not ok then
            ngx.log(ngx.ERR, "failed to init_worker events: ", err)
        end

        local generation = ev.opts._generation
        state:set("worker_pid:" .. generation .. ":" .. worker_id,
                  ngx.worker.pid())

        ev:subscribe("reload_test", "broadcast", function()
            state:set("delivered:" .. generation .. ":" .. worker_id, true)
            ngx.log(ngx.INFO, "reload event delivered to worker #", worker_id,
                              " in generation ", generation)
        end)

        local original_generation = state:get("original_generation")
        if not original_generation then
            state:add("original_generation", generation)

        elseif generation ~= original_generation then
            state:set("new_generation", generation)

            if worker_id == 0 then
                ngx.timer.at(0.2, function(premature)
                    if premature then
                        return
                    end

                    for id = 0, 3 do
                        local pid = state:get("worker_pid:" ..
                                              original_generation .. ":" .. id)
                        if not pid or _G.kill(pid, 0) ~= 0 then
                            ngx.log(ngx.ERR, "original worker #", id,
                                              " was not alive before publish")
                            return
                        end
                    end

                    state:set("overlap_confirmed:" .. generation, true)

                    local ok, err = ev:publish("all", "reload_test", "broadcast")
                    if not ok then
                        ngx.log(ngx.ERR, "failed to publish reload event: ", err)
                    end
                end)
            end
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
    location = /hold {
        lua_check_client_abort on;
        content_by_lua_block {
            local id = ngx.worker.id()
            ngx.shared.reload_test:set("held:" .. id, true)
            ngx.sleep(15)
            ngx.say("held")
        }
    }

    location = /test {
        content_by_lua_block {
            local state = ngx.shared.reload_test
            local sockets = {}

            -- This request itself keeps its worker alive across the reload.
            state:set("held:" .. ngx.worker.id(), true)

            for _ = 1, 64 do
                local sock = ngx.socket.tcp()
                sock:settimeout(1000)
                assert(sock:connect("127.0.0.1", ngx.var.server_port))
                assert(sock:send("GET /hold HTTP/1.0\r\nHost: localhost\r\n\r\n"))
                sockets[#sockets + 1] = sock
            end

            local all_held
            for _ = 1, 100 do
                all_held = true
                for id = 0, 3 do
                    if not state:get("held:" .. id) then
                        all_held = false
                        break
                    end
                end

                if all_held then
                    break
                end
                ngx.sleep(0.01)
            end
            assert(all_held, "failed to hold every worker before reload")

            local master_pid = require("ngx.process").get_master_pid()
            assert(_G.kill(master_pid, 1) == 0)

            local generation
            for _ = 1, 500 do
                generation = state:get("new_generation")
                if generation then
                    break
                end
                ngx.sleep(0.01)
            end
            assert(generation, "new worker generation did not start")

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

            assert(state:get("overlap_confirmed:" .. generation),
                   "original workers were not alive when the event was published")

            ngx.sleep(0.1)
            local original_generation = state:get("original_generation")
            local original_delivered = 0
            for id = 0, 3 do
                if state:get("delivered:" .. original_generation .. ":" .. id) then
                    original_delivered = original_delivered + 1
                end
            end

            for _, sock in ipairs(sockets) do
                sock:close()
            end

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
