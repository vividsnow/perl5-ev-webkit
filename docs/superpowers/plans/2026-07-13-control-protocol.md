# EV::WebKit Control Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let another process drive an already-running `EV::WebKit` instance -- the visible window `eg/browser.pl` opens -- over a unix socket.

**Architecture:** Two new modules in this distribution. `EV::WebKit::Control` runs the server inside the browser process; `EV::WebKit::Client` (plus `::Client::Element`) is the client. They share one wire codec, `EV::WebKit::Protocol` (newline-delimited JSON). The server is a **pure consumer of the public API** -- it calls the same `go`/`find`/`script` any caller would and adds no code path inside `EV::WebKit`. The core gains only what it is genuinely missing: an `on_navigate` event and accessors for its `on_*` handlers.

**Tech Stack:** Perl 5.10+, EV (`EV::io` on the socket), `IO::Socket::UNIX`, `Cpanel::JSON::XS` (already a dependency), `Scalar::Util::weaken`. No new CPAN dependencies.

## Global Constraints

- **Design source:** `docs/superpowers/specs/2026-07-13-control-protocol-design.md`. Read it first.
- **POD and comments are plain ASCII.** No em-dashes, no unicode. Use `--`.
- **Never break the core's invariants.** `EV::WebKit::Control` may only use documented public methods of `EV::WebKit`. If you find yourself reaching into `$b->{...}`, stop -- that is the bug this design exists to avoid.
- **Weaken every closure that a long-lived object holds.** A handler stored on the browser that captures the browser strongly is a cycle Perl cannot collect. This module has shipped that bug more than once; `weaken(my $wb = $b)` is not optional.
- **Never call `EV::break` or block inside a WebKit/GLib dispatch frame.** It busy-spins the next `EV::run` forever (the EV::Glib wedge). This is why dialog and policy decisions stay local.
- **Tests needing a browser run under `xvfb-run -a`.** `xvfb-run -a prove -Ilib t/`. Codec tests must NOT need a browser.
- **A wedge spins, it does not fail.** Any test that could arm one runs in a child process under a shell `timeout`, as `t/05-wedge-ops.t` does. An in-process test would hang the suite instead of reporting.
- **Full suite green before every commit:** `xvfb-run -a prove -Ilib t/` (currently 40 files, 672 tests).
- **Commit author:** `git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit`. No AI attribution in messages.
- **Every new file goes in MANIFEST** (`make manifest`), or `make dist` ships an incomplete distribution.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/EV/WebKit.pm` (modify) | Gains `on_navigate` (fires for EVERY committed navigation, including ones a human causes) and get/set accessors for the `on_*` handlers. Nothing else. |
| `lib/EV/WebKit/Protocol.pm` (create) | The wire codec, and nothing else: `encode` a frame to a line, and a stateful line `decoder`. Pure -- no EV, no browser, no sockets. This is what makes the codec testable on its own. |
| `lib/EV/WebKit/Control.pm` (create) | The server. Listens, accepts, dispatches wire methods to the browser's public API, pushes events, owns the element-handle table. |
| `lib/EV/WebKit/Client.pm` (create) | The client. Blocking by default; EV-native with `ev => 1`. |
| `lib/EV/WebKit/Client/Element.pm` (create) | The remote element proxy: the same 14 methods, each one a `el.*` request carrying a handle. |
| `eg/browser.pl` (modify) | Gains `--control [path]`. |
| `t/82-navigate.t` .. `t/89-control-robust.t` (create) | One test file per task, below. |

---

## Task 1: `on_navigate` -- report navigation the API did not start

**Files:**
- Modify: `lib/EV/WebKit.pm` (the `bless` hash; the `load-changed` handler's `committed` branch; POD)
- Create: `t/82-navigate.t`
- Modify: `Changes`, `MANIFEST`

**Interfaces:**
- Consumes: nothing.
- Produces: `EV::WebKit->new(on_navigate => sub { my ($uri) = @_ })`. Fires on every committed navigation, whoever caused it. Delivered on a clean EV tick.

**Why:** `on_load` fires only for navigations this API started. Click a link in the window and NOTHING fires, though the page changed -- measured. A control client attached to a window a human is also using must know where that window went.

- [ ] **Step 1: Write the failing test**

Create `t/82-navigate.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

# on_load fires only for navigations the API started. A page that navigates
# ITSELF -- a human clicking a link in a visible window -- changed the page and
# told nobody: _finish_nav returns early when there is no pending nav. on_navigate
# reports every committed navigation, whoever caused it.

my (@nav, @load);
my $b = EV::WebKit->new(
    window      => [300,200], ephemeral => 1,
    on_navigate => sub { push @nav,  $_[0] },
    on_load     => sub { push @load, 'load' },
);
$b->mock_scheme('nv', sub {
    my $uri = shift;
    return ('<html><body><a id="lnk" href="nv://second">go</a></body></html>', 'text/html')
        if $uri =~ /first/;
    return ('<html><body><h1>SECOND</h1></body></html>', 'text/html');
});

# 1) an API-initiated navigation fires BOTH (on_navigate is additive, on_load unchanged)
$b->go('nv://first', sub { EV::break });
TWK::run_with_timeout(15);
for (1 .. 3) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run }   # let the settle tick land
is(scalar(@nav), 1, 'API navigation fires on_navigate');
is($nav[0], 'nv://first', '...with the uri');
is(scalar(@load), 1, '...and on_load still fires (unchanged)');

# 2) a navigation the page starts itself -- the human clicking a link
@nav = (); @load = ();
$b->script('document.getElementById("lnk").click()', sub { });
{ my $t = EV::timer(3, 0, sub { EV::break }); EV::run }
is(scalar(@nav), 1, 'a link click fires on_navigate (nothing used to fire at all)')
    or diag('the page changed and the caller was never told');
is($nav[0], 'nv://second', '...with the new uri');
is(scalar(@load), 0, '...and on_load does NOT (it means "the nav I started finished")');
is($b->uri, 'nv://second', 'sanity: the browser really did navigate');

# 3) load_html counts as a navigation too
@nav = ();
$b->load_html('<p>x</p>', sub { EV::break });
TWK::run_with_timeout(15);
is(scalar(@nav), 1, 'load_html fires on_navigate');

# 4) nothing after quit
@nav = ();
$b->quit;
for (1 .. 3) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run }
is(scalar(@nav), 0, 'no on_navigate after quit');

done_testing;
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd ~/dev/perl-modules/EV-WebKit && xvfb-run -a prove -Ilib t/82-navigate.t`
Expected: FAIL. Test 1 fails (`on_navigate` is not wired at all, so `@nav` stays empty), and so does the link-click test -- which is the whole point.

- [ ] **Step 3: Implement it**

In `lib/EV/WebKit.pm`, add the handler to the `bless` hash, next to `on_close`:

```perl
        on_close  => $o{on_close},
        on_navigate => $o{on_navigate},
```

Then in the `load-changed` handler, extend the `started`/`committed` branch:

```perl
        elsif ($ev eq 'started' || $ev eq 'committed') {
            my $p = $self->{pending};
            if ($p) {
                $p->[4] = 1;
                $p->[5] = $ev_view->get_uri if $ev eq 'committed';
            }
            # 'committed' is the moment WebKit switches to the new document, so
            # the view's uri is now definitively the new page's. Report it
            # however the navigation began: on_load only fires for navigations
            # this API started, so a page that navigates itself -- a human
            # clicking a link in a visible window -- changed the page and told
            # nobody. Deferred like every other callback, and dead-gated: a
            # navigate event after quit() is meaningless.
            $self->_defer($self->{on_navigate}, $ev_view->get_uri)
                if $ev eq 'committed' && $self->{on_navigate};
        }
