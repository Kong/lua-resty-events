
lua-resty-events
=======================

Inter process Pub/Sub pattern for Nginx worker processes

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
    * [register_weak](#register_weak)
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
    lua_package_path "/path/to/lua-resty-worker-events/lib/?.lua;;";

}
```

Description
===========

[Back to TOC](#table-of-contents)


Methods
=======

[Back to TOC](#table-of-contents)

configure
---------
`syntax: ok, err = events.configure(opts)`

[Back to TOC](#table-of-contents)

post
----
`syntax: success, err = events.post(source, event, data, unique)`

Will post a new event. `source` and `event` are both strings. `data` can be anything (including `nil`)
as long as it is (de)serializable by the cjson module.

If the `unique` parameter is provided then only one worker will execute the event,
the other workers will ignore it. Also any follow up events with the same `unique`
value will be ignored (for the `timeout` period specified to [configure](#configure)).
The process executing the event will not necessarily be the process posting the event.

The return value will be `true` when the event was successfully posted or
`nil + error` in case of failure.

*Note*: the worker process sending the event, will also receive the event! So if
the eventsource will also act upon the event, it should not do so from the event
posting code, but only when receiving it.

[Back to TOC](#table-of-contents)

post_local
----------
`syntax: success, err = events.post_local(source, event, data)`

The same as [post](#post) except that the event will be local to the worker process,
it will not be broadcasted to other workers. With this method, the `data` element
will not be jsonified.

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

*WARNING*: event handlers must return quickly. If a handler takes more time than
the configured `timeout` value, events will be dropped!

*Note*: to receive the process own `started` event, the handler must be registered before
calling [configure](#configure)

[Back to TOC](#table-of-contents)

register_weak
-------------
`syntax: events.register_weak(callback, source, event1, event2, ...)`

This function is identical to `register`, with the exception that the module
will only hold _weak references_ to the `callback` function.

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

