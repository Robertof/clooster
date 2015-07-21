Clooster
========

Cl**oo**ster is a Perl script designed to automatically switch the address of a DNS record whenever
a server goes offline.

Clooster uses a *client-server architecture*, which removes the need of an additional monitoring
server. It also has the advantage of being expandable, even if right now it only supports a maximum
of two servers.

Features
--------

* Extremely easy to use and to configure: you need two servers, a Cloudflare account with an host,
  a JSON file and a Perl interpreter.
* [Cloudflare](https://www.cloudflare.com) and [Pushbullet](https://www.pushbullet.com) support out
  of the box, no extra modules needed.
* Small memory footprint and low number of dependencies. The script itself is only ~10KB!
* Depending on the kind of failure, Clooster detects an offline server instantly or in a few
  minutes.
* Only one script for both the client and the server.

Warning
-------

Beware! This script has been written for fun, and I do not have the time and resources required to
test it extensively. Don't blame me if something explodes, or if it doesn't work at all!

Instead, why don't you write a an issue or a pull request? ♥

Requirements
------------

Clooster depends on:

* [Perl](https://www.perl.org/) 5.10.1 or better.
* [Mojolicious](https://metacpan.org/release/Mojolicious), a lightweight framework with a lot of
  cool stuff.
* [JSON::MaybeXS](https://metacpan.org/release/JSON-MaybeXS), a module which does
  *the right thing* when decoding JSON.

Usage
-----

* Create a `CNAME` record on your domain pointing to your preferred host.
* Get an API key from the [account page](https://www.cloudflare.com/a/account/my-account) of
  Cloudflare.
* Optionally, get an API key from [Pushbullet](https://www.pushbullet.com).
* Configure the server and client instances of Clooster (you need two separate configs).
  See `clooster.json.example`.
* Put Clooster on your servers, and run the two instances (first the server one, then the client
  one). Don't forget to install any missing dependency with [cpan](http://www.cpan.org).

The path of the config file can be specified with the first argument passed to Clooster.
It defaults to `%{script_name}.json`.

FAQ
----

### Why didn't you just use [insert_awesome_service_name]? It's much better!

It's more fun when you do it by yourself.

### Why did you pick this ugly name?

Well, I was thinking about `cluster` and `max two servers` (2), so this name came out of my mind.

I'm not good at picking names.

### How does it work?

It's actually pretty simple. First and foremost, the script calls Cloudflare and gets the zone id
and an object representing the record that will be updated. Then, the server binds on the address
specified in the config and lets the client connect. Only **one** client is allowed at a time.
Other connections are instantly terminated.

When the client successfully connects to the server, the authorization string is sent: it's the
server name encoded with HMAC-SHA256 (the key is specified in the config). Nothing too fancy,
it's just to ensure that the script is talking to the right server.

Once the authorization is complete, the servers send a keep-alive string every 60 seconds to keep
the socket alive. The keep-alive string is the server name (`this_server` in the config).

A watchdog runs every 120 seconds, and does the following:

* Ensures that the client is connected to the server, and if it is not, a connection is attempted.
* Ensures that the keep-alive strings are being sent, by comparing the timestamp of the last
  keep-alive and the current system time.

When the socket is closed (either after a timeout, or simply because one server died), the
`down_handler()` function of the script is called. An up-to-date version of the record object is
retrieved from Cloudflare, to prevent wrong assumptions derived from old data.

Once the updated record is available (and even if it isn't - errors are suppressed in this case),
the script checks if the record is already set to the value of `this_server` in the config.
If it is, then there is nothing to do - it just notifies the administrator using Pushbullet, if
enabled, and then waits until the other server is up again. Otherwise, the record is updated
remotely by using the Cloudflare API, and a notification is sent.

Once the dead server is up again (and with it, the script), the same thing as before is performed,
except that the record is changed to the value of `cloudflare.preferred_value` in the config.

### How do I daemonize the script?

You can write an init script for your system init daemon. Systemd can do
[this and much more](https://wiki.archlinux.org/index.php/Systemd#Writing_unit_files).

### How do I retrieve the `device_iden` required to push to single devices?

You have to use a tool like `curl` from the command line to perform the task.

```sh
curl -H 'Authorization: Bearer <access_token>' -X GET https://api.pushbullet.com/v2/devices
```

[Source](https://docs.pushbullet.com/#devices).

### Why did you bother writing modules wrapping the API of Cloudflare and Pushbullet, when they are already available on CPAN?

Two reasons:

* I designed the script to be as lightweight as possible in terms of dependencies and memory
  footprint.
* I also wanted to perform as many operations as possible asynchronously, and the easiest way was
  to use [Mojo::UserAgent](https://metacpan.org/pod/Mojo::UserAgent).

Also, keep in mind that my implementations are specific to the script! They do not implement all
the methods of the respective APIs, and include a few quirks I am not proud about.

TODO
----

This is some of the stuff I'd add in another life:

* add a version number :P
* command-line interface (with `Getopt::Long`)
* conversion to the standard Perl application interface (`App::clooster` maybe?)
* support for multiple servers
* TLS support
* modularity (support other DNS services and notification methods)

License
-------

Copyright (C) 2015, Roberto Frenna.

This program is free software, you can redistribute it and/or modify it under the terms of the
Artistic License version 2.0.