```

Add to the POD's EVENTS section, immediately after the `on_load` entry:

```pod
=item C<< on_navigate => sub { my ($uri) = @_ } >>

Called for B<every> navigation that commits, whoever started it -- including
one the page starts itself, which is what a human clicking a link in a visible
window looks like. C<on_load> is not that: it fires only for a navigation this
API started, so without C<on_navigate> a browser you are also using by hand can
change page and tell you nothing.

An API navigation fires both. Delivered on a clean EV tick, so C<EV::break> is
safe from it.
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `xvfb-run -a prove -Ilib t/82-navigate.t`
Expected: PASS, 8 tests.

- [ ] **Step 5: Run the whole suite -- this touches the navigation core**

Run: `xvfb-run -a prove -Ilib t/`
Expected: PASS. Pay attention to `t/20-nav.t`, `t/64-nav.t`, `t/65-nav-overlap.t`, `t/66-nav-finished.t`, `t/21-teardown.t` -- the overlap and supersede logic lives in the handler you just edited.

- [ ] **Step 6: Commit**

```bash
make manifest
git add -A
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "on_navigate: report navigation the API did not start

on_load fires only for navigations this API started. Click a link in the window
and nothing fires at all, though the page has changed -- _finish_nav returns
early when there is no pending nav. The module could not tell you the user
navigated, which makes a visible browser unobservable to anything but the script
that opened it.

on_navigate fires for every committed navigation, whoever caused it. on_load
keeps its meaning, so nothing breaks; an API navigation fires both."
```

---

## Task 2: `on_*` accessors -- so a layer on top can observe without reaching inside

**Files:**
- Modify: `lib/EV/WebKit.pm` (extract `_install_console`; add the accessors; POD)
- Create: `t/83-handlers.t`
- Modify: `Changes`, `MANIFEST`

**Interfaces:**
- Consumes: `on_navigate` from Task 1.
- Produces: for each of `on_load on_error on_close on_navigate on_console on_dialog on_policy`, a get/set accessor:
  - `my $cb = $b->on_console;` returns the current handler (or undef)
  - `$b->on_console($cb)` sets it, returns `$b`, croaks on a non-coderef
  - Setting `on_console` for the first time installs the console proxy lazily.

**Why:** The constructor is currently the ONLY way to set these, so anything wanting to observe events had to *be* the code that created the browser. `EV::WebKit::Control` must chain an existing handler (`eg/browser.pl` prints console lines to the terminal AND the server forwards them to clients), and it must do so through the public API.

- [ ] **Step 1: Write the failing test**

Create `t/83-handlers.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use Scalar::Util qw(weaken);
use EV; use EV::WebKit;

# The constructor used to be the only way to set a handler, so anything that
# wanted to observe events had to BE the code that created the browser. A layer
# built on top (EV::WebKit::Control) has to chain an existing handler, through
# the public API -- not by reaching into the object.

my @seen;
my $b = EV::WebKit->new(window => [300,200], ephemeral => 1,
                        on_console => sub { push @seen, "orig: $_[0]" });

# get
is(ref $b->on_console, 'CODE', 'on_console reads back the handler given to new()');
is($b->on_navigate, undef, 'an unset handler reads back undef');

# set, and chain the previous one -- the pattern Control uses
my $prev = $b->on_console;
my @mine;
$b->on_console(sub { $prev->(@_); push @mine, "mine: $_[0]" });
isa_ok($b->on_console(sub { $prev->(@_); push @mine, "mine: $_[0]" }), 'EV::WebKit', 'the setter returns $b');

$b->load_html('<script>console.log("hi")</script>', sub { EV::break });
TWK::run_with_timeout(15);
{ my $t = EV::timer(1, 0, sub { EV::break }); EV::run }
ok(scalar(grep { /orig: log: hi/ } @seen), 'the chained-to original handler still runs');
ok(scalar(grep { /mine: log: hi/ } @mine), '...and so does the new one');

# a non-coderef croaks, like every other callback in this API
my $ok = eval { $b->on_load('not a coderef'); 1 };
ok(!$ok && $@ =~ /code reference/, 'a non-coderef handler croaks');

# undef clears it
$b->on_console(undef);
is($b->on_console, undef, 'a handler can be cleared');
$b->quit;

# on_console must work when it was NOT given to new() -- the proxy installs lazily
{
    my @late;
    my $c = EV::WebKit->new(window => [300,200], ephemeral => 1);   # no on_console
    $c->on_console(sub { push @late, $_[0] });
    $c->load_html('<script>console.log("late")</script>', sub { EV::break });
    TWK::run_with_timeout(15);
    { my $t = EV::timer(1, 0, sub { EV::break }); EV::run }
    ok(scalar(grep { /log: late/ } @late),
        'on_console set after construction still receives console output (proxy installed lazily)')
        or diag('the console proxy is only installed when on_console is given to new()');
    $c->quit;
}

# a handler must not keep the browser alive: the closure the caller gives is
# stored ON the browser, so a handler that captures $b strongly is a cycle.
# (This is the caller's business, but prove the ACCESSOR itself adds no ref.)
{
    my $wb;
    {
        my $d = EV::WebKit->new(window => [200,150], ephemeral => 1);
        weaken($wb = $d);
        $d->on_navigate(sub { });   # captures nothing
        $d->quit;
    }
    for (1 .. 3) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run }
    ok(!defined $wb, 'setting a handler does not make the instance uncollectable');
}

done_testing;
```

- [ ] **Step 2: Run it and watch it fail**

Run: `xvfb-run -a prove -Ilib t/83-handlers.t`
Expected: FAIL with `Can't locate object method "on_console" via package "EV::WebKit"`.

- [ ] **Step 3: Extract the console proxy so it can be installed lazily**

In `lib/EV/WebKit.pm`, replace the whole `if ($self->{on_console} = $o{on_console}) { ... }` block in `new()` with:

```perl
    $self->{on_console} = $o{on_console};
    $self->_install_console if $self->{on_console};
```

Then add the extracted method (put it next to `_install_boot`). Note it captures `$self` WEAKLY, exactly as the inlined version did:

```perl
# Install the console proxy: a user script that wraps console.log/warn/error/info
# in the page's MAIN world (it has to override the console the page's own code
# calls) and posts each line to a script-message handler. Idempotent, and called
# lazily by the on_console accessor -- until something wants console output there
# is no reason to touch the page at all.
#
# NOTE: user scripts are injected at document-start, so enabling on_console after
# a page has loaded takes effect from the NEXT navigation.
sub _install_console {
    my $self = shift;
    return if $self->{_console_installed}++;
    my $ucm = $self->{ucm} or return;
    weaken(my $wself = $self);
    $ucm->register_script_message_handler('evwk', undef);
    $ucm->signal_connect('script-message-received' => sub {
        my (undef, $val) = @_;
        local $IN_DISPATCH = 1;      # on_console runs nested in WebKit's dispatch frame -- see quit
        my $self = $wself or return;
        return if $self->{_dead};    # torn down: the page is gone, do not call back into user code
        my $text = eval { $val->to_string };
        return unless defined $text && $self->{on_console};
        unless (eval { $self->{on_console}->($text); 1 }) {
            warn "EV::WebKit: on_console callback died: $@";
        }
    });
    my $proxy = <<'JS';
(function(){ try {
  const post = (t)=>window.webkit.messageHandlers.evwk.postMessage(String(t));
  ['log','warn','error','info'].forEach(k=>{ const o=console[k];
    console[k]=function(){ try{post(k+': '+Array.from(arguments).join(' '))}catch(e){}; return o.apply(console,arguments); }; });
} catch(e){} })();
JS
    $ucm->add_script(WebKit::UserScript->new($proxy, 'all-frames', 'start', undef, undef));
    return;
}
```

