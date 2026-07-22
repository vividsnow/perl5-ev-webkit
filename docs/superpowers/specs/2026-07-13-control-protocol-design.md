# EV::WebKit control protocol -- design

Date: 2026-07-13
Status: approved, ready for an implementation plan

## Problem

An `EV::WebKit` instance can only be driven by the process that created it. A
visible browser -- the window `eg/browser.pl` opens -- is therefore a dead end:
you can watch it, but nothing outside that script can ask it anything.

Three uses want the opposite, and all three are in scope:

1. **Poke a live window.** Keep a visible browser open and drive it ad hoc from
   a shell while watching what happens.
2. **Reuse expensive state.** The browser holds a login, cookies, a warmed-up
   single-page app. Separate scripts attach in turn and work without
   re-authenticating.
3. **Browser as a service.** A long-running process several clients drive
   concurrently.

Cross-language reach (a CDP/WebDriver-style public contract) is explicitly NOT a
goal. The protocol serves Perl clients; it is documented and stable, but it is
not trying to be an ecosystem.

## Shape

- One control socket controls **one browser** -- the instance that opened it. A
  render farm is N processes and N sockets, which keeps a crashed WebKit from
  taking its siblings with it. Requests carry a target field from day one, so a
  pool remains a compatible extension rather than a breaking change.
- The server **pushes** events (a client must see the human clicking links), but
  **decisions stay local**: `on_dialog` and `on_policy` must answer
  synchronously inside WebKit's dispatch frame, and blocking there for a network
  round-trip is precisely the EV::Glib wedge this module spent its whole review
  history eliminating. The browser process answers them itself and tells clients
  what it did.
- The client is **blocking by default and EV-native on request**: no callback
  means it blocks and returns the value (`say $c->title`), a callback means it
  behaves like `EV::WebKit` itself (`$c->go($uri, sub {...})`). Blocking mode is
  plain socket I/O, never a nested `EV::run`, so it cannot wedge anything.
- **Unix socket, newline-delimited JSON.** Filesystem permissions are the
  authentication. It is hand-debuggable with `socat`. Binary results go base64,
  or are avoided entirely by writing files server-side.

## Architecture

Two new modules ship in this distribution:

- `EV::WebKit::Control` -- the server, inside the browser process.
- `EV::WebKit::Client` (and `EV::WebKit::Client::Element`) -- the client.

`EV::WebKit` itself gains exactly one thing (`on_navigate`, below). It grows no
socket code.

**The server is a pure consumer of the public API.** It calls the same
`go`/`find`/`script` methods any caller would, and introduces no new code path
inside `EV::WebKit`. This is load-bearing, not tidiness: the core's invariants
hold because they are closed, and a server reaching into internals would reopen
every one of them. It also lets the protocol layer be tested on its own.

Activation is explicit rather than a constructor option, so the core has no
opinion about sockets:

    my $b   = EV::WebKit->new(chrome => 1, on_close => sub { EV::break });
    my $ctl = EV::WebKit::Control->listen($b, path => "$ENV{XDG_RUNTIME_DIR}/evwk.sock");
    EV::run;

`eg/browser.pl` gains `--control [path]`.

Client:

    my $c = EV::WebKit::Client->connect($path);      # blocking
    $c->go('https://example.com');
    say $c->title;
    my $el = $c->find('h1');
    say $el->text;

    my $c = EV::WebKit::Client->connect($path, ev => 1);   # EV-native
    $c->go('https://example.com', sub { my (undef, $err) = @_; ... });

**Events in a blocking client.** The server pushes events whenever it likes, so
a blocking client reading a response will often see event frames first. It
dispatches each to an `on_event` handler if one was given, and otherwise queues
it; `$c->events` drains the queue. Events are never confused with a response
(they carry `ev`, not `i`) and never block a caller waiting for one. A blocking
client that never asks for anything still collects events on its next call --
which is the honest limit of blocking mode, and the reason `ev => 1` exists.

## Wire

One JSON object per line, UTF-8, both directions.

Request:

    {"i":1,"m":"go","a":["https://x"],"o":{"timeout":10}}

`i` request id, `m` method, `a` positional arguments, `o` options. An optional
`t` names the target; today there is one target, and the field is validated but
unused -- it is the seam that lets a pool arrive later without a version bump.

Response, exactly one per request:

    {"i":1,"r":1}
    {"i":1,"e":"timeout"}

Event, at any time, unsolicited:

    {"ev":"console","text":"log: hi"}

On connect the server greets:

    {"ev":"hello","proto":1,"uri":"https://x","title":"X"}

so a client attaching to a long-lived session immediately knows where the
browser actually is. That is use case 2 in one frame.

**Methods** are the public API verbatim: `go`, `load_html`, `back`, `forward`,
`reload`, `stop`, `can_go_back`, `can_go_forward`, `uri`, `title`, `is_loading`,
`html`, `script`, `script_async`, `find`, `find_all`, `wait_for`, `screenshot`,
`pdf`, `settings`, `set_user_agent`, `user_agent`, `set_proxy`,
`show_devtools`, `set_cookie`, `cookies`, `clear_cookies`, `save_cookies`,
`load_cookies`, `quit`. Element methods are namespaced and carry a handle:
`{"m":"el.text","h":7}`.

