# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

repeat_each(2);

plan tests => repeat_each() * (blocks() * 5);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#no_diff();
#no_long_string();
#master_on();
#workers(2);
run_tests();

__DATA__

=== TEST 1: sanity: encode, decode
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
--- config
    location = /test {
        content_by_lua_block {
            local codec = require("resty.events.codec")

            local obj1 = {n = 100, s = "xxx", b = true,}

            local str = codec.encode(obj1)
            assert(str)

            local obj2 = codec.decode(str)
            assert(obj2)

            ngx.say(type(obj2))
            ngx.say(type(obj2.n), obj2.n)
            ngx.say(type(obj2.s), obj2.s)
            ngx.say(type(obj2.b), obj2.b)
        }
    }
--- request
GET /test
--- response_body
table
number100
stringxxx
booleantrue
--- no_error_log
[error]
[crit]
[alert]
