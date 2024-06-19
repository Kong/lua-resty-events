# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 5);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

workers(1);
run_tests();

__DATA__

=== TEST 1: queue works correctly
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
--- config
    location = /test {
        content_by_lua_block {
            local queue = require("resty.events.queue").new(10240)
            local value, err = queue:pop()
            ngx.say(err)
            assert(queue:push_front("first"))
            ngx.say((queue:pop()))
            assert(queue:push("second"))
            assert(queue:push_front("first"))
            ngx.say((queue:pop()))
            ngx.say((queue:pop()))
            value, err = queue:pop()
            ngx.say(err)
            assert(queue:push("first"))
            assert(queue:push("second"))
            ngx.say((queue:pop()))
            ngx.say((queue:pop()))
            assert(queue:push_front("third"))
            assert(queue:push_front("second"))
            assert(queue:push_front("first"))
            ngx.say((queue:pop()))
            ngx.say((queue:pop()))
            ngx.say((queue:pop()))
        }
    }
--- request
GET /test
--- response_body
timeout
first
first
second
timeout
first
second
first
second
third
--- no_error_log
[crit]
[error]
[warn]
