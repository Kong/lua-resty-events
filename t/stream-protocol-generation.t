# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 6);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

run_tests();

__DATA__

=== TEST 1: legacy stream broker decodes new worker info
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";

        server {
            listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
            content_by_lua_block {
                local sock = assert(ngx.req.socket(true))
                local data = assert(require("resty.events.frame").recv(sock))

                local buffer = require "string.buffer"
                local legacy = buffer.new({
                    dict = { "spec", "data", "source", "event", "wid", "unique" },
                })
                local info = legacy:set(data):decode()
                ngx.log(ngx.INFO, "legacy broker decoded generation: ",
                                  info.generation)
                -- Legacy brokers wait for events instead of acknowledging.
                sock:settimeout(3000)
                local event, err = require("resty.events.frame").recv(sock)
                assert(not event and err:find("closed", 1, true),
                       "client did not close without sending an event")
            }
        }

        server {
            listen 1985;
            # The legacy handshake timeout is expected and asserted below.
            lua_socket_log_errors off;
            content_by_lua_block {
                local client = require("resty.events.protocol").client.new()
                local started = ngx.now()
                local ok, err, mismatch = client:connect(
                    "unix:$TEST_NGINX_HTML_DIR/nginx.sock", "new-generation")
                local elapsed = ngx.now() - started
                assert(elapsed >= 0.9 and elapsed < 2.5,
                       "legacy handshake did not time out within its budget")
                ngx.say("connected: ", ok and "yes" or "no")
                ngx.say("generation mismatch: ", mismatch and "yes" or "no")
                ngx.say("error: ", err)
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local sock = assert(ngx.socket.tcp())
            assert(sock:connect("127.0.0.1", 1985))
            ngx.print(assert(sock:receive("*a")))
        }
    }
--- request
GET /test
--- timeout: 5
--- response_body
connected: no
generation mismatch: yes
error: events broker belongs to a different nginx generation: failed to receive the header bytes: timeout
--- error_log
legacy broker decoded generation: new-generation
--- no_error_log
[error]
[crit]
[alert]



=== TEST 2: new stream broker decodes and rejects legacy worker info
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";

        server {
            listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
            content_by_lua_block {
                local server = require("resty.events.protocol").server
                local _, err, mismatch = server.new("new-generation")
                ngx.log(ngx.INFO, "new broker rejected legacy worker: ",
                                  mismatch and "yes" or "no", ", error: ", err)
            }
        }

        server {
            listen 1985;
            content_by_lua_block {
                local sock = assert(ngx.socket.tcp())
                assert(sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock"))

                local buffer = require "string.buffer"
                local legacy = buffer.new({
                    dict = { "spec", "data", "source", "event", "wid", "unique" },
                })
                local info = legacy:reset():encode({
                    id = 0,
                    pid = ngx.worker.pid(),
                }):get()
                assert(require("resty.events.frame").send(sock, info))

                ngx.sleep(0.05)
                ngx.say("legacy worker info sent")
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local sock = assert(ngx.socket.tcp())
            assert(sock:connect("127.0.0.1", 1985))
            ngx.print(assert(sock:receive("*a")))
        }
    }
--- request
GET /test
--- response_body
legacy worker info sent
--- error_log
new broker rejected legacy worker: yes, error: events broker belongs to a different nginx generation
--- no_error_log
[error]
[crit]
[alert]
