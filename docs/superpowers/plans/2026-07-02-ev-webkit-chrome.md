# EV::WebKit Chrome Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A built-in minimalistic browser chrome (`chrome => 1`: GNOME HeaderBar with back/forward/reload + address bar) plus the public navigation API that drives it (`back`/`forward`/`reload`/`stop`/`can_go_back`/`can_go_forward`).

**Architecture:** Two additive changes to `lib/EV/WebKit.pm`. (1) Thin navigation wrappers over the WebView's `go_back`/`go_forward`/`reload`/`stop_loading`, reusing the existing `_start_nav`/`_finish_nav` machinery so `back($cb)` behaves exactly like `go($uri,$cb)`. (2) A `_build_chrome` helper (HeaderBar + buttons + address entry, installed as the window titlebar BEFORE `present`) with a chrome-only `load-changed` updater that refreshes widget state, deferring one extra refresh past the known title-propagation race.

**Tech Stack:** Perl 5.10+, EV + EV::Glib, WebKitGTK 6.0 / GTK4 via Glib::Object::Introspection. Branch: `chrome` (already created; execution happens there).

## Global Constraints

- Perl floor: `use v5.10;`. Pure Perl, NO XS.
- Callback convention: `$cb->($result, $err)`; user callbacks from GLib dispatch frames go through `$self->_defer` (never fire synchronously from a dispatch frame); teardown-guarded (`browser closed` after `quit`).
- Bring-your-own-display: ALL browser tests run under `xvfb-run -a`, bounded with `timeout` (e.g. `timeout 90 xvfb-run -a perl -Ilib t/XX.t`). Tests must PASS and EXIT 0.
- Author `vividsnow` only. NO Co-Authored-By / Generated-with / Claude/AI/LLM mention in commits. If git author isn't vividsnow: `git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit ...`.
- POD: plain ASCII (no em-dash, no unicode).
- Work from `/home/yk/dev/perl-modules/EV-WebKit` on branch `chrome`; do not switch branches.

### Spike-verified facts (2026-07-02, on this host -- use these EXACT calls)

```perl
# GTK4 chrome widgets (all verified under xvfb):
my $hb = Gtk4::HeaderBar->new;
$win->set_titlebar($hb);                  # MUST be called BEFORE $win->present
                                          # (GTK warns "called on a realized window" after)
my $btn = Gtk4::Button->new_from_icon_name('go-previous-symbolic');
$btn->set_icon_name('process-stop-symbolic');   # and get_icon_name round-trips
$btn->set_sensitive(0);  $btn->get_sensitive;   # boolean state readable
$btn->set_tooltip_text('Back');
$hb->pack_start($btn);
my $entry = Gtk4::Entry->new;
$entry->set_hexpand(1);
$hb->set_title_widget($entry);            # centered address bar
$entry->set_text('x');  $entry->get_text; # round-trips
$entry->has_focus;                        # false when unfocused (headless: always false)
$entry->signal_connect(activate => sub {...});   # Enter key

# WebView navigation (all present and working):
$view->go_back; $view->go_forward; $view->reload; $view->stop_loading;
$view->can_go_back; $view->can_go_forward;

# History: load_html does NOT create back-forward entries. Real navigations DO:
# mock_scheme('mock', ...) + go('mock://one') + go('mock://two') =>
#   can_go_back true; go_back lands on mock://one AND fires load-changed
#   'finished' (so _start_nav-based callbacks resolve); can_go_forward true after.
# Title/uri propagate ~0.1ms AFTER load-changed 'finished' (existing NAV_SETTLE_DELAY
# race) -- chrome must re-refresh once after that delay.
```

---

### Task 1: Navigation API (back/forward/reload/stop/can_go_back/can_go_forward)

**Files:**
- Modify: `lib/EV/WebKit.pm` (add six methods after the existing `sub load_html`; extend POD)
- Create: `t/64-nav.t`

