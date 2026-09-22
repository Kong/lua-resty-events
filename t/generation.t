# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 5);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

master_on();
workers(2);
run_tests();

__DATA__

=== TEST 1: generation of the current worker process is known
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
--- config
    location = /test {
        content_by_lua_block {
            local generation = require "resty.events.generation"

            local mine = generation.mine()

            ngx.say("mine: ", mine > 0)
            ngx.say("own pid: ", generation.of_pid(ngx.worker.pid()) == mine)
            ngx.say("unknown pid: ", generation.of_pid(1))
        }
    }
--- request
GET /test
--- response_body
mine: true
own pid: true
unknown pid: 0
--- no_error_log
[error]
[crit]
[alert]



=== TEST 2: workers of the same generation are recognised
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    lua_shared_dict generation_test 1m;

    init_worker_by_lua_block {
        ngx.shared.generation_test:set("pid:" .. ngx.worker.id(),
                                       ngx.worker.pid())
    }
--- config
    location = /test {
        content_by_lua_block {
            local generation = require "resty.events.generation"
            local state = ngx.shared.generation_test
            local mine = generation.mine()
            local self_pid = ngx.worker.pid()

            local pid0, pid1
            for _ = 1, 200 do
                pid0 = state:get("pid:0")
                pid1 = state:get("pid:1")
                if pid0 and pid1 then
                    break
                end
                ngx.sleep(0.01)
            end

            local peer_pid = pid0 == self_pid and pid1 or pid0

            for _ = 1, 200 do
                if generation.of_pid(peer_pid) ~= 0 then
                    break
                end
                ngx.sleep(0.01)
            end

            ngx.say("peer pid known: ", generation.of_pid(peer_pid) > 0)
            ngx.say("peer generation: ", generation.of_pid(peer_pid) == mine)
        }
    }
--- request
GET /test
--- response_body
peer pid known: true
peer generation: true
--- no_error_log
[error]
[crit]
[alert]
