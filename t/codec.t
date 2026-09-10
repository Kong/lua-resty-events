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



=== TEST 2: generation field is compatible with the legacy dictionary
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
--- config
    location = /test {
        content_by_lua_block {
            local buffer = require "string.buffer"
            local codec = require "resty.events.codec"
            local options = {
                dict = { "spec", "data", "source", "event", "wid", "unique" },
            }
            local legacy_encoder = buffer.new(options)
            local legacy_decoder = buffer.new(options)

            local encoded = codec.encode({
                id = 1,
                pid = 2,
                generation = "new-generation",
            })
            local decoded = legacy_decoder:set(encoded):decode()
            ngx.say("new to legacy: ", decoded.generation)

            encoded = legacy_encoder:reset():encode({ id = 1, pid = 2 }):get()
            decoded = codec.decode(encoded)
            ngx.say("legacy to new: ", decoded.id, ",", decoded.pid)
        }
    }
--- request
GET /test
--- response_body
new to legacy: new-generation
legacy to new: 1,2
--- no_error_log
[error]
[crit]
[alert]
