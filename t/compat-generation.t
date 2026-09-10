# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 5);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

master_on();
workers(2);
run_tests();

__DATA__

=== TEST 1: compatibility API shares one generation between workers
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    lua_shared_dict compat_generation_test 1m;
    init_by_lua_block {
        require "resty.events.compat"
    }
    init_worker_by_lua_block {
        local ev = require "resty.events.compat"
        local ok, err = ev.configure({
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        })
        if not ok then
            ngx.log(ngx.ERR, "failed to configure events: ", err)
        end

        ev.register(function(_, event)
            if event == "compat-generation" then
                ngx.shared.compat_generation_test:set(
                    "delivered:" .. ngx.worker.id(), true)
            end
        end, "compat-generation", "compat-generation")
    }

    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                require("resty.events.compat").run()
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local ev = require "resty.events.compat"
            assert(ev.post("compat-generation", "compat-generation"))

            local state = ngx.shared.compat_generation_test
            local delivered
            for _ = 1, 500 do
                delivered = 0
                for id = 0, 1 do
                    if state:get("delivered:" .. id) then
                        delivered = delivered + 1
                    end
                end

                if delivered == 2 then
                    break
                end
                ngx.sleep(0.01)
            end

            ngx.say("deliveries: ", delivered)
        }
    }
--- request
GET /test
--- timeout: 10
--- response_body
deliveries: 2
--- no_error_log
[error]
[crit]
[alert]


=== TEST 2: compatibility API rejects missing preload clearly
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    init_worker_by_lua_block {
        local ev = require "resty.events.compat"
        local ok, err = pcall(ev.configure, {
            listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
        })
        assert(not ok and err:find(
            "resty.events must be required in init_by_lua before workers start", 1, true))
        _G.preload_rejected = true
    }
--- config
    location = /test {
        content_by_lua_block {
            ngx.say("missing preload rejected: ", _G.preload_rejected)
        }
    }
--- request
GET /test
--- response_body
missing preload rejected: true
--- no_error_log
[error]
[crit]
[alert]
