# EV::WebKit

Async WebKitGTK 6.0 (GTK4) browser automation for Perl, on the
[EV](https://metacpan.org/pod/EV) event loop. Firefox::Marionette-inspired,
WebKit-native, pure Perl over GObject Introspection -- no XS, no C compiler
needed for this distribution.

## Synopsis

    use EV;
    use EV::WebKit;

    die "WebKitGTK 6.0 / GTK4 typelibs not available\n"
        unless EV::WebKit->available;

    my $b = EV::WebKit->new(window => [1024, 768]);

    $b->go('https://example.com', sub {
        my (undef, $err) = @_;
        die "navigation failed: $err\n" if $err;

        $b->find('h1', sub {
            my ($el, $err) = @_;
            unless ($el) { $b->quit; EV::break; return }

            # text() is async too -- finish from inside its callback, or quit()
            # resolves the still-in-flight call with 'browser closed' first.
            $el->text(sub {
                print "H1: $_[0]\n";
                $b->quit;
                EV::break;
            });
        });
    });

    EV::run;

## Bring your own display

EV::WebKit never spawns or kills an X server. Run headless under:

    xvfb-run -a perl your-script.pl

or export a real `$DISPLAY` to get a visible, fully-interactive GTK4 window.
The test suite needs a display too -- run it as `xvfb-run -a make test`
(plain `make test` with no `$DISPLAY` set will cleanly `skip_all`).

## Chrome

Pass `chrome => 1` to `new` for a minimal built-in browser chrome (a header
bar with back/forward/reload buttons and an address entry) -- handy for
visible use on a real `$DISPLAY`; automation methods keep working unchanged.

## Controlling a browser that is already running

A browser is normally driveable only by the process that made it, which makes a
visible window a dead end: you can watch it, but nothing can ask it anything.
`EV::WebKit::Control` puts one on a unix socket.

```bash
perl eg/browser.pl --control /tmp/evwk.sock &   # a visible window, on a socket
perl eg/control.pl /tmp/evwk.sock https://perl.org
```

The window navigates while you watch, and you can still click around in it
yourself. The client is blocking by default, which is what you want from a shell:

```perl
use EV::WebKit::Client;

my $c = EV::WebKit::Client->connect('/tmp/evwk.sock');
say 'attached to: ', $c->hello->{uri} // '(nothing loaded)';   # where it already is

$c->go('https://example.com');
say $c->title;
say $c->find('h1')->text;

$c->disconnect;   # the browser keeps running -- cookies, logins and all
```

Pass `ev => 1` and every method takes a callback instead, exactly like
`EV::WebKit` itself, so code moves between a local browser and a remote one
without being rewritten.

Several clients can drive one browser at once. Their operations interleave just
as they would in one process -- including navigation, where a second `go()`
supersedes the first and that caller is told `'superseded'`. The protocol reports
what the browser actually did rather than faking exclusivity.

**Security.** Anyone who can connect to that socket can run arbitrary JavaScript
in the browser and read every cookie it holds. The socket is the authentication
boundary: it is created `0600`, it refuses a world-writable directory, and there
is deliberately no TCP listener.

## Cookie notes

cookie_jar => $file uses WebKit's native persistent cookie storage (sqlite
by default, jar_format => 'text' for cookies.txt format). Cookies need a
real expiry (max_age) to be persisted -- session cookies are excluded by
design; expiry round-trips. To capture session cookies too, use the explicit
JSON snapshot calls save_cookies($file, \@uris?, $cb) and load_cookies($file,
$cb) (snapshot expiry is not preserved; cookies load back as session cookies).
Use different files for the jar and snapshots.

## Persisting a full session

`cookie_jar` persists cookies. To persist a whole session -- `localStorage`,
`IndexedDB`, the cache, a login that lives in any of them -- pass
`data_dir => $path`:

    my $b = EV::WebKit->new(data_dir => "$ENV{HOME}/.myapp/session");
    # ...log in...
    # next run, same data_dir -> the session is already there

Different `data_dir`s are fully isolated. `cache_dir` optionally redirects the
disposable cache (e.g. to tmpfs). Session cookies and `sessionStorage` are never
persisted (WebKit treats both as per-session). One live instance per `data_dir`
at a time.

## Documentation

See `perldoc EV::WebKit` (and `perldoc EV::WebKit::Element`) for the full
API: navigation, synchronous and asynchronous JavaScript execution, element
find/interact, `wait_for`, screenshots, PDF export, settings/user-agent,
cookies, proxy, console/dialog/policy events, and request interception.

## Requirements

WebKitGTK 6.0, GTK4, JavaScriptCore 6.0 and libsoup3, with their
GObject-Introspection typelibs (`WebKit-6.0`, `Gtk-4.0`, `Gdk-4.0`,
`JavaScriptCore-6.0`, `Soup-3.0`); Glib::Object::Introspection, Glib::IO,
EV, EV::Glib, and Cpanel::JSON::XS (falls back to JSON::PP if unavailable).
Xvfb (or a real X server) to actually run anything. Linux only.

## License

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.