Confirm `$self->{ucm}` is set before `_install_console` is called in `new()`; if the UCM is stored under a different key, use that key (grep for `ucm`).

- [ ] **Step 4: Add the accessors**

Add near the other public methods:

```perl
# Get/set accessors for the event handlers. Without these the constructor is the
# only way to set one, so anything that wants to observe a browser has to BE the
# code that created it -- which is exactly what EV::WebKit::Control must not
# require. With them, a layer on top can CHAIN:
#
#     my $prev = $b->on_console;
#     $b->on_console(sub { $prev->(@_) if $prev; ...mine... });
#
# through the public API, instead of reaching into the object.
for my $h (qw/on_load on_error on_close on_navigate on_console on_dialog on_policy/) {
    no strict 'refs';
    *{__PACKAGE__ . "::$h"} = sub {
        my $self = shift;
        return $self->{$h} unless @_;
        my $cb = shift;
        Carp::croak("$h: expected a code reference") if defined $cb && ref $cb ne 'CODE';
        $self->{$h} = $cb;
        # The console proxy is only injected when something actually wants
        # console output; enabling it late is legal (from the next navigation).
        $self->_install_console if $h eq 'on_console' && $cb && !$self->{_dead};
        return $self;
    };
}
```

Add a POD section after the EVENTS list:

```pod
=head2 Handler accessors

    my $cb = $b->on_console;          # get
    $b->on_console(sub { ... });      # set, returns $b
    $b->on_console(undef);            # clear

Every C<on_*> handler (C<on_load>, C<on_error>, C<on_close>, C<on_navigate>,
C<on_console>, C<on_dialog>, C<on_policy>) has a get/set accessor, so code that
did not construct the browser can still observe it -- and can B<chain> an
existing handler rather than clobbering it:

    my $prev = $b->on_console;
    $b->on_console(sub { $prev->(@_) if $prev; ...also mine... });

Croaks on a non-coderef. Enabling C<on_console> after a page has loaded takes
effect from the next navigation: the console proxy is a user script, and those
are injected at document start.
```

- [ ] **Step 5: Run the test and the full suite**

Run: `xvfb-run -a prove -Ilib t/83-handlers.t` -- expected PASS.
Run: `xvfb-run -a prove -Ilib t/` -- expected PASS. Watch `t/70-console.t` especially: you just moved its machinery.

- [ ] **Step 6: Commit**

```bash
make manifest
git add -A
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "accessors for the on_* handlers, and a lazily-installed console proxy

The constructor was the only way to set a handler, so anything that wanted to
observe a browser had to BE the code that created it. A layer on top has to
chain an existing handler, and it must do that through the public API rather
than reaching into the object.

The console proxy now installs on demand, so on_console works when it is set
after construction (from the next navigation -- user scripts are injected at
document start)."
```

---

## Task 3: `EV::WebKit::Protocol` -- the wire codec, with no browser in sight

**Files:**
- Create: `lib/EV/WebKit/Protocol.pm`
- Create: `t/84-protocol.t`
- Modify: `MANIFEST`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `EV::WebKit::Protocol::PROTO` -- constant, `1`.
  - `EV::WebKit::Protocol::MAX_LINE` -- constant, `67108864` (64 MiB).
  - `EV::WebKit::Protocol::encode($hashref)` -- returns one line of UTF-8 octets, newline-terminated.
  - `EV::WebKit::Protocol::decoder()` -- returns a coderef. Call it with octets; it returns a list of decoded frames (hashrefs). A line that is not a JSON object comes back as `{ _bad => $reason }` rather than dying.

**Why separate:** this is the only piece testable with no browser and no event loop, and both server and client need identical buffering. Duplicating "split on newlines, tolerate partial reads" in two places is how they drift.

- [ ] **Step 1: Write the failing test**

Create `t/84-protocol.t` (note: NO `TWK`, no browser, no xvfb needed):

```perl
use v5.10; use strict; use warnings;
use Test::More;
use EV::WebKit::Protocol;

# The wire codec, on its own. No browser, no event loop, no socket.

is(EV::WebKit::Protocol::PROTO, 1, 'protocol version is 1');

# encode: one line, newline-terminated, UTF-8 OCTETS (this goes on a socket)
my $line = EV::WebKit::Protocol::encode({ i => 1, m => 'go', a => ['x'] });
like($line, qr/\n\z/, 'encode ends with a newline');
unlike(substr($line, 0, -1), qr/\n/, '...and contains no other newline');
ok(!utf8::is_utf8($line), 'encode returns octets, not characters');

# round-trip
my $dec = EV::WebKit::Protocol::decoder();
my @f = $dec->($line);
is(scalar(@f), 1, 'one line decodes to one frame');
is_deeply($f[0], { i => 1, m => 'go', a => ['x'] }, '...round-tripped intact');

# partial reads: a socket splits wherever it likes, including mid-character
{
    my $d = EV::WebKit::Protocol::decoder();
    my $l = EV::WebKit::Protocol::encode({ i => 2, m => 'title' });
    my @got;
    push @got, $d->($_) for split //, $l;      # one octet at a time
    is(scalar(@got), 1, 'a frame split across every possible boundary still decodes once');
    is($got[0]{i}, 2, '...intact');
}

# several frames in one chunk
{
    my $d = EV::WebKit::Protocol::decoder();
    my $chunk = join '', map { EV::WebKit::Protocol::encode({ i => $_ }) } 1 .. 3;
    my @got = $d->($chunk);
    is(scalar(@got), 3, 'three frames in one read decode to three frames');
    is_deeply([ map { $_->{i} } @got ], [1,2,3], '...in order');
}

# unicode survives the wire
{
    my $d = EV::WebKit::Protocol::decoder();
    my $text = "caf\x{e9} \x{4e2d}\x{6587} \x{1f600}";
    my @got = $d->(EV::WebKit::Protocol::encode({ i => 9, r => $text }));
    is($got[0]{r}, $text, 'unicode round-trips (encode octets, decode characters)');
}

# garbage must not kill the server: one client's bad line is that client's problem
{
    my $d = EV::WebKit::Protocol::decoder();
    my @got = $d->(qq({"i":1,"m":"go"}\n) . qq(not json at all\n) . qq({"i":2}\n));
    is(scalar(@got), 3, 'a bad line does not swallow the good ones around it');
    is($got[0]{m}, 'go', 'the frame before it is fine');
    ok($got[1]{_bad}, 'the bad line comes back marked, not thrown');
    is($got[2]{i}, 2, 'the frame after it is fine');
}

# valid JSON that is not an object is still a bad frame
{
    my $d = EV::WebKit::Protocol::decoder();
    my @got = $d->(qq(123\n["a"]\n));
    ok($got[0]{_bad} && $got[1]{_bad}, 'a JSON scalar or array is not a frame');
}

# blank lines are tolerated
{
    my $d = EV::WebKit::Protocol::decoder();
    my @got = $d->(qq(\n\n{"i":1}\n));
    is(scalar(@got), 1, 'blank lines are ignored');
}

# a client that never sends a newline must not eat all our memory
{
    my $d = EV::WebKit::Protocol::decoder();
    my @got = $d->('x' x (EV::WebKit::Protocol::MAX_LINE + 1));
    ok($got[0]{_bad}, 'an oversized line is refused rather than buffered forever');
    like($got[0]{_bad}, qr/too long/, '...saying why');
}

done_testing;
```

- [ ] **Step 2: Run it and watch it fail**