`mock_scheme` is deliberately **not** exposed. Its argument is a Perl callback
that WebKit invokes inside the browser process to produce a response body; there
is nothing to marshal, and faking it (calling back to the client for each
request) would put a network round-trip inside a WebKit dispatch frame -- the
one thing this design refuses to do anywhere.

`quit` **is** exposed. Anyone who can open the socket can already kill the
process, so refusing would be theatre. When the browser goes -- a client's
`quit`, or the human closing the window -- the server pushes `{"ev":"close"}`
and closes every client socket, so a client can tell an orderly shutdown from a
crash by whether it saw the event before EOF.

Responses may arrive **out of order**: the underlying operations are
asynchronous and a `script` issued after a `pdf` will usually answer first.
Clients match on `i`, never on arrival order.

**Events:** `load` (a navigation this API started finished), `navigate` (the
page changed, whoever caused it), `console`, `error`, `dialog` and `policy`
(what the browser answered locally), `close`.

**Binary:** `screenshot(bytes => 1)` returns `{"r":{"b64":"..."}}`, about 33%
overhead. `screenshot($path)` and `pdf($path)` write server-side and return the
path, which is both cheaper and what a service wants anyway.

## Element handles

The server holds a table of handle id to `EV::WebKit::Element`, tagged with the
owning client. Handles are freed when:

- **the page navigates** -- every handle is stale by definition, the epoch
  changed;
- **the client disconnects**;
- `el.release` is called.

This is not bookkeeping for its own sake. Every `find()` mints a new `Element`
holding a reference to the browser, so a server that never frees them rebuilds,
in Perl, the unbounded-registry growth just fixed on the JavaScript side -- and
a `find()` poll loop against a long-lived page is the ordinary case. The three
rules bound the table by "handles made since the last navigation, by clients
still connected".

## Concurrency

Concurrent `script`/`find`/`html`/`screenshot`/cookie operations already
interleave; `pdf` is internally serialized by its own queue. Navigation is the
exception: a second `go()` **supersedes** the first, and that client's callback
resolves with `'superseded'`.

The protocol **reports this honestly rather than faking exclusivity**. Two
clients navigating at once behave exactly as two `go()` calls in one process do.
There is no lock, no request queue, and no pretence that the browser did
something it did not. If exclusivity is ever wanted, a `lock`/`unlock` pair is
additive.

## Errors

Every `EV::WebKit` callback is already `($result, $err)`, so it maps one to one:
`{"r":...}` or `{"e":"..."}`. The module's uniform error strings cross the wire
unchanged -- `'timeout'`, `'browser closed'`, `'superseded'`, `'stale element'`
-- so a remote client tests `$err eq 'timeout'` exactly as an in-process caller
does. That uniformity took several review rounds to enforce; the protocol
inherits it for nothing.

Every dispatch is guarded. A die in one client's request must never kill the
browser or drop another client's work -- the same lesson `quit()`'s flush loops
taught. A malformed line answers `{"i":null,"e":"bad request"}` and the
connection stays up. An unknown method answers with an error, never silence: a
dropped request is a hung client.

## Security

The socket is the authentication boundary, and the documentation says so
plainly:

> Anyone who can connect to this socket can run arbitrary JavaScript in this
> browser and read every cookie it holds.

That is what the tool is for. It is also why there is no TCP listener.

- Mode `0600`, under `$XDG_RUNTIME_DIR` by default (a `0700` temporary directory
  otherwise).
- Refuse to listen on a path inside a world-writable directory.
- A stale socket file is detected by connecting first: dead, unlink it and
  proceed; live, refuse to start.
- The socket file is removed on exit.

## The one change to EV::WebKit: `on_navigate`

`on_load` fires only for navigations the API started. Measured: click a link in
the window and `on_load` does not fire at all, though the page has changed --
`_finish_nav` returns early when there is no pending navigation. **The module
currently cannot tell you the user navigated.**

That is a hole in the visible mode regardless of this protocol, and the protocol
cannot work without closing it: a client attached to a window a human is also
using must know where that window went.

`on_navigate => sub { my ($uri) = @_ }` fires for **every** committed
navigation, whoever caused it, delivered on a clean tick like every other
callback. `on_load` keeps its current meaning, so nothing breaks; an
API-initiated navigation fires both. It ships with its own test.

## Testing

- **Codec**, with no browser: encode/decode, malformed input, unicode, large
  payloads.
- **Integration**, over a real temporary socket under `xvfb-run`: the whole
  method surface, blocking client and EV client.
- **Multi-client**: two clients concurrently; one `go` superseding another's;
  one client killed with `SIGKILL` mid-request without leaking the handle table
  or wedging the other.
- **Handle lifetime**: the table is empty after a navigation, and after a
  disconnect.
- **Re-attach** (use case 2): connect, set a cookie, disconnect, reconnect, and
  confirm the `hello` frame and the cookie both survive.
- **The wedge**: a client command that triggers a dialog (answered locally) must
  not wedge the loop, and a client command must never be delivered from inside a
  WebKit dispatch frame. Child-process containment, as in `t/05-wedge-ops.t` --
  a wedge spins rather than fails, so an in-process test would hang instead of
  reporting.
- **`on_navigate`**: fires for a link click, and for an API navigation alongside
  `on_load`.

## Not in v1

No TCP, no auth token, no TLS. No pool (the `t` field is reserved and unused).
No exclusive locking. No remote dialog or policy decisions. No binary framing --
base64 is sufficient, and a framed upgrade sits behind the `proto` version.
