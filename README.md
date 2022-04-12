
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
    * [new](#new)
    * [init_worker](#init_worker)
    * [run](#run)
    * [publish](#publish)
    * [subscribe](#subscribe)
    * [unsubscribe](#unsubscribe)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)

Status
======

This library is still under development, APIs may be changed without notification.

Synopsis
========

```nginx
http {
    lua_package_path "/path/to/lua-resty-events/lib/?/init.lua;;";

    init_worker_by_lua_block {
        local opts = {
            listening = "unix:/tmp/events.sock",
        }

        local ev = require("resty.events").new(opts)
        if not ev then
            ngx.log(ngx.ERR, "failed to new events object: ", err)
        end

        local handler = function(data, event, source, wid)
            print("received event; source=", source,
                  ", event=", event,
                  ", data=", tostring(data),
                  ", from process ", wid)
        end

        local id1 = ev:subscribe("*", "*", handler)
        local id2 = ev:subscribe("source", "*", handler)
        local id3 = ev:subscribe("source", "event", handler)

        local ok, err = ev:init_worker()
        if not ok then
            ngx.log(ngx.ERR, "failed to init events: ", err)
        end

        -- store ev to global
        _G.ev = ev
    }

    # create a listening unix domain socket
    server {
        listen unix:/tmp/events.sock;
        location / {
            content_by_lua_block {
                -- fetch ev from global
                local ev = _G.ev
                ev:run()
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

1. broadcast an event to all workers processes, see [publish](#publish). Example:
a healthcheck running in one worker, but informing all workers of a failed
upstream node.
2. broadcast an event to the current worker only,
see `target` parameter of [publish](#publish).
3. coalesce external events to a single action. Example: all workers watch
external events indicating an in-memory cache needs to be refreshed. When
receiving it they all post it with a unique event hash (all workers generate the
same hash), see `target` parameter of [publish](#publish). Now only 1 worker will
receive the event _only once_, so only one worker will hit the upstream
database to refresh the in-memory data.

[Back to TOC](#table-of-contents)


Methods
=======

[Back to TOC](#table-of-contents)

new
---------
`syntax: ev = events.new(opts)`

Return a new events object.
It should be stored in global scope for [run](#run) later.

The `opts` parameter is a Lua table with named options:

* `listening`: the unix doamin socket, which must be same as another `server` block.
* `broker_id`: (optional) the worker id that will start to listen, default 0.
* `unique_timeout`: (optional) timeout of unique event data stored (in seconds), default 5.
  See the `target` parameter of the [publish](#publish) method.

The return value will be the event object, or `nil` and an error message.

[Back to TOC](#table-of-contents)

init_worker
---------
`syntax: ok, err = ev:init_worker()`

Will initialize the event listener. This should typically be called from the
`init_worker_by_lua` handler, because it will make sure only one Nginx worker
starts to listen on unix domain socket.

The return value will be `true`, or `nil` and an error message.

[Back to TOC](#table-of-contents)

run
---------
`syntax: ev:run()`

Active the event loop only in Nginx broker process, see opts `broker_id` of [new](#new).
it must be called in `content_by_lua*`.

`ev` object must be the same object returned by [new](#new).

[Back to TOC](#table-of-contents)

publish
----
`syntax: ok, err = ev:publish(target, source, event, data)`

Will post a new event. `target`, `source` and `event` are all strings. `data` can be anything (including `nil`)
as long as it is (de)serializable by the cjson or other module.

The `target` parameter could be:

* "all" : the event will be broadcasted to all workers.
* "current" : the event will be local to the worker process,
it will not be broadcasted to other workers. With this method, the `data` element
will not be serialized.
* _unique hash_ : the event will be send to only one worker.
Also any follow up events with the same hash value will be ignored
(for the `unique_timeout` period specified to [new](#new)).

The return value will be `true` when the event was successfully published or
`nil + error` in case of cjson serializition failure or event queue full.

*Note*: in case of "all" and "current" the worker process sending the event,
will also receive the event! So if the eventsource will also act upon the event,
it should not do so from the event posting code, but only when receiving it.

[Back to TOC](#table-of-contents)

subscribe
--------
`syntax: id = ev:subscribe(source, event, callback)`

Will register a callback function to receive events. If `source` and `event` are `*`, then the
callback will be executed on _every_ event, if `source` is provided and `event` is `*`, then only events with a
matching source will be passed. If event name is given, then only when
both `source` and `event` match the callback is invoked.

The callback should have the following signature;

`syntax: callback = function(data, event, source, wid)`

The parameters will be the same as the ones provided to [publish](#publish), except for the extra value
`wid` which will be the worker id of the originating worker process, or `nil` if it was a local event
only. Any return value from `callback` will be discarded.
*Note:* `data` may be a reference type of data (eg. a Lua `table`  type). The same value is passed
to all callbacks, _so do not change the value in your handler, unless you know what you are doing!_

The return value of `subscribe` will be a callback id, or it will throw an error if `callback` is not a
function value.

[Back to TOC](#table-of-contents)

unsubscribe
----------
`syntax: ev:unsubscribe(id)`

Will unregister the callback function and prevent it from receiving further events. The
parameter `id` is the return value of [subscribe](#subscribe).

[Back to TOC](#table-of-contents)


License
=======

```
Copyright 2022 Kong Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

[Back to TOC](#table-of-contents)


See Also
========
* Kong: https://konghq.com/

[Back to TOC](#table-of-contents)

