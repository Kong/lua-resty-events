# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 6);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

run_tests();

__DATA__

=== TEST 1: new HTTP worker rejects legacy broker before worker info
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                ngx.header["Upgrade"] = "Kong-Worker-Events/1"
                ngx.header["Content-Type"] = nil
                ngx.status = 101
                assert(ngx.send_headers())
                assert(ngx.flush(true))

                local sock = assert(ngx.req.socket(true))
                local data, err = require("resty.events.frame").recv(sock)
                ngx.log(ngx.INFO, "legacy broker received worker info: ",
                                  data and "yes" or "no", ", error: ", err)
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local client = require("resty.events.protocol").client.new()
            local ok, err, mismatch = client:connect(
                "unix:$TEST_NGINX_HTML_DIR/nginx.sock", "new-generation")
            ngx.say("connected: ", ok and "yes" or "no")
            ngx.say("generation mismatch: ", mismatch and "yes" or "no")
            ngx.say("error: ", err)
        }
    }
--- request
GET /test
--- response_body
connected: no
generation mismatch: yes
error: events broker belongs to a different nginx generation
--- error_log
legacy broker received worker info: no, error: failed to receive the header bytes: closed
--- no_error_log
[error]
[crit]
[alert]



=== TEST 2: new HTTP broker decodes and rejects legacy worker info
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?.lua;;";
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                local server = require("resty.events.protocol").server
                local conn, err, mismatch = server.new("new-generation")
                ngx.log(ngx.INFO, "new broker rejected legacy worker: ",
                                  mismatch and "yes" or "no", ", error: ", err)
                if conn then
                    conn:close()
                end
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local sock = assert(ngx.socket.tcp())
            assert(sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock"))
            assert(sock:send("GET / HTTP/1.1\r\n" ..
                             "Host: localhost\r\n" ..
                             "Connection: Upgrade\r\n" ..
                             "Upgrade: Kong-Worker-Events/1\r\n\r\n"))

            local read_header = sock:receiveuntil("\r\n\r\n")
            local header = assert(read_header())

            local buffer = require "string.buffer"
            local legacy = buffer.new({
                dict = { "spec", "data", "source", "event", "wid", "unique" },
            })
            local info = legacy:reset():encode({ id = 0, pid = ngx.worker.pid() }):get()
            assert(require("resty.events.frame").send(sock, info))

            ngx.sleep(0.05)
            ngx.say("broker advertises generation: ",
                    string.lower(header):find(
                        "kong-worker-events-generation: new-generation", 1, true)
                    and "yes" or "no")
        }
    }
--- request
GET /test
--- response_body
broker advertises generation: yes
--- error_log
new broker rejected legacy worker: yes, error: events broker belongs to a different nginx generation
--- no_error_log
[error]
[crit]
[alert]