Run: `prove -Ilib t/84-protocol.t` (no xvfb needed -- that is the point)
Expected: FAIL, `Can't locate EV/WebKit/Protocol.pm`.

- [ ] **Step 3: Write the codec**

Create `lib/EV/WebKit/Protocol.pm`:

```perl
package EV::WebKit::Protocol;
use v5.10;
use strict;
use warnings;

our $VERSION = '0.01';

# The control protocol's wire codec, and nothing else: no EV, no sockets, no
# browser. Both the server (EV::WebKit::Control) and the client
# (EV::WebKit::Client) use it, so "split on newlines, tolerate a partial read"
# exists once instead of drifting in two places.
#
# One JSON object per line, UTF-8 octets. See
# docs/superpowers/specs/2026-07-13-control-protocol-design.md

use constant PROTO => 1;

# A client that opens a socket and never sends a newline would otherwise buffer
# without bound. 64 MiB is far above any real frame (a base64 full-page
# screenshot is a few MiB) and far below "eat the machine".
use constant MAX_LINE => 64 * 1024 * 1024;

# utf8(1): unlike EV::WebKit's own JSON object (which is in CHARACTER mode,
# because Glib::Object::Introspection marshals utf8 strings as characters), this
# one writes to a SOCKET and must produce octets.
my $JSON = do {
    my $j = eval { require Cpanel::JSON::XS; Cpanel::JSON::XS->new }
         || do { require JSON::PP; JSON::PP->new };
    $j->canonical(1)->utf8(1);
};

sub encode { $JSON->encode($_[0]) . "\n" }

# Returns a stateful decoder. Feed it octets; it returns however many complete
# frames those octets completed (possibly none). A line that is not a JSON
# object comes back as { _bad => $reason } instead of dying -- one client's
# garbage must not take down the browser or anybody else's session.
sub decoder {
    my $buf  = '';
    my $dead = 0;
    return sub {
        my ($octets) = @_;
        return ({ _bad => 'line too long' }) if $dead;
        $buf .= $octets if defined $octets && length $octets;
        if (length($buf) > MAX_LINE) {
            $dead = 1;
            $buf  = '';
            return ({ _bad => 'line too long' });
        }
        my @frames;
        while ((my $nl = index($buf, "\n")) >= 0) {
            my $line = substr($buf, 0, $nl, '');   # take the line...
            substr($buf, 0, 1, '');                # ...and drop the newline
            next unless length $line;              # blank lines are nothing
            my $f = eval { $JSON->decode($line) };
            push @frames, (ref $f eq 'HASH') ? $f : { _bad => 'bad request' };
        }
        return @frames;
    };
}

1;

__END__

=head1 NAME

EV::WebKit::Protocol - wire codec for the EV::WebKit control protocol

=head1 DESCRIPTION

Newline-delimited JSON. One object per line, UTF-8 octets. Used by
L<EV::WebKit::Control> and L<EV::WebKit::Client>; you do not normally touch it
directly.

=head1 FUNCTIONS

=head2 encode

    my $line = EV::WebKit::Protocol::encode({ i => 1, m => 'go', a => ['x'] });

Returns one newline-terminated line of UTF-8 octets.

=head2 decoder

    my $dec = EV::WebKit::Protocol::decoder();
    my @frames = $dec->($octets_from_the_socket);

Returns a stateful decoder. Feed it whatever the socket gave you -- partial
lines, several lines, one byte -- and it returns the frames those octets
completed. A line that is not a JSON object is returned as
C<< { _bad => $reason } >> rather than thrown: one client's garbage is that
client's problem.

=cut
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `prove -Ilib t/84-protocol.t`
Expected: PASS, 17 tests, in well under a second (no browser).

- [ ] **Step 5: Commit**

```bash
make manifest
git add -A
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "EV::WebKit::Protocol: the control protocol's wire codec

Newline-delimited JSON, UTF-8 octets, with a bounded read buffer so a client
that never sends a newline cannot eat the machine. A line that is not a JSON
object comes back marked rather than thrown: one client's garbage must not take
down the browser.

Separate from the server and the client because it is the one piece testable
with no browser and no event loop, and because both ends need identical
buffering."
```

---

## Task 4: `EV::WebKit::Control` -- listen, accept, dispatch

**Files:**
- Create: `lib/EV/WebKit/Control.pm`
- Create: `t/85-control.t`
- Modify: `MANIFEST`

**Interfaces:**
- Consumes: `EV::WebKit::Protocol::{encode,decoder,PROTO}` (Task 3).
- Produces:
  - `EV::WebKit::Control->listen($browser, path => $path)` -- returns the server object. Croaks if the directory is world-writable, or if a live server already owns the path.
  - `$ctl->path` -- the socket path.
  - `$ctl->close` -- close all clients, stop listening, unlink the socket. Idempotent. Also runs from `DESTROY`.
  - Wire: `{"i":N,"m":"<method>","a":[...],"o":{...}}` -> `{"i":N,"r":...}` or `{"i":N,"e":"..."}`; a `{"ev":"hello","proto":1,"uri":...,"title":...}` on connect.

**Scope of this task:** sync and async methods whose results are plain scalars. `find`/`find_all` and the `el.*` methods come in Task 6 -- a request for them here answers `{"e":"unknown method"}`, and Task 6's test is what changes that.

- [ ] **Step 1: Write the failing test**

Create `t/85-control.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use EV; use EV::WebKit; use EV::WebKit::Control; use EV::WebKit::Protocol;

# The server, driven by a RAW socket -- no client module yet, on purpose: the
# server must be correct on its own terms, not merely agree with a client that
# shares its bugs.

my $dir  = tempdir(CLEANUP => 1);
my $path = "$dir/ctl.sock";

my $b = EV::WebKit->new(window => [300,200], ephemeral => 1);
$b->mock_scheme('cs', sub { ('<html><head><title>T</title></head><body><h1>hi</h1></body></html>', 'text/html') });
my $ctl = EV::WebKit::Control->listen($b, path => $path);
ok(-S $path, 'the socket exists');
is((stat $path)[2] & 07777, 0600, 'and is mode 0600 -- the socket IS the auth boundary');

# a tiny raw client: write a frame, pump the loop, collect frames
my $sock = IO::Socket::UNIX->new(Peer => $path) or BAIL_OUT("connect: $!");
$sock->blocking(0);
my $dec = EV::WebKit::Protocol::decoder();
my @in;
my $rw = EV::io($sock, EV::READ, sub {
    my $n = sysread($sock, my $buf, 65536);
    return EV::break unless $n;      # EOF
    push @in, $dec->($buf);
    EV::break;
});
sub pump {                            # run until we have $_[0] frames, or time out
    my ($want, $secs) = (@_, 10);
    my $wd = EV::timer($secs, 0, sub { EV::break });
    EV::run while @in < $want && do { my $t = EV::timer(0, 0, sub {}); 1 } && 0;
    # simple: keep running until enough frames or the watchdog fires
    while (@in < $want) { my $stop = 0; my $g = EV::timer($secs, 0, sub { $stop = 1; EV::break }); EV::run; last if $stop }
    undef $wd;
    return;
}
sub send_frame { my $l = EV::WebKit::Protocol::encode($_[0]); syswrite($sock, $l) }

# 1) hello on connect: a client attaching to a long-lived session must learn
#    where the browser actually IS without asking
pump(1);
is($in[0]{ev}, 'hello', 'the server greets a new client');
is($in[0]{proto}, EV::WebKit::Protocol::PROTO, '...with the protocol version');

