# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 11);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

master_on();
workers(3);
run_tests();

__DATA__

=== TEST 1: posting events and handling events, broadcast
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    lua_shared_dict dict 1m;
    init_by_lua_block {
        require("ngx.process").enable_privileged_agent(4096)
        local opts = {
            broker_id = 2,
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

        local semaphore = require("ngx.semaphore")
        local sema = semaphore.new(1)

        local id = ngx.worker.id()

        if id == 2 then
            ngx.shared.dict:set("broker-pid", ngx.worker.pid())
        end

        if id == 0 or id == 1 then
            ev:subscribe("content_by_lua", "first", function()
                ngx.sleep(0)
                ngx.log(ngx.INFO, id, " first handler")
                local ok, err = sema:wait(0)
                if ok then
                    ngx.log(ngx.INFO, id, " first got mutex")
                    ngx.sleep(5)
                else
                    ngx.log(ngx.CRIT, id, " first did not got mutex: ", err)
                end
                sema:post()
            end)
        end

        if id == nil then
            ev:subscribe("content_by_lua", "second", function()
                ngx.sleep(0)
                ngx.log(ngx.INFO, "privileged killer")
                ngx.timer.at(0, function()
                    ngx.log(ngx.INFO, "killing ", ngx.shared.dict:get("broker-pid"))
                    os.execute("kill -9 " .. ngx.shared.dict:get("broker-pid"))
                    ngx.sleep(0)
                end)
            end)
        end

        if id == 0 or id == 1 then
            ev:subscribe("content_by_lua", "third", function()
                ngx.sleep(0)
                ngx.log(ngx.INFO, id, " third handler")
                local ok, err = sema:wait(0)
                if ok then
                    ngx.log(ngx.INFO, id, " third got mutex")
                else
                    ngx.log(ngx.CRIT, id, " third did not got mutex: ", err)
                end
                sema:post()
            end)
        end


        -- These tests are left to be enabled when we get this reliable (needs more reliability fixes in lib):
        --if id == 0 or id == 1 then
        --    ev:subscribe("content_by_lua", "fourth", function()
        --        ngx.sleep(0)
        --        ngx.log(ngx.INFO, id, " fourth handler")
        --    end)
        --end

        --ev:subscribe("content_by_lua", "fifth", function()
        --    ngx.sleep(0)
        --    ngx.log(ngx.INFO, id or "privileged", " fifth handler")
        --end)

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
            ev:publish("all", "content_by_lua", "second")
            ngx.sleep(0)
            ev:publish("all", "content_by_lua", "third")
            ngx.sleep(0)
            -- These tests are left to be enabled when we get this reliable (needs more reliability fixes in lib):
            --ev:publish("all", "content_by_lua", "fourth")
            --ngx.sleep(0)
            --ev:publish("all", "content_by_lua", "fifth")
            --ngx.sleep(0)
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
    qr/0 first handler/,
    qr/1 first handler/,
    qr/0 first got mutex/,
    qr/1 first got mutex/,
    qr/privileged killer/,
    qr/exited on signal 9/,
    qr/0 third got mutex/,
    qr/1 third got mutex/,
    # These tests are left to be enabled when we get this reliable (needs more reliability fixes in lib):
    # qr/0 fourth handler/,
    # qr/1 fourth handler/,
    # qr/privileged fifth handler/,
    # qr/0 fifth handler/,
    # qr/1 fifth handler/,
    # qr/2 fifth handler/,
]
--- skip_nginx
11: < 1.21.4
