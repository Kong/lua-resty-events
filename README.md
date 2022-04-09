
lua-resty-events
=======================

Inter process Pub/Sub pattern events propagation for Nginx worker processes

Table of Contents
=================

* [Name](#name)
* [Status](#status)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
    * [configure](#configure)
    * [post](#post)
    * [post_local](#post_local)
    * [register](#register)
    * [unregister](#unregister)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)

Status
======

This library is currently considered experimental.

Synopsis
========

```nginx
http {
    lua_package_path "/path/to/lua-resty-events/lib/?/init.lua;;";

    init_worker_by_lua_block {
        local opts = {
            listening = "unix:/tmp/nginx.sock",
        }

        local ev = require "resty.events"

        local handler = function(data, event, source, pid)
            print("received event; source=",source,
                  ", event=",event,
                  ", data=", tostring(data),
                  ", from process ",pid)
        end

        ev.register(handler)

        local ok, err = ev.configure(opts)
        if not ok then
            ngx.log(ngx.ERR, "failed to configure events: ", err)
        end
    }

    # create a listening unix domain socket
    server {
        listen unix:/tmp/nginx.sock;
        location / {
            content_by_lua_block {
                 require("resty.events").run()
            }
        }
    }
}
```

Description
===========

This module provides a way to send events to the other worker processes in an Nginx
server. Communication is through a unix domain socket which is listened by one and
only one Nginx worker.

The design allows for 3 usecases;

1. broadcast an event to all workers processes, see [post](#post). Example:
a healthcheck running in one worker, but informing all workers of a failed
upstream node.
2. broadcast an event to the local worker only, see [post_local](#post_local).
3. coalesce external events to a single action. Example; all workers watch
external events indicating an in-memory cache needs to be refreshed. When
receiving it they all post it with a unique event hash (all workers generate the
same hash), see `unique` parameter of [post](#post). Now only 1 worker will
receive the event _only once_, so only one worker will hit the upstream
database to refresh the in-memory data.

[Back to TOC](#table-of-contents)


Methods
=======

[Back to TOC](#table-of-contents)

configure
---------
`syntax: ok, err = events.configure(opts)`

Will initialize the event listener. This should typically be called from the
`init_worker_by_lua` handler, because it will make sure only one Nginx worker
starts to listen on unix domain socket.

The `opts` parameter is a Lua table with named options:

* `listening`: the unix doamin socket, which must be same as another `server` block.
* `broker_id`: (optional) the worker id that will start to listen, default 0.
* `unique_timeout`: (optional) timeout of unique event data stored (in seconds), default 2.
  See the `unique` parameter of the [post](#post) method.

The return value will be `true`, or `nil` and an error message.

[Back to TOC](#table-of-contents)

post
----
`syntax: ok, err = events.post(source, event, data, unique)`

Will post a new event. `source` and `event` are both strings. `data` can be anything (including `nil`)
as long as it is (de)serializable by the cjson or other module.

If the `unique` parameter is provided then only one worker will execute the event,
the other workers will ignore it. Also any follow up events with the same `unique`
value will be ignored (for the `unique_timeout` period specified to [configure](#configure)).
The process executing the event will not necessarily be the process posting the event.

The return value will be `true` when the event was successfully posted or
`nil + error` in case of failure.

*Note*: the worker process sending the event, will also receive the event! So if
the eventsource will also act upon the event, it should not do so from the event
posting code, but only when receiving it.

[Back to TOC](#table-of-contents)

post_local
----------
`syntax: ok, err = events.post_local(source, event, data)`

The same as [post](#post) except that the event will be local to the worker process,
it will not be broadcasted to other workers. With this method, the `data` element
will not be serialized.

The return value will be `true` when the event was successfully posted or
`nil + error` in case of failure.

[Back to TOC](#table-of-contents)

register
--------
`syntax: events.register(callback, source, event1, event2, ...)`

Will register a callback function to receive events. If `source` and `event` are omitted, then the
callback will be executed on _every_ event, if `source` is provided, then only events with a
matching source will be passed. If (one or more) event name is given, then only when
both `source` and `event` match the callback is invoked.

The callback should have the following signature;

`syntax: callback = function(data, event, source, pid)`

The parameters will be the same as the ones provided to [post](#post), except for the extra value
`pid` which will be the pid of the originating worker process, or `nil` if it was a local event
only. Any return value from `callback` will be discarded.
*Note:* `data` may be a reference type of data (eg. a Lua `table`  type). The same value is passed
to all callbacks, _so do not change the value in your handler, unless you know what you are doing!_

The return value of `register` will be `true`, or it will throw an error if `callback` is not a
function value.

calling [configure](#configure)

[Back to TOC](#table-of-contents)

unregister
----------
`syntax: events.unregister(callback, source, event1, event2, ...)`

Will unregister the callback function and prevent it from receiving further events. The parameters
work exactly the same as with [register](#register).

The return value will be `true` if it was removed, `false` if it was not in the handlers list, or
it will throw an error if `callback` is not a function value.

[Back to TOC](#table-of-contents)


Copyright and License
=====================

This module is licensed under the [Apache 2.0 license](https://opensource.org/licenses/Apache-2.0).

Copyright (C) 2022, Kong Inc.

All rights reserved.

[Back to TOC](#table-of-contents)


See Also
========
* OpenResty: http://openresty.org

[Back to TOC](#table-of-contents)

