# vim:set ft= ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

plan tests => repeat_each() * (blocks() * 5);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

run_tests();

__DATA__

=== TEST 1: the acknowledgement of the handshake does not disturb the stream
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                local conn, err = require("resty.events.protocol").server.new()
                if not conn then
                    ngx.say("failed to init socket: ", err)
                    return
                end

                local ok, err = conn:ack()
                if not ok then
                    ngx.say("failed to ack: ", err)
                    return
                end

                local _, err = conn:send_frame("event")
                if err then
                    ngx.say("failed to send data: ", err)
                end
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local client = require("resty.events.protocol").client.new()

            local ok, err = client:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            -- the acknowledgement was consumed by connect()
            local data, err = client:recv_frame()
            if not data then
                ngx.say("failed to recv data: ", err)
                return
            end

            ngx.say("connected: yes, event: ", data)
        }
    }
--- request
GET /test
--- response_body
connected: yes, event: event
--- no_error_log
[error]
[crit]
[alert]



=== TEST 2: a broker of an older version is not waited for
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                -- an older broker: same handshake, it acknowledges nothing
                ngx.header["Upgrade"] = "Kong-Worker-Events/1"
                ngx.header["Content-Type"] = nil
                ngx.status = 101
                assert(ngx.send_headers())
                assert(ngx.flush(true))

                local sock = assert(ngx.req.socket(true))
                sock:settimeout(5000)
                assert(require("resty.events.frame").recv(sock))

                ngx.sleep(0.5)
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local client = require("resty.events.protocol").client.new()

            local started = ngx.now()
            local ok, err = client:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            local elapsed = ngx.now() - started

            ngx.say("connected: ", ok and "yes" or "no", ", err: ", err or "none")
            ngx.say("waited: ", elapsed >= 0.09)

            -- keep it open so the fake broker can read the worker info
            ngx.sleep(0.5)
        }
    }
--- request
GET /test
--- response_body
connected: yes, err: none
waited: false
--- no_error_log
[error]
[crit]
[alert]



=== TEST 3: a broker that drops the handshake is reported as a rejection
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                -- how another generation's broker refuses: by dropping it
                local conn, err = require("resty.events.protocol").server.new()
                if not conn then
                    ngx.say("failed to init socket: ", err)
                    return
                end

                return ngx.exit(444)
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local client = require("resty.events.protocol").client.new()

            local ok, err, rejected =
                client:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")

            ngx.say("connected: ", ok and "yes" or "no")
            ngx.say("rejected: ", tostring(rejected))
            ngx.say("retryable: ", err ~= nil and rejected == true)
        }
    }
--- request
GET /test
--- response_body
connected: no
rejected: true
retryable: true
--- no_error_log
[error]
[crit]
[alert]



=== TEST 4: in the stream subsystem a broker that acknowledges nothing is waited for
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";

        server {
            listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
            content_by_lua_block {
                -- here an older broker cannot be told apart from a slow one
                local conn, err = require("resty.events.protocol").server.new()
                if not conn then
                    ngx.say("failed to init socket: ", err)
                    return
                end

                ngx.sleep(0.5)
            }
        }

        server {
            listen 1985;
            # the acknowledgement timeout of an older broker is expected here
            lua_socket_log_errors off;
            content_by_lua_block {
                local client = require("resty.events.protocol").client.new()

                local started = ngx.now()
                local ok, err = client:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                local elapsed = ngx.now() - started

                ngx.say("connected: ", ok and "yes" or "no", ", err: ", err or "none")
                ngx.say("waited: ", elapsed >= 0.09 and elapsed < 1)
            }
        }
    }
--- config
    # the acknowledgement timeout of an older broker is expected here
    lua_socket_log_errors off;

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
connected: yes, err: none
waited: true
--- no_error_log
[error]
[crit]
[alert]