# 2) a sync method
@in = ();
send_frame({ i => 1, m => 'uri' });
pump(1);
is($in[0]{i}, 1, 'a response carries the request id');
ok(exists $in[0]{r}, '...and a result');

# 3) an async method, end to end
@in = ();
send_frame({ i => 2, m => 'go', a => ['cs://p'] });
pump(1, 20);
is($in[0]{i}, 2, 'go() answers');
ok(!exists $in[0]{e}, '...without error') or diag("err=$in[0]{e}");

@in = ();
send_frame({ i => 3, m => 'title' });
pump(1);
is($in[0]{r}, 'T', 'title reflects the page the client navigated to');

# 4) errors come back as errors, never as silence (a dropped request is a hung client)
@in = ();
send_frame({ i => 4, m => 'no_such_method' });
pump(1);
like($in[0]{e}, qr/unknown method/, 'an unknown method answers with an error');

@in = ();
send_frame({ i => 5, m => 'go', a => [undef] });
pump(1);
like($in[0]{e}, qr/uri required/, "the module's own error strings cross the wire unchanged");

# 5) a malformed line is answered, and the connection survives
@in = ();
syswrite($sock, "this is not json\n");
pump(1);
ok($in[0]{e}, 'a malformed line gets an error');
@in = ();
send_frame({ i => 6, m => 'uri' });
pump(1);
is($in[0]{i}, 6, '...and the connection is still usable afterwards');

# 6) close() cleans up after itself
$ctl->close;
ok(!-e $path, 'close() unlinks the socket');
$b->quit;
done_testing;
```

- [ ] **Step 2: Run it and watch it fail**

Run: `xvfb-run -a prove -Ilib t/85-control.t`
Expected: FAIL, `Can't locate EV/WebKit/Control.pm`.

- [ ] **Step 3: Write the server**

Create `lib/EV/WebKit/Control.pm`:

```perl
package EV::WebKit::Control;
use v5.10;
use strict;
use warnings;

use Carp ();
use Errno ();
use EV;
use IO::Socket::UNIX;
use Scalar::Util qw(weaken);
use EV::WebKit::Protocol;

our $VERSION = '0.01';

# A control server for a running EV::WebKit instance. See
# docs/superpowers/specs/2026-07-13-control-protocol-design.md
#
# This server is a PURE CONSUMER of EV::WebKit's public API. It calls the same
# go()/find()/script() any caller would and adds no code path inside the browser.
# That is load-bearing, not tidiness: the core's invariants hold because they are
# closed, and a socket server reaching into internals would reopen every one of
# them. If you find yourself writing $b->{...}, stop.

# Methods that answer immediately.
my %SYNC = map { $_ => 1 } qw(
    uri title is_loading user_agent can_go_back can_go_forward
    stop settings set_user_agent set_proxy show_devtools quit
);

# Methods that take a trailing callback and answer later.
my %ASYNC = map { $_ => 1 } qw(
    go load_html back forward reload
    script script_async html wait_for screenshot pdf
    set_cookie cookies clear_cookies save_cookies load_cookies
);

sub listen {
    my ($class, $browser, %o) = @_;
    Carp::croak('listen: a browser is required') unless ref $browser;
    my $path = $o{path} or Carp::croak('listen: path is required');

    # The socket is the authentication boundary: anyone who can connect can run
    # arbitrary JavaScript in this browser and read every cookie it holds. So
    # refuse to put it anywhere the world can reach.
    my ($dir) = $path =~ m{^(.*)/[^/]+$};
    $dir //= '.';
    my @st = stat $dir or Carp::croak("listen: cannot stat '$dir': $!");
    Carp::croak("listen: refusing to listen in a world-writable directory ('$dir')")
        if ($st[2] & 0002) && !($st[2] & 01000);   # world-writable and not sticky

    # A leftover socket file from a crashed process is common; a LIVE one means
    # somebody else already owns this path. Tell them apart by connecting.
    if (-e $path) {
        if (IO::Socket::UNIX->new(Peer => $path)) {
            Carp::croak("listen: '$path' is already served by a live process");
        }
        unlink $path or Carp::croak("listen: cannot remove stale socket '$path': $!");
    }

    my $old = umask 0177;             # create it 0600 without a chmod race
    my $srv = IO::Socket::UNIX->new(Local => $path, Listen => 16);
    umask $old;
    Carp::croak("listen: cannot listen on '$path': $!") unless $srv;
    $srv->blocking(0);

    my $self = bless {
        browser => $browser,
        path    => $path,
        srv     => $srv,
        clients => {},      # id => client state
        next_id => 0,
    }, $class;

    weaken(my $wself = $self);
    $self->{aw} = EV::io($srv, EV::READ, sub {
        my $s = $wself or return;
        while (my $fh = $s->{srv}->accept) { $s->_add_client($fh) }
    });

    return $self;
}

sub path { $_[0]{path} }

sub _add_client {
    my ($self, $fh) = @_;
    $fh->blocking(0);
    my $id = ++$self->{next_id};
    my $c  = $self->{clients}{$id} = {
        id  => $id,
        fh  => $fh,
        dec => EV::WebKit::Protocol::decoder(),
        out => '',
    };

    weaken(my $wself = $self);
    $c->{rw} = EV::io($fh, EV::READ, sub {
        my $s = $wself or return;
        my $n = sysread($fh, my $buf, 65536);
        if (!defined $n) {
            return if $!{EAGAIN} || $!{EINTR};
            return $s->_drop_client($id);
        }
        return $s->_drop_client($id) unless $n;     # EOF
        $s->_dispatch($id, $_) for $c->{dec}->($buf);
    });

    # Greet: a client attaching to a long-lived session learns where the browser
    # actually is without having to ask.
    my $b = $self->{browser};
    $self->_send($id, {
        ev    => 'hello',
        proto => EV::WebKit::Protocol::PROTO,
        uri   => scalar eval { $b->uri },
        title => scalar eval { $b->title },
    });
    return;
}

sub _drop_client {
    my ($self, $id) = @_;
    my $c = delete $self->{clients}{$id} or return;
    $self->_release_handles_of($id) if $self->can('_release_handles_of');
    delete $c->{rw};
    delete $c->{ww};
    close $c->{fh};
    return;
}

# Queue a frame and flush what we can. A slow or stalled client must never block
# the browser, so anything the socket will not take right now waits in {out} and
# a write watcher drains it.
sub _send {
    my ($self, $id, $frame) = @_;
    my $c = $self->{clients}{$id} or return;
    $c->{out} .= EV::WebKit::Protocol::encode($frame);
    $self->_flush($id);
    return;
}

sub _flush {
    my ($self, $id) = @_;
    my $c = $self->{clients}{$id} or return;
    while (length $c->{out}) {
        my $n = syswrite($c->{fh}, $c->{out});
        if (!defined $n) {
            last if $!{EAGAIN} || $!{EINTR};
            return $self->_drop_client($id);
        }
        substr($c->{out}, 0, $n, '');
    }
    if (length $c->{out}) {
        weaken(my $wself = $self);
        $c->{ww} ||= EV::io($c->{fh}, EV::WRITE, sub {
            my $s = $wself or return;
            $s->_flush($id);
        });
    }
    else {
        delete $c->{ww};
    }
    return;
}

sub _dispatch {
    my ($self, $id, $f) = @_;
    return $self->_send($id, { i => undef, e => $f->{_bad} }) if $f->{_bad};

    my $rid = $f->{i};
    my $m   = $f->{m} // '';
    my @a   = @{ $f->{a} // [] };
    my %o   = %{ $f->{o} // {} };
    my $b   = $self->{browser};

    weaken(my $wself = $self);
    my $answer = sub {                       # exactly one response per request
        my ($r, $e) = @_;
        my $s = $wself or return;
        $s->_send($id, defined $e ? { i => $rid, e => "$e" } : { i => $rid, r => $r });
    };

    if ($SYNC{$m}) {
        # Sync methods can croak (settings, set_user_agent, set_proxy do). A die
        # in one client's request must never kill the browser or drop anybody
        # else's work -- the same lesson quit()'s flush loops taught.
        my $r = eval { $b->$m(@a ? @a : ()) };
        return $answer->(undef, _clean($@)) if $@;
        # a method that returns $b (a mutator) must not be serialized as an object
        $r = 1 if ref $r;
        return $answer->($r);
    }

    if ($ASYNC{$m}) {
        my $r = eval { $b->$m(@a, (%o ? (%o) : ()), sub { $answer->(@_) }); 1 };
        return $answer->(undef, _clean($@)) unless $r;
        return;
    }

    return $answer->(undef, "unknown method: $m");
}

sub _clean {
    my $e = shift // 'error';
    $e =~ s/ at \S+ line \d+\.?\n?\z//;
    chomp $e;
    return $e;
}

sub close {
    my $self = shift;
    return if $self->{_closed}++;
    delete $self->{aw};
    $self->_drop_client($_) for keys %{ $self->{clients} };
    close $self->{srv} if $self->{srv};
    unlink $self->{path} if defined $self->{path} && -S $self->{path};
    return;
}

sub DESTROY { local $@; eval { $_[0]->close } }

1;

__END__

=head1 NAME

EV::WebKit::Control - drive a running EV::WebKit instance from another process

=head1 SYNOPSIS

    use EV; use EV::WebKit; use EV::WebKit::Control;

    my $b   = EV::WebKit->new(chrome => 1, on_close => sub { EV::break });
    my $ctl = EV::WebKit::Control->listen($b, path => "$ENV{XDG_RUNTIME_DIR}/evwk.sock");
    EV::run;

=head1 SECURITY

B<Anyone who can connect to this socket can run arbitrary JavaScript in this
browser and read every cookie it holds.> That is what the tool is for. The
socket is the authentication boundary: it is created mode C<0600>, and
C<listen> refuses a world-writable directory. There is deliberately no TCP
listener.

=cut
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `xvfb-run -a prove -Ilib t/85-control.t`
Expected: PASS. If `pump()` hangs, the server is not answering -- check that `EV::run` is being entered (the browser's own EV loop is what drives the socket watchers).

- [ ] **Step 5: Full suite, then commit**

Run: `xvfb-run -a prove -Ilib t/` -- expected PASS (nothing else changed).

```bash
make manifest
git add -A
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "EV::WebKit::Control: listen, accept, dispatch