**Interfaces:**
- Consumes (already in `lib/EV/WebKit.pm`): `$self->_start_nav($cb)` (registers pending nav + timeout; `$cb` may be undef -- `_finish_nav` guards every `$cb->` with `if $cb`), `$self->_defer($cb, @args)` (bounces a callback to a clean EV tick; no-ops when `_dead`), `$self->{view}`, `$self->{_dead}`, `$self->mock_scheme` (t/73 pattern), `TWK::skip_unless_available` / `TWK::run_with_timeout`.
- Produces (Task 2 relies on these exact names): `$b->back($cb?)`, `$b->forward($cb?)`, `$b->reload($cb?)` -- optional callback resolves on load finish like `go`; `$b->stop` -- fire-and-forget, returns `$self`; `$b->can_go_back` / `$b->can_go_forward` -- synchronous 1/0.

- [ ] **Step 1: Write the failing test** -- `t/64-nav.t`

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

my $b = EV::WebKit->new(window=>[300,200]);
$b->mock_scheme('mock', sub {
    my ($uri) = @_;
    my ($n) = $uri =~ m{mock://(\w+)};
    return ("<html><head><title>$n</title></head><body>$n</body></html>", 'text/html');
});

ok(!$b->can_go_back,    'fresh: cannot go back');
ok(!$b->can_go_forward, 'fresh: cannot go forward');
is($b->stop, $b, 'stop is callable and returns self');

my %g;
$b->back(sub {                                # nothing to go back to -> error, not a hang
    $g{noback_err} = $_[1];
    $b->go('mock://one', sub {
        $b->go('mock://two', sub {
            $g{cgb_after_two} = $b->can_go_back;
            $g{cgf_after_two} = $b->can_go_forward;
            $b->back(sub {
                my (undef, $err) = @_;
                $g{back_err}       = $err;
                $g{uri_after_back} = $b->uri;
                $g{cgf_after_back} = $b->can_go_forward;
                $b->forward(sub {
                    $g{uri_after_forward} = $b->uri;
                    $b->reload(sub {
                        my (undef, $rerr) = @_;
                        $g{reload_err}       = $rerr;
                        $g{uri_after_reload} = $b->uri;
                        EV::break;
                    });
                });
            });
        });
    });
});
TWK::run_with_timeout(25);
is($g{noback_err}, 'cannot go back', 'back with empty history -> error');
ok($g{cgb_after_two},  'can_go_back after two navigations');
ok(!$g{cgf_after_two}, 'cannot go forward at newest entry');
is($g{back_err}, undef, 'back resolved without error');
is($g{uri_after_back}, 'mock://one', 'back landed on first page');
ok($g{cgf_after_back}, 'can_go_forward true after going back');
is($g{uri_after_forward}, 'mock://two', 'forward landed on second page');
is($g{reload_err}, undef, 'reload resolved without error');
is($g{uri_after_reload}, 'mock://two', 'reload stays on second page');
done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 90 xvfb-run -a perl -Ilib t/64-nav.t`
Expected: FAIL -- `Can't locate object method "can_go_back" via package "EV::WebKit"`.

- [ ] **Step 3: Write minimal implementation** -- add to `lib/EV/WebKit.pm` immediately after `sub load_html`

```perl
sub _history_nav {
    my ($self, $can_method, $go_method, $errmsg, $cb) = @_;
    if ($self->{_dead} || !$self->{view}) { $cb->(undef, 'browser closed') if $cb; return $self }
    unless ($self->{view}->$can_method) {
        # normal runtime condition (empty history side) -- deliver async, on a clean tick
        $self->_defer($cb, undef, $errmsg) if $cb;
        return $self;
    }
    $self->_start_nav($cb);          # cb may be undef; resolves on load finish like go()
    $self->{view}->$go_method;
    return $self;
}

sub back    { my ($s,$cb)=@_; $s->_history_nav('can_go_back',    'go_back',    'cannot go back',    $cb) }
sub forward { my ($s,$cb)=@_; $s->_history_nav('can_go_forward', 'go_forward', 'cannot go forward', $cb) }

sub reload {
    my ($self, $cb) = @_;
    if ($self->{_dead} || !$self->{view}) { $cb->(undef, 'browser closed') if $cb; return $self }
    $self->_start_nav($cb);
    $self->{view}->reload;
    return $self;
}

sub stop {
    my ($self) = @_;
    return $self if $self->{_dead} || !$self->{view};
    $self->{view}->stop_loading;
    return $self;
}

sub can_go_back    { my $s=$_[0]; ($s->{_dead} || !$s->{view}) ? 0 : ($s->{view}->can_go_back    ? 1 : 0) }
sub can_go_forward { my $s=$_[0]; ($s->{_dead} || !$s->{view}) ? 0 : ($s->{view}->can_go_forward ? 1 : 0) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `timeout 90 xvfb-run -a perl -Ilib t/64-nav.t`
Expected: PASS, 12 assertions, exit 0.

- [ ] **Step 5: Add POD** -- in `lib/EV/WebKit.pm`'s POD, in the Navigation methods section (after the `load_html` entry), add:

```pod
=head2 Navigation history

    $b->back(sub { my ($ok, $err) = @_; ... });     # optional callback
    $b->forward($cb);
    $b->reload($cb);
    $b->stop;
    $b->can_go_back;      # 1 or 0
    $b->can_go_forward;   # 1 or 0

back, forward and reload behave like go: the optional trailing callback is
invoked as ($ok, $err) when the resulting navigation finishes (or fails or
times out). Calling back/forward when the history has no entry in that
direction invokes the callback with the error 'cannot go back' /
'cannot go forward'. stop aborts the current load and returns the browser
object; it takes no callback. can_go_back / can_go_forward are synchronous
and return 1 or 0.

Note: load_html does not add entries to the back-forward list; only real
navigations (go, links, redirects) do.
```

Verify POD stays ASCII-clean: `grep -nP '[^\x00-\x7F]' lib/EV/WebKit.pm` returns nothing; `podchecker lib/EV/WebKit.pm` clean.

- [ ] **Step 6: Full-suite regression check**

Run: `timeout 400 xvfb-run -a prove -Ilib t/`
Expected: all files pass (22 files now), exit 0.

- [ ] **Step 7: Commit**

```bash
git add lib/EV/WebKit.pm t/64-nav.t
git commit -m 'feat: navigation API (back/forward/reload/stop/can_go_back/can_go_forward)'
```

---

### Task 2: Chrome mode (`chrome => 1`)

**Files:**
- Modify: `lib/EV/WebKit.pm` (`new` gains the `chrome` option + `_build_chrome` call; add `_build_chrome`/`_update_chrome`/`_refresh_chrome`; `quit` cleans up the chrome settle timer; POD + Changes)
- Modify: `Changes`
- Create: `t/80-chrome.t`

**Interfaces:**
- Consumes: Task 1's `$self->back`/`forward`/`reload`/`stop`/`can_go_back`/`can_go_forward`; existing `$self->go($url)` (cb optional), `$self->uri`, `$self->title`, `NAV_SETTLE_DELAY` constant, `$self->{win}`, `$self->{view}`, `$self->{_dead}`, `$self->mock_scheme`.
- Produces: `EV::WebKit->new(chrome => 1, ...)`; `$self->{chrome}` hash with keys `hb` (Gtk4::HeaderBar), `entry` (Gtk4::Entry), `back`/`forward`/`reload` (Gtk4::Button), `loading` (0/1), `settle` (EV timer or undef). Tests may read widget state through it.

- [ ] **Step 1: Write the failing test** -- `t/80-chrome.t`

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

my $b = EV::WebKit->new(window=>[400,300], chrome => 1);
my $c = $b->{chrome};
ok($c, 'chrome hash present');
isa_ok($c->{$_}, 'Gtk4::Button', "chrome '$_' button") for qw/back forward reload/;
isa_ok($c->{entry}, 'Gtk4::Entry', 'address entry');
ok(!$c->{back}->get_sensitive,    'back button starts insensitive');
ok(!$c->{forward}->get_sensitive, 'forward button starts insensitive');

$b->mock_scheme('mock', sub {
    my ($uri) = @_;
    my ($n) = $uri =~ m{mock://(\w+)};
    return ("<html><head><title>$n</title></head><body>$n</body></html>", 'text/html');
});

my %g;
my $t;
$b->go('mock://one', sub {
    $b->go('mock://two', sub {
        # give the chrome's own settle refresh (NAV_SETTLE_DELAY after 'finished')
        # time to land before sampling widget state
        $t = EV::timer(0.05, 0, sub {
            undef $t;
            $g{entry}          = $c->{entry}->get_text;
            $g{title}          = $b->{win}->get_title;
            $g{back_sensitive} = $c->{back}->get_sensitive;
            $g{fwd_sensitive}  = $c->{forward}->get_sensitive;
            $g{reload_icon}    = $c->{reload}->get_icon_name;
            EV::break;
        });
    });
});
TWK::run_with_timeout(20);
is($g{entry}, 'mock://two', 'address entry tracks current uri');
is($g{title}, 'two', 'window title tracks page title');
ok($g{back_sensitive}, 'back button sensitive after two navigations');
ok(!$g{fwd_sensitive}, 'forward button insensitive at newest entry');
is($g{reload_icon}, 'view-refresh-symbolic', 'reload icon restored after load');
$b->quit;
pass('quit with chrome does not crash');
done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 90 xvfb-run -a perl -Ilib t/80-chrome.t`
Expected: FAIL -- `ok($c, ...)` fails (`$b->{chrome}` undef; the `isa_ok` calls fail on undef).

- [ ] **Step 3: Write minimal implementation**

(a) In `sub new` in `lib/EV/WebKit.pm`, the window block currently reads:

```perl
    my $win = $self->{win} = Gtk4::Window->new;
    $win->set_default_size($w, $h);
    $win->set_child($view);
    $win->set_title($o{title}) if defined $o{title};
    $win->present;
```

Insert the chrome build between `set_title` and `present` (the titlebar MUST be installed before the window is realized):

```perl
    my $win = $self->{win} = Gtk4::Window->new;
    $win->set_default_size($w, $h);
    $win->set_child($view);
    $win->set_title($o{title}) if defined $o{title};
    $self->_build_chrome if $o{chrome};   # titlebar must precede present (realized-window warning)
    $win->present;
```

(b) Add the three subs (place them right after `sub _install_boot`):

```perl
# chrome => 1: minimal browser chrome -- a GNOME HeaderBar titlebar with
# back/forward/reload buttons and an address entry. Orthogonal to automation:
# the WebView is unchanged and stays fully scriptable.
sub _build_chrome {
    my ($self) = @_;
    my $hb = Gtk4::HeaderBar->new;
    my %btn;
    for (['back',    'go-previous-symbolic',  'Back'],
         ['forward', 'go-next-symbolic',      'Forward'],
         ['reload',  'view-refresh-symbolic', 'Reload']) {
        my ($k, $icon, $tip) = @$_;
        $btn{$k} = Gtk4::Button->new_from_icon_name($icon);
        $btn{$k}->set_tooltip_text($tip);
        $hb->pack_start($btn{$k});
    }
    my $entry = Gtk4::Entry->new;
    $entry->set_hexpand(1);
    $hb->set_title_widget($entry);
    $self->{win}->set_titlebar($hb);
    my $c = $self->{chrome} = { hb => $hb, entry => $entry, %btn, loading => 0, settle => undef };
    $btn{back}->set_sensitive(0);
    $btn{forward}->set_sensitive(0);

    $entry->signal_connect(activate => sub {
        my $url = $entry->get_text;
        return unless defined $url && length $url;
        $url = "https://$url" unless $url =~ m{^[a-z][a-z0-9+.-]*://}i;
        $self->go($url);
    });
    $btn{back}->signal_connect(clicked    => sub { $self->back });
    $btn{forward}->signal_connect(clicked => sub { $self->forward });
    $btn{reload}->signal_connect(clicked  => sub { $c->{loading} ? $self->stop : $self->reload });

    # chrome-only updater; the core nav handler is connected separately in new()
    $self->{view}->signal_connect('load-changed' => sub {
        my (undef, $ev) = @_;
        $self->_update_chrome($ev);
    });
    return;
}

sub _update_chrome {
    my ($self, $ev) = @_;
    my $c = $self->{chrome} or return;
    if ($ev eq 'started') {
        $c->{loading} = 1;
        $c->{reload}->set_icon_name('process-stop-symbolic');
    }
    elsif ($ev eq 'finished') {
        $c->{loading} = 0;
        $c->{reload}->set_icon_name('view-refresh-symbolic');
        # title/uri propagate from the web process shortly after 'finished'
        # (the NAV_SETTLE_DELAY race) -- refresh once more after that window.
        $c->{settle} = EV::timer(NAV_SETTLE_DELAY, 0, sub {
            $c->{settle} = undef;
            $self->_refresh_chrome;
        });
    }
    $self->_refresh_chrome;
}

sub _refresh_chrome {
    my ($self) = @_;
    return if $self->{_dead} || !$self->{view};
    my $c = $self->{chrome} or return;
    my $uri = $self->uri;
    $c->{entry}->set_text($uri // '') unless $c->{entry}->has_focus;  # never clobber typing
    my $title = $self->title;
    $self->{win}->set_title($title) if defined $title && length $title;
    $c->{back}->set_sensitive($self->can_go_back);
    $c->{forward}->set_sensitive($self->can_go_forward);
    return;
}
```

(c) In `sub quit`, next to the `_settle` cancellation line, add chrome-settle cleanup, and add `chrome` to the teardown delete list. The relevant lines currently read:

```perl
    if ($self->{_settle}) { $self->{_settle}->stop; $self->{_settle} = undef }
    ...
    delete @{$self}{qw/view win ucm session context/};
```

Change to:

```perl
    if ($self->{_settle}) { $self->{_settle}->stop; $self->{_settle} = undef }
    if ($self->{chrome} && $self->{chrome}{settle}) { $self->{chrome}{settle}->stop; $self->{chrome}{settle} = undef }
    ...
    delete @{$self}{qw/view win ucm session context chrome/};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `timeout 90 xvfb-run -a perl -Ilib t/80-chrome.t`
Expected: PASS, 13 assertions, exit 0.

- [ ] **Step 5: Add POD + Changes**

POD -- in the constructor options list in `lib/EV/WebKit.pm`, add (keep ASCII):

```pod
=item chrome => 1

Build a minimal browser chrome: a GNOME header bar with back, forward and
reload buttons and an address entry, installed as the window title bar.
Intended for visible use on a real display; harmless under xvfb-run. The
reload button turns into a stop button while a page is loading. The address
entry navigates on Enter (https:// is assumed when no scheme is given) and
tracks the current page uri except while it has keyboard focus. The window
title follows the page title. Automation methods keep working unchanged.
```

Changes -- add two lines under the 0.01 entry (still unreleased/not uploaded):

```
        - navigation API: back/forward/reload/stop/can_go_back/can_go_forward
        - chrome => 1: minimal browser chrome (header bar + address entry)
```

Verify: `podchecker lib/EV/WebKit.pm` clean; `grep -nP '[^\x00-\x7F]' lib/EV/WebKit.pm` empty.

- [ ] **Step 6: Full-suite regression check**

Run: `timeout 400 xvfb-run -a prove -Ilib t/`
Expected: all files pass (23 files now), exit 0.

- [ ] **Step 7: Commit**

```bash
git add lib/EV/WebKit.pm t/80-chrome.t Changes
git commit -m 'feat: chrome => 1 minimal browser chrome (HeaderBar + address bar)'
```

---

## Self-Review notes (addressed)

- **Spec coverage:** nav API (T1), chrome construction + wiring + reload/stop toggle + focus-guarded entry + title/sensitivity updates (T2), quit cleanup (T2c), POD (T1 S5, T2 S5), tests incl. widget-state assertions (T1 S1, T2 S1). The spec's "to-verify" items are resolved in the spike-verified section (titlebar-before-present; icon buttons; nav methods; has_focus; mock-scheme history).
- **Type consistency:** `$self->{chrome}` keys (`hb`/`entry`/`back`/`forward`/`reload`/`loading`/`settle`) match between T2's implementation and test; T1's method names match T2's consumers.
- **Known accepted behaviors:** chrome's `load-changed` handler is a second connection (runs before the core one -- connection order); `finished` also follows `load-failed` in WebKitGTK, so the loading state always clears without a separate `load-failed` hook; button clicks are not simulated headlessly -- navigation is driven via methods and widget STATE is asserted (per spec).