=== TEST 5: a late acknowledgement is not mistaken for an event
--- main_config
    stream {
        lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
        lua_shared_dict late_ack 1m;

        init_by_lua_block {
            local ev = require("resty.events").new({
                broker_id = 0,
                listening = "unix:$TEST_NGINX_HTML_DIR/nginx.sock",
            })
            _G.ev = ev
        }

        init_worker_by_lua_block {
            local ev = _G.ev
            local state = ngx.shared.late_ack

            ev:subscribe("late-ack", "event", function(data)
                state:set("delivered", true)
            end)

            local ok, err = ev:init_worker()
            if not ok then
                ngx.log(ngx.ERR, "failed to init_worker events: ", err)
            end
        }

        server {
            listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
            content_by_lua_block {
                -- a broker that acknowledges later than the client waits for it
                local conn, err = require("resty.events.protocol").server.new()
                if not conn then
                    ngx.say("failed to init socket: ", err)
                    return
                end

                ngx.sleep(0.3)

                local ok, err = conn:ack()
                if not ok then
                    ngx.log(ngx.ERR, "failed to ack: ", err)
                    return
                end

                conn:send_frame(require("resty.events.codec").encode({
                    source = "late-ack", event = "event", data = "ok", wid = 0,
                }))

                ngx.sleep(0.2)
            }
        }

        server {
            listen 1985;
            content_by_lua_block {
                local state = ngx.shared.late_ack
                local delivered

                for _ = 1, 300 do
                    delivered = state:get("delivered")
                    if delivered then
                        break
                    end
                    ngx.sleep(0.01)
                end

                ngx.say("event delivered: ", delivered and "yes" or "no")
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
event delivered: yes
--- no_error_log eval
[
    # giving up on the acknowledgement is expected, decoding it is not
    qr/\[error\](?!.*lua tcp socket read timed out)/,
    qr/\[crit\]/,
    qr/\[alert\]/,
]



=== TEST 6: a response that is not an acknowledgement is rejected
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                -- the first frame is not the acknowledgement: the client must
                -- not take it for an acceptance
                local conn, err = require("resty.events.protocol").server.new()
                if not conn then
                    ngx.say("failed to init socket: ", err)
                    return
                end

                local _, err = conn:send_frame("not-an-ack")
                if err then
                    ngx.say("failed to send data: ", err)
                end
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local client = require("resty.events.protocol").client.new()

            local ok, err, rejected =
                client:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")

            ngx.say("connected: ", ok and "yes" or "no")
            ngx.say("rejected: ", tostring(rejected))
            ngx.say("error: ", err or "none")
        }
    }
--- request
GET /test
--- response_body
connected: no
rejected: true
error: unexpected handshake response: not-an-ack
--- no_error_log
[error]
[crit]
[alert]



=== TEST 7: a client that does not expect the acknowledgement is not sent one
--- http_config
    lua_package_path "../lua-resty-core/lib/?.lua;lualib/?/init.lua;lualib/?.lua;;";
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        location / {
            content_by_lua_block {
                local conn, err = require("resty.events.protocol").server.new()
                if not conn then
                    ngx.say("failed to init socket: ", err)
                    return
                end

                -- the peer sent no ack field: acknowledging it would confuse it
                local ok, err = conn:ack()
                if not ok then
                    ngx.say("failed to ack: ", err)
                    return
                end

                assert(conn:send_frame("event"))
            }
        }
    }
--- config
    location = /test {
        content_by_lua_block {
            local codec = require "resty.events.codec"
            local frame = require "resty.events.frame"

            -- a client of the previous version: no ack field in its worker
            -- info, and no idea what an acknowledgement frame is
            local sock = assert(ngx.socket.tcp())
            sock:settimeout(2000)
            assert(sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock"))

            assert(sock:send("GET / HTTP/1.1\r\n" ..
                             "Host: localhost\r\n" ..
                             "Connection: Upgrade\r\n" ..
                             "Upgrade: Kong-Worker-Events/1\r\n\r\n"))

            local header = assert(sock:receiveuntil("\r\n\r\n")())
            assert(string.find(header, "101", 1, true), header)

            assert(frame.send(sock, codec.encode({
                id = 0, pid = ngx.worker.pid(),
            })))

            -- only the event may arrive: an acknowledgement would break it
            local data = assert(frame.recv(sock))
            ngx.say("first frame is the event: ", data == "event")
        }
    }
--- request
GET /test
--- response_body
first frame is the event: true
--- no_error_log
[error]
[crit]
[alert]