A unix-socket server for a running browser. It is a pure consumer of the public
API -- it calls the same methods any caller would and adds no code path inside
EV::WebKit, which is what keeps the core's invariants closed.

The socket is the auth boundary: 0600, no world-writable directory, no TCP. A
stale socket file is told from a live one by connecting to it. Writes are
buffered, so a stalled client cannot block the browser. Every dispatch is
guarded: one client's die must not kill the browser or drop another's work."
```

---

## Task 5: events -- push what the client did not ask for

**Files:**
- Modify: `lib/EV/WebKit/Control.pm` (add `_wire_events`, `_broadcast`; call from `listen`)
- Create: `t/86-control-events.t`

**Interfaces:**
- Consumes: the `on_*` accessors (Task 2), `on_navigate` (Task 1).
- Produces: events pushed to every connected client:
  - `{"ev":"navigate","uri":...}` -- the page changed, whoever caused it
  - `{"ev":"load","uri":...,"title":...}` -- a navigation this API started finished
  - `{"ev":"console","text":...}`
  - `{"ev":"error","error":...}`
  - `{"ev":"close"}` -- the browser is going away; every client socket closes right after

- [ ] **Step 1: Write the failing test**

Create `t/86-control-events.t`. Reuse the raw-socket harness from `t/85-control.t` (copy `pump`/`send_frame`; do not factor it into `t/lib` yet -- two copies is cheaper than a premature abstraction).

The tests, in order:

```perl
# 1) the human clicks a link -- the client hears about it. This is the whole
#    reason on_navigate exists, and it is what makes a visible window observable.
@in = ();
send_frame({ i => 1, m => 'go', a => ['ev://first'] });
pump(1, 20);
@in = ();
send_frame({ i => 2, m => 'script', a => ['document.getElementById("lnk").click()'] });
pump(2, 20);                                   # the script response AND the navigate event
my ($nav) = grep { ($_->{ev} // '') eq 'navigate' } @in;
ok($nav, 'a page-initiated navigation reaches the client as an event');
is($nav->{uri}, 'ev://second', '...with the new uri');

# 2) console output is forwarded, and the browser's OWN handler still runs
#    (Control chains, it does not clobber)
@in = ();
send_frame({ i => 3, m => 'script', a => ['console.log("hello")'] });
pump(2, 20);
my ($con) = grep { ($_->{ev} // '') eq 'console' } @in;
is($con->{text}, 'log: hello', 'console output reaches the client');
ok(scalar(grep { /hello/ } @local_console), '...and the local handler given to new() still ran');

# 3) closing the browser tells clients before the socket dies
@in = ();
$b->quit;
pump(1, 5);
is($in[0]{ev}, 'close', 'quit() tells clients the browser is going');
```

- [ ] **Step 2: Run it and watch it fail** -- no events arrive at all.

- [ ] **Step 3: Implement**

In `listen`, after building `$self`, call `$self->_wire_events;`. Then:

```perl
# Chain the browser's event handlers so a client sees what it did not ask for --
# above all, the human navigating a window the client is also driving.
#
# CHAINED, never clobbered: eg/browser.pl prints console lines to its terminal
# AND the server forwards them. And weakened, both ways: the browser holds these
# closures, so a closure capturing the browser (or the server) strongly is a
# cycle Perl cannot collect. This module has shipped that bug before.
sub _wire_events {
    my $self = shift;
    my $b    = $self->{browser};
    weaken(my $ws = $self);
    weaken(my $wb = $b);

    my $prev_nav = $b->on_navigate;
    $b->on_navigate(sub {
        $prev_nav->(@_) if $prev_nav;
        my $s = $ws or return;
        $s->_broadcast(navigate => { uri => $_[0] });
    });

    my $prev_load = $b->on_load;
    $b->on_load(sub {
        $prev_load->(@_) if $prev_load;
        my ($s, $br) = ($ws, $wb);
        return unless $s && $br;
        $s->_broadcast(load => { uri => scalar eval { $br->uri }, title => scalar eval { $br->title } });
    });

    my $prev_con = $b->on_console;
    $b->on_console(sub {
        $prev_con->(@_) if $prev_con;
        my $s = $ws or return;
        $s->_broadcast(console => { text => $_[0] });
    });

    my $prev_err = $b->on_error;
    $b->on_error(sub {
        $prev_err->(@_) if $prev_err;
        my $s = $ws or return;
        $s->_broadcast(error => { error => $_[0] });
    });

    my $prev_close = $b->on_close;
    $b->on_close(sub {
        my $s = $ws;
        if ($s) { $s->_broadcast(close => {}); $s->close }
        $prev_close->(@_) if $prev_close;   # the caller's EV::break comes LAST
    });

    return;
}

sub _broadcast {
    my ($self, $ev, $data) = @_;
    $self->_send($_, { ev => $ev, %$data }) for keys %{ $self->{clients} };
    return;
}
```

**Note on `quit`:** `on_close` only fires when the USER closes the window. A client calling `quit` over the wire, or the script calling `$b->quit`, does NOT fire it. So also broadcast `close` from the `quit` dispatch path: in `_dispatch`, special-case it before the generic `%SYNC` branch:

```perl
    if ($m eq 'quit') {
        $answer->(1);                         # answer first -- the socket is about to close
        $self->_broadcast(close => {});
        eval { $b->quit };
        $self->close;
        return;
    }
```

- [ ] **Step 4: Run the test, then the full suite. Commit.**

```bash
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "Control: push events, chained rather than clobbered

A client driving a window a human is also using must hear about what it did not
ask for -- above all the human navigating. The browser's handlers are chained,
not replaced, so a script's own on_console keeps working while the server
forwards the same lines; and both directions are weakened, because the browser
holds these closures and one that captures the browser strongly is a cycle."
```

---

## Task 6: element handles

**Files:**
- Modify: `lib/EV/WebKit/Control.pm`
- Create: `t/87-control-elements.t`

**Interfaces:**
- Consumes: Tasks 4 and 5.
- Produces:
  - `find` answers `{"r":{"h":7}}` or `{"r":null}` (no match); `find_all` answers `{"r":[{"h":7},{"h":8}]}`.
  - `{"m":"el.<method>","h":7,"a":[...]}` for each of `text html value tag attr prop is_visible click focus type clear submit find find_all`.
  - `{"m":"el.release","h":7}` frees one handle.
  - A stale or unknown handle answers `{"e":"stale element"}`.

**The hazard this task exists to avoid:** every `find()` mints an `Element` that holds a reference to the browser. A server that never frees them rebuilds, in Perl, the unbounded registry growth that was just fixed on the JavaScript side -- and a `find()` poll loop against a long-lived page is the ordinary case, not an exotic one.

- [ ] **Step 1: Write the failing test**

`t/87-control-elements.t`, key assertions:

```perl
# find returns a handle, and the handle works
send_frame({ i => 1, m => 'go', a => ['el://p'] });  pump(1, 20);
@in = (); send_frame({ i => 2, m => 'find', a => ['h1'] }); pump(1);
my $h = $in[0]{r}{h};
ok(defined $h, 'find returns a handle');
@in = (); send_frame({ i => 3, m => 'el.text', h => $h }); pump(1);
is($in[0]{r}, 'hi', 'the handle reads the element');

# no match is not an error
@in = (); send_frame({ i => 4, m => 'find', a => ['#nope'] }); pump(1);
is($in[0]{r}, undef, 'no match answers null, not an error');
ok(!exists $in[0]{e}, '...and is not an error');

# handles are freed by NAVIGATION -- they are all stale anyway, and keeping them
# is how you rebuild the registry leak in Perl
@in = (); send_frame({ i => 5, m => 'find_all', a => ['p'] }); pump(1);
is(scalar @{ $in[0]{r} }, 3, 'find_all returns a handle each');
cmp_ok(scalar keys %{ $ctl->{handles} }, '>=', 4, 'the server is holding them');
@in = (); send_frame({ i => 6, m => 'go', a => ['el://other'] }); pump(1, 20);
is(scalar keys %{ $ctl->{handles} }, 0, 'navigating frees every handle');

# a stale handle answers cleanly
@in = (); send_frame({ i => 7, m => 'el.text', h => $h }); pump(1);
like($in[0]{e}, qr/stale element/, 'a handle from the previous page is stale, not a crash');

# disconnect frees that client's handles
# (open a second socket, find, close it, assert the table shrinks)
```

- [ ] **Step 2: Run it and watch it fail** (`unknown method: find`).

- [ ] **Step 3: Implement**

Add to `Control.pm`:

```perl
my %EL_METHOD = map { $_ => 1 } qw(
    text html value tag attr prop is_visible click focus type clear submit find find_all
);

# Element handles. Every find() mints an EV::WebKit::Element that holds the
# browser, so a table that is never pruned rebuilds -- in Perl -- the unbounded
# registry growth just fixed in JavaScript. Handles are freed on navigation
# (they are all stale by then: the page's epoch changed), on disconnect, and on
# an explicit el.release. That bounds the table by "handles made since the last
# navigation, by clients still connected".
sub _hold {
    my ($self, $cid, $el) = @_;
    my $h = ++$self->{next_handle};
    $self->{handles}{$h} = { el => $el, client => $cid };
    return { h => $h };
}

sub _release_handles_of {
    my ($self, $cid) = @_;
    for my $h (keys %{ $self->{handles} || {} }) {
        delete $self->{handles}{$h} if $self->{handles}{$h}{client} == $cid;
    }
    return;
}

sub _release_all_handles { $_[0]{handles} = {}; return }
```

Initialise `handles => {}, next_handle => 0` in `listen`'s `bless`. Free them on navigation, inside `_wire_events`'s `on_navigate` chain (before the broadcast):

```perl
        my $s = $ws or return;
        $s->_release_all_handles;      # every handle from the old page is stale now
        $s->_broadcast(navigate => { uri => $_[0] });
```

In `_dispatch`, before the `%SYNC` branch:

```perl
    if ($m eq 'find' || $m eq 'find_all') {
        my $wrap = sub {
            my ($r, $e) = @_;
            my $s = $wself or return;
            return $answer->(undef, $e) if defined $e;
            return $answer->(undef)                                    if !defined $r;
            return $answer->([ map { $s->_hold($id, $_) } @$r ])       if ref $r eq 'ARRAY';
            return $answer->($s->_hold($id, $r));
        };
        my $ok = eval { $b->$m(@a, $wrap); 1 };
        return $answer->(undef, _clean($@)) unless $ok;
        return;
    }

    if ($m eq 'el.release') {
        delete $self->{handles}{ $f->{h} // '' };
        return $answer->(1);
    }

    if (index($m, 'el.') == 0) {
        my $em = substr($m, 3);
        return $answer->(undef, "unknown method: $m") unless $EL_METHOD{$em};
        my $rec = $self->{handles}{ $f->{h} // '' }
            or return $answer->(undef, 'stale element');
        my $el = $rec->{el};
        my $wrap = ($em eq 'find' || $em eq 'find_all')
            ? sub {
                my ($r, $e) = @_;
                my $s = $wself or return;
                return $answer->(undef, $e) if defined $e;
                return $answer->(undef)                              if !defined $r;
                return $answer->([ map { $s->_hold($id, $_) } @$r ]) if ref $r eq 'ARRAY';
                return $answer->($s->_hold($id, $r));
              }
            : sub { $answer->(@_) };
        my $ok = eval { $el->$em(@a, $wrap); 1 };
        return $answer->(undef, _clean($@)) unless $ok;
        return;
    }
```

- [ ] **Step 4: Run the test, then the full suite. Commit.**

---

## Task 7: `EV::WebKit::Client` (blocking) and `::Client::Element`

**Files:**
- Create: `lib/EV/WebKit/Client.pm`, `lib/EV/WebKit/Client/Element.pm`
- Create: `t/88-client.t`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `EV::WebKit::Client->connect($path, %opt)` -- `%opt`: `on_event => sub { my ($ev, $data) = @_ }`.
  - Every browser method, blocking: `$c->go($uri)`, `$c->title`, `$c->script($js)`. Returns the result. **Croaks on error**, with the module's own error string -- in blocking mode there is no callback to deliver an error to, and croaking is how synchronous code reports one. `eval { }` if you want the string.
  - `$c->find($sel)` returns an `EV::WebKit::Client::Element` (or undef); `find_all` an arrayref.
  - `$c->events` drains queued events; `$c->hello` returns the greeting frame.
  - `$c->disconnect`.

- [ ] **Step 1: Write the failing test** (`t/88-client.t`): start a browser + Control in the same process, connect a blocking client, and drive it -- `go`, `title`, `script`, `find` + `->text`, a croak on a bad uri, and `$c->events` seeing a navigate event after a link click.

- [ ] **Step 2: Run it and watch it fail.**

- [ ] **Step 3: Implement.** The blocking read loop, which is the only subtle part:

```perl
# Blocking mode is plain socket I/O -- deliberately NOT a nested EV::run. A
# nested loop inside a callback is how you wedge EV::Glib, and a client has no
# business running the caller's loop anyway.
sub _call {
    my ($self, $m, $a, $o) = @_;
    my $id = ++$self->{next_id};
    $self->_write(EV::WebKit::Protocol::encode({ i => $id, m => $m, a => $a, ($o ? (o => $o) : ()) }));
    while (1) {
        for my $f ($self->_read_frames) {
            if (($f->{ev} // '') ne '') { $self->_event($f); next }   # never confuse an event with a response
            next unless ($f->{i} // -1) == $id;                       # responses can arrive OUT OF ORDER
            Carp::croak("$m: $f->{e}") if defined $f->{e};
            return $f->{r};
        }
    }
}
```

`_event` calls `on_event` if given, else pushes onto `$self->{events}`.

`EV::WebKit::Client::Element` holds `{ client => $c, h => $h }` and generates its 14 methods:

```perl
for my $m (qw(text html value tag attr prop is_visible click focus type clear submit)) {
    no strict 'refs';
    *$m = sub { my $s = shift; $s->{client}->_call("el.$m", [@_], undef, $s->{h}) };
}
```

(extend `_call` with a `$h` argument that adds `h => $h` to the frame).

- [ ] **Step 4: Run the test, then the full suite. Commit.**

---

## Task 8: `EV::WebKit::Client` in EV mode

**Files:**
- Modify: `lib/EV/WebKit/Client.pm`
- Modify: `t/88-client.t` (add an EV-mode section)

**Interfaces:**
- Produces: `EV::WebKit::Client->connect($path, ev => 1)`. Every method now takes a trailing callback and returns immediately; the callback gets `($result, $err)` -- the same shape as `EV::WebKit` itself, so code moves between local and remote with no rewriting. Calling a method with no callback in `ev => 1` mode croaks (it cannot block: the caller owns the loop).

- [ ] **Step 1: Write the failing test:** `go` with a callback, `EV::run`, assert the callback fired once with no error; a bad uri delivers `(undef, 'go: uri required')` rather than croaking; events reach `on_event` while the loop runs.

- [ ] **Step 2: Run and fail. Step 3: implement** an `EV::io` read watcher that decodes frames, matches `i` against a pending-request table, and dispatches events to `on_event`. **Step 4: run + full suite. Commit.**

---

## Task 9: robustness -- many clients, dead clients, hostile clients

**Files:**
- Create: `t/89-control-robust.t`

**No new implementation is expected.** This task's job is to prove the server behaves, and to fix it if it does not.

- [ ] **Step 1: Write the tests**

1. **Two clients at once.** Both connected; each issues `script` concurrently; both get their own answer, matched by id.
2. **Superseded navigation, reported honestly.** Client A issues `go(slow)`, client B issues `go(other)` immediately. A's response is `{"e":"superseded"}` -- the same thing two `go()` calls in one process do. Assert exactly that: the protocol reports the browser's real semantics, it does not fake exclusivity.
3. **A client killed mid-request.** Fork a child that connects, sends `go`, and `kill -9`s itself. The server must drop it, free its handles, and keep serving the other client. Assert the surviving client still gets answers and `$ctl->{handles}` is empty.
4. **A hostile client.** Send an oversized line (`MAX_LINE + 1` bytes with no newline) and garbage. The server answers the error, and the browser is still alive and serving other clients.
5. **The wedge.** Run in a CHILD under a shell `timeout`, as `t/05-wedge-ops.t` does: a client command triggers a page dialog (answered locally by the browser's own `on_dialog`), and afterwards a fresh `EV::run` in the browser process must still complete. A wedge spins rather than fails, so an in-process test would hang the suite instead of reporting.

- [ ] **Step 2: Run them.** Fix whatever breaks. **Step 3: full suite. Commit.**

---

## Task 10: `eg/browser.pl --control`, docs, Changes

**Files:**
- Modify: `eg/browser.pl`, `Changes`, `MANIFEST`, `README.md`
- Create: `eg/control.pl` (a tiny client: attach, print the title, screenshot)

- [ ] **Step 1:** Add `--control [path]` to `eg/browser.pl`:

```perl
use Getopt::Long;
my $control;
GetOptions('control:s' => \$control) or die "usage: browser.pl [--control [path]] [uri]\n";
...
if (defined $control) {
    require EV::WebKit::Control;
    $control ||= ($ENV{XDG_RUNTIME_DIR} || '/tmp') . "/ev-webkit-$$.sock";
    my $ctl = EV::WebKit::Control->listen($b, path => $control);
    say "[ctl  ] listening on $control";
}
```

- [ ] **Step 2:** Write `eg/control.pl`:

```perl
use v5.10; use strict; use warnings;
use EV::WebKit::Client;
my $path = shift or die "usage: control.pl <socket> [uri]\n";
my $uri  = shift;
my $c = EV::WebKit::Client->connect($path);
say "attached: ", ($c->hello->{uri} // '(nothing loaded)');
$c->go($uri) if $uri;
say "title: ", ($c->title // '(none)');
my $el = $c->find('h1');
say "h1: ", $el->text if $el;
```

- [ ] **Step 3:** Verify by hand, on a real display, because that is the whole point of the feature:

```bash
perl -Ilib eg/browser.pl --control /tmp/evwk.sock https://example.com &
perl -Ilib eg/control.pl /tmp/evwk.sock https://perl.org
# the visible window must navigate, and control.pl must print perl.org's title
```

- [ ] **Step 4:** Add a `Changes` entry and a `README.md` section. Run `make manifest`. Full suite. Commit.

---

## Self-Review

**Spec coverage.** Every section of the design maps to a task: shape and wire -> 3, 4; events with local decisions -> 5; element handles and their lifetime -> 6; blocking and EV clients -> 7, 8; concurrency reported honestly -> 9 (test 2); errors -> 4 (the `_clean`/`answer` path) and 9 (test 4); security -> 4 (`listen`'s directory and stale-socket checks, tested in `t/85`); `on_navigate` -> 1; testing -> the test file per task; "not in v1" -> nothing implements TCP, tokens, pools, or locking.

**Two things the spec left implicit, now explicit in the plan.** `MAX_LINE` (Task 3): a client that opens a socket and never sends a newline would otherwise buffer without bound. And **buffered writes** (Task 4): a stalled client must not be able to block the browser, so anything the socket will not take waits in `{out}` behind a write watcher.

**One thing the spec got wrong, now corrected in Task 5.** The design says `on_close` covers the browser going away. It does not: `on_close` fires only when the *user* closes the window. A client calling `quit` over the wire, or the script calling `$b->quit`, does not fire it -- so the `close` event is broadcast from the `quit` dispatch path as well.

**Type consistency.** `_hold` returns `{ h => $n }` in Task 6, and Task 7's client reads `$f->{r}{h}` -- consistent. `_call($m, $a, $o, $h)` in Task 7 is the same signature the Element proxy uses. Handler accessor names in Task 2 (`on_navigate`) match Task 1's constructor key and Task 5's chaining.

**Order dependency.** Tasks 1 and 2 must land before 5 (which chains handlers that do not otherwise exist), and 3 before 4. Everything else is sequential anyway.
