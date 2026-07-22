# EV::WebKit User-Content Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a public API to inject caller-supplied JavaScript and CSS into pages, per instance, at document-start/end, in the main or an isolated world, optionally scoped by URL-pattern globs -- the primitive that fingerprint-spoofing and uBlock cosmetic-filtering will build on.

**Architecture:** Four thin public methods (`add_user_script`, `add_user_style`, `remove_all_user_scripts`, `remove_all_user_styles`) funnel through one private builder `_add_user_content` that validates options, maps friendly option strings to WebKit's GI enum nicks, constructs the native `WebKit::UserScript`/`WebKit::UserStyleSheet`, adds it to the existing per-instance `WebKit::UserContentManager` (`$self->{ucm}`), records the native in a per-instance registry (`$self->{_user_scripts}` / `$self->{_user_styles}`), and returns a small blessed handle (`EV::WebKit::UserContent`) that removes just that item. `remove_all_user_*` loops per-item `remove_script`/`remove_style_sheet` over only the caller's registry -- it never calls WebKit's `remove_all_scripts`, which would also wipe the module's own BOOT injection and break `find()`.

**Tech Stack:** Perl 5.10+, Glib::Object::Introspection over WebKitGTK 6.0 (GTK4), EV event loop. Pure Perl, no XS. Tests run under `xvfb-run -a` against `mock_scheme` pages.

## Global Constraints

- Every test file begins `use v5.10; use strict; use warnings;` then `use lib 't/lib'; use TWK; TWK::skip_unless_available();` then `use EV; use EV::WebKit;` -- copy the preamble from any existing `t/*.t`.
- Run tests with `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/<file>.t` (a real X display is unavailable; `$PWD/.tmp` keeps temp files off the full `/tmp`).
- Commit author is `vividsnow` with no name/email leakage and no LLM attribution: `git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "..."`. No `Co-Authored-By`.
- POD is plain ASCII: no unicode, no em-dash -- use `--`. (`t/90-pod.t` checks POD syntax validity.)
- NEVER call `$ucm->remove_all_scripts` or `$ucm->remove_all_style_sheets`: they wipe the module's own injected BOOT (`$EVWK_WORLD` registry that `find`/`find_all`/`html`/`wait_for`/element accessors need) and console proxy. Remove per-item only.
- NEVER redefine a Glib::Object::Introspection-generated method (it recurses -> OOM -> kills the session).
- The isolated user world is the string `EVWebKitUser` -- DISTINCT from the module's private `$EVWK_WORLD` (`EVWebKit`). A user script must never share the module's registry world.
- Work on the current `user-scripts` branch (already created off master; the spec is committed there).

### Verified facts (already spiked -- do not re-derive)

- WebKit enum nicks accepted by the constructors: frames `all-frames`/`top-frame`; injection time `start`/`end`; style level `author`/`user`. The friendly `all`/`top` are hard-REJECTED, so `frames` must be renamed; the others pass through.
- `WebKit::UserScript->new($src, $frames_nick, $at_nick, $allow, $deny)` and `->new_for_world($src, $frames_nick, $at_nick, $world, $allow, $deny)`; `WebKit::UserStyleSheet->new($css, $frames_nick, $level_nick, $allow, $deny)`. `$allow`/`$deny` are `undef` or a Perl arrayref of pattern strings (marshals to GStrv).
- URL-pattern globs need a path component: `scheme://host/*` matches a page loaded at `scheme://host/path`; `scheme://*` never matches; an http pattern on a custom scheme simply does not match (no throw). Deny beats allow.
- `$ucm` has all six methods: `add_script`, `remove_script`, `remove_all_scripts`, `add_style_sheet`, `remove_style_sheet`, `remove_all_style_sheets`.
- A document-START script runs before the page's own scripts, but `document.body` is null then; a script that touches the DOM must inject at `end` (this is why `end` is the default).
- An isolated-world script's `window` global is invisible to the page/main world, but it shares the DOM. `script()`/`script_async()` run in the main world; `find`/`html` use the module's isolated `EVWebKit` world.

---

## Task 1: Script injection core (add_user_script + handle + builder)

**Files:**
- Modify: `lib/EV/WebKit.pm` -- add `$USER_WORLD` + option maps near `my $EVWK_WORLD = 'EVWebKit';` (line ~105); add `add_user_script`/`_add_user_content` after `_install_console` (ends line ~630); add the `EV::WebKit::UserContent` package after `sub DESTROY` (line ~2176).
- Test: `t/94-user-scripts.t` (create)

**Interfaces:**
- Consumes: `$self->{ucm}` (a live `WebKit::UserContentManager`, created in `new` at line 270); `$self->{_dead}` (teardown flag); `Carp::croak` (already `use Carp ()` at line 11); `$EVWK_WORLD` (line 105).
- Produces:
  - `$self->add_user_script($source, %opt)` -> `EV::WebKit::UserContent` handle. `%opt`: `at` `'start'|'end'` (default `end`), `world` `'main'|'isolated'` (default `main`), `frames` `'all'|'top'` (default `all`). (`allow`/`deny` accepted by the builder but validated + tested in Task 3.)
  - `EV::WebKit::UserContent->_new($browser, $id, $kind)` -> handle; `$handle->remove` removes just that item (exercised in Task 2).
  - Private `$self->_add_user_content($kind, $source, %opt)` where `$kind` is `'script'` or `'style'`.
  - Registry: `$self->{_user_scripts}` / `$self->{_user_styles}` = `{ $id => $native }`; monotonic `$self->{_user_seq}`.

- [ ] **Step 1: Write the failing test**

Create `t/94-user-scripts.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

# main-world script at document-start runs BEFORE the page's own inline script
# and its global is visible to the main world (and to script()).
{
    my $b = EV::WebKit->new(window => [200,150]);
    # the page's inline script records whether our injected global existed yet.
    $b->mock_scheme('us', sub {
        ('<html><head><script>window.__saw = (typeof window.__injected)</script></head><body>x</body></html>',
         'text/html');
    });
    my $h = $b->add_user_script('window.__injected = 42;', at => 'start', world => 'main');
    isa_ok($h, 'EV::WebKit::UserContent', 'add_user_script returns a handle');
    my %g;
    $b->go('us://host/p', sub {
        $b->script('return window.__injected', sub {
            $g{val} = $_[0];
            $b->script('return window.__saw', sub { $g{saw} = $_[0]; EV::break });
        });
    });
    TWK::run_with_timeout(15);
    is($g{val}, 42,        'main-world user script global visible to script()');
    is($g{saw}, 'number',  'document-start injection ran before the page inline script');
    $b->quit;
}

# isolated-world script (at document-end so document.body exists): its window
# global is INVISIBLE to the main world, but it shares the DOM.
{
    my $b = EV::WebKit->new(window => [200,150]);
    $b->mock_scheme('iso', sub { ('<html><body>iso</body></html>','text/html') });
    $b->add_user_script(
        'window.__iso = 1; document.body && document.body.setAttribute("data-iso","yes");',
        at => 'end', world => 'isolated');
    my %g;
    $b->go('iso://host/p', sub {
        $b->script('return window.__iso || null', sub {           # main world
            $g{global} = $_[0];
            $b->script('return document.body.getAttribute("data-iso")', sub {
                $g{dom} = $_[0]; EV::break;
            });
        });
    });
    TWK::run_with_timeout(15);
    is($g{global}, undef, 'isolated-world global is NOT visible to the main world');
    is($g{dom},    'yes', 'isolated-world script ran and shares the DOM');
    $b->quit;
}

# validation: bad option values and a missing source croak.
{
    my $b = EV::WebKit->new(window => [200,150]);
    eval { $b->add_user_script(undef) };
    like($@, qr/source is required/,          'undef source croaks');
    eval { $b->add_user_script('x', at => 'whenever') };
    like($@, qr/at => 'whenever' is invalid/, 'bad at croaks');
    eval { $b->add_user_script('x', world => 'parallel') };
    like($@, qr/world => 'parallel' is invalid/, 'bad world croaks');
    eval { $b->add_user_script('x', frames => 'some') };
    like($@, qr/frames => 'some' is invalid/, 'bad frames croaks');
    $b->quit;
}

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/94-user-scripts.t`
Expected: FAIL -- `Can't locate object method "add_user_script" via package "EV::WebKit"`.

- [ ] **Step 3: Add the world constant and option maps**

In `lib/EV/WebKit.pm`, immediately AFTER `my $EVWK_WORLD = 'EVWebKit';` (line ~105), add:

```perl
# A dedicated world for user scripts requested with world => 'isolated'. It is
# DELIBERATELY distinct from $EVWK_WORLD: a caller's isolated script must not be
# able to read or corrupt the module's own element registry.
my $USER_WORLD = 'EVWebKitUser';

# Friendly option value -> WebKit GObject-Introspection enum nick. Only `frames`
# actually renames; the rest pass through but are still validated so a typo
# croaks here instead of reaching WebKit as a bad nick.
my %USER_FRAMES = (all => 'all-frames', top => 'top-frame');
my %USER_AT     = (start => 'start', end => 'end');
my %USER_LEVEL  = (author => 'author', user => 'user');
my %USER_WORLD_OK = (main => 1, isolated => 1);
```

- [ ] **Step 4: Add the public method and the builder**

In `lib/EV/WebKit.pm`, immediately AFTER the `_install_console` sub closes (the line `}` following `return;` at line ~630) and BEFORE the `# Get/set accessors` comment (line ~632), add:

```perl
# Inject caller-supplied JavaScript. Returns an EV::WebKit::UserContent handle
# whose ->remove takes just this script out. Options: at 'start'|'end' (default
# end -- the DOM exists), world 'main'|'isolated' (default main), frames
# 'all'|'top' (default all), allow/deny arrayrefs of URL-pattern globs. Takes
# effect from the NEXT navigation (WebKit injects user content at load time).
sub add_user_script { my ($self, $source, %opt) = @_; $self->_add_user_content('script', $source, %opt) }

# Inject caller-supplied CSS. Like add_user_script but for stylesheets: no world
# (WebKit user stylesheets have none); adds a level 'author'|'user' (default
# author; 'user' beats page CSS -- use it to hide elements).
sub add_user_style  { my ($self, $source, %opt) = @_; $self->_add_user_content('style',  $source, %opt) }

sub _add_user_content {
    my ($self, $kind, $source, %opt) = @_;
    Carp::croak("add_user_$kind: source is required") unless defined $source;
    Carp::croak("add_user_$kind: browser closed") if $self->{_dead} || !$self->{ucm};

    my $frames = $USER_FRAMES{ $opt{frames} // 'all' }
        // Carp::croak("add_user_$kind: frames => '$opt{frames}' is invalid (use 'all' or 'top')");

    # allow/deny pass straight to WebKit as URL-pattern globs -- validate shape.
    for my $k (qw/allow deny/) {
        next unless defined $opt{$k};
        Carp::croak("add_user_$kind: $k => ... must be an arrayref of URL-pattern strings")
            unless ref $opt{$k} eq 'ARRAY';
        ref $_ and Carp::croak("add_user_$kind: $k entries must be strings") for @{ $opt{$k} };
    }
    my ($allow, $deny) = @opt{qw/allow deny/};

    my $native;
    if ($kind eq 'script') {
        my $at = $USER_AT{ $opt{at} // 'end' }
            // Carp::croak("add_user_script: at => '$opt{at}' is invalid (use 'start' or 'end')");
        my $world = $opt{world} // 'main';
        Carp::croak("add_user_script: world => '$world' is invalid (use 'main' or 'isolated')")
            unless $USER_WORLD_OK{$world};
        $native = $world eq 'isolated'
            ? WebKit::UserScript->new_for_world($source, $frames, $at, $USER_WORLD, $allow, $deny)
            : WebKit::UserScript->new($source, $frames, $at, $allow, $deny);
        $self->{ucm}->add_script($native);
    }
    else {   # style
        my $level = $USER_LEVEL{ $opt{level} // 'author' }
            // Carp::croak("add_user_style: level => '$opt{level}' is invalid (use 'author' or 'user')");
        $native = WebKit::UserStyleSheet->new($source, $frames, $level, $allow, $deny);
        $self->{ucm}->add_style_sheet($native);
    }

    my $id = ++$self->{_user_seq};
    $self->{"_user_${kind}s"}{$id} = $native;
    return EV::WebKit::UserContent->_new($self, $id, $kind);
}
```

- [ ] **Step 5: Add the handle package**

In `lib/EV/WebKit.pm`, immediately AFTER `sub DESTROY { my $self = shift; $self->{_destroying} = 1; eval { $self->quit } }` (line ~2176) and BEFORE `{ package EV::WebKit::Dialog;` (line ~2178), add:

```perl
{
    package EV::WebKit::UserContent;
    # Handle for one injected user script or stylesheet. Holds a WEAK ref to the
    # browser (so a dangling handle never keeps the instance alive) plus the id
    # of its native in the browser's per-kind registry. remove() is idempotent:
    # the shared registry is the single source of truth, so an item removed
    # individually OR by remove_all_user_* (which clears the registry) makes
    # every later remove() on it a clean no-op.
    sub _new {
        my ($class, $browser, $id, $kind) = @_;
        my $self = bless { id => $id, kind => $kind }, $class;
        Scalar::Util::weaken($self->{browser} = $browser);
        return $self;
    }
    sub remove {
        my $self = shift;
        my $b = $self->{browser} or return $self;       # browser already collected
        return $self if $b->{_dead} || !$b->{ucm};      # torn down: registry gone with the ucm
        my $reg = $b->{"_user_$self->{kind}s"} or return $self;
        my $native = delete $reg->{ $self->{id} } or return $self;   # already removed
        my $m = $self->{kind} eq 'style' ? 'remove_style_sheet' : 'remove_script';
        $b->{ucm}->$m($native);
        return $self;
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/94-user-scripts.t`
Expected: PASS -- 9 assertions (isa_ok + val + saw + global + dom + four validation `like`s).

- [ ] **Step 7: Commit**

```bash
git add lib/EV/WebKit.pm t/94-user-scripts.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "user-content: add_user_script (main/isolated world, at, frames) + handle"
```

---

## Task 2: Removal (handle->remove, remove_all_user_scripts, clobber guard)

**Files:**
- Modify: `lib/EV/WebKit.pm` -- add `remove_all_user_scripts`/`remove_all_user_styles`/`_remove_all_user` right after `_add_user_content`.
- Test: `t/95-user-remove.t` (create)

**Interfaces:**
- Consumes: `$self->{_user_scripts}`/`$self->{_user_styles}` registries and the `EV::WebKit::UserContent` handle from Task 1; `$self->{ucm}`.
- Produces: `$self->remove_all_user_scripts` and `$self->remove_all_user_styles` (chainable, return `$self`); private `$self->_remove_all_user($kind)`.

- [ ] **Step 1: Write the failing test**

Create `t/95-user-remove.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

# handle->remove stops injection from the NEXT navigation; a second remove()
# is a harmless no-op.
{
    my $b = EV::WebKit->new(window => [200,150]);
    $b->mock_scheme('rem', sub { ('<html><body>rem</body></html>','text/html') });
    my $h = $b->add_user_script('window.__rem = 1;', at => 'start');
    my %g;
    $b->go('rem://host/1', sub {
        $b->script('return window.__rem || null', sub {
            $g{before} = $_[0];
            $h->remove;
            $h->remove;                    # idempotent: must not throw
            $b->go('rem://host/2', sub {
                $b->script('return window.__rem || null', sub { $g{after} = $_[0]; EV::break });
            });
        });
    });
    TWK::run_with_timeout(20);
    is($g{before}, 1,     'user script injected before remove');
    is($g{after},  undef, 'no injection after remove (double-remove did not throw)');
    $b->quit;
}

# remove_all_user_scripts removes the caller's scripts but must NOT wipe the
# module's own BOOT: find() (which needs the isolated-world registry) still works.
{
    my $b = EV::WebKit->new(window => [200,150]);
    $b->mock_scheme('clob', sub { ('<html><body><div id=x>X</div></body></html>','text/html') });
    $b->add_user_script('window.__a = 1;', at => 'start');
    $b->add_user_script('window.__b = 1;', at => 'start');
    $b->remove_all_user_scripts;
    my %g;
    $b->go('clob://host/p', sub {
        $b->script('return (window.__a||0) + (window.__b||0)', sub {
            $g{sum} = $_[0];
            $b->find('#x', sub { $g{el} = $_[0]; EV::break });
        });
    });
    TWK::run_with_timeout(20);
    is($g{sum}, 0, 'remove_all_user_scripts removed every user script');
    ok($g{el}, 'find() still works -- BOOT was NOT clobbered by remove_all_user_scripts')
        or diag('remove_all_user_scripts must loop remove_script over the user registry, not call remove_all_scripts');
    $b->quit;
}

# remove_all_user_scripts with nothing added is a safe no-op.
{
    my $b = EV::WebKit->new(window => [200,150]);
    my $ok = eval { $b->remove_all_user_scripts; 1 };
    ok($ok, 'remove_all_user_scripts with no scripts is a no-op');
    $b->quit;
}

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/95-user-remove.t`
Expected: FAIL -- `Can't locate object method "remove_all_user_scripts"`.

- [ ] **Step 3: Add remove_all_user_* and the helper**

In `lib/EV/WebKit.pm`, immediately AFTER the `_add_user_content` sub (from Task 1) closes, add:

```perl
# Remove every user script / stylesheet THIS caller added, and only those. Must
# NOT use WebKit's remove_all_scripts/remove_all_style_sheets: those also remove
# the module's own injected BOOT (the $EVWK_WORLD registry find()/html() need)
# and console proxy. Loop per-item removal over our registry instead.
sub remove_all_user_scripts { my $self = shift; $self->_remove_all_user('script'); return $self }
sub remove_all_user_styles  { my $self = shift; $self->_remove_all_user('style');  return $self }

sub _remove_all_user {
    my ($self, $kind) = @_;
    return if $self->{_dead} || !$self->{ucm};
    my $reg = $self->{"_user_${kind}s"} or return;
    my $m = $kind eq 'style' ? 'remove_style_sheet' : 'remove_script';
    $self->{ucm}->$m($_) for values %$reg;
    %$reg = ();
    return;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/95-user-remove.t`
Expected: PASS (5 assertions).

- [ ] **Step 5: Commit**

```bash
git add lib/EV/WebKit.pm t/95-user-remove.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "user-content: per-item remove + remove_all_user_scripts (BOOT-safe)"
```

---

## Task 3: URL-pattern scoping (allow/deny) + validation

**Files:**
- Test: `t/96-user-match.t` (create). No `lib/EV/WebKit.pm` change: the builder already threads `allow`/`deny` and validates their shape (Task 1). This task proves the behavior and locks it with tests.

**Interfaces:**
- Consumes: `add_user_script` with `allow`/`deny` arrayrefs of `scheme://host/*` glob strings.
- Produces: nothing new -- behavioral coverage only.

- [ ] **Step 1: Write the failing test**

Create `t/96-user-match.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

# navigate $url on $b, return window.__m (the flag an injected script would set).
sub flag_at {
    my ($b, $url) = @_;
    my $got;
    $b->go($url, sub { $b->script('return window.__m || null', sub { $got = $_[0]; EV::break }) });
    TWK::run_with_timeout(15);
    return $got;
}

# allow: runs only on the allow-listed origin. WebKit URL patterns need a path
# component (scheme://host/*) and the page URL must carry a path.
{
    my $b = EV::WebKit->new(window => [200,150]);
    $b->mock_scheme('aok', sub { ('<html><body>aok</body></html>','text/html') });
    $b->mock_scheme('ano', sub { ('<html><body>ano</body></html>','text/html') });
    $b->add_user_script('window.__m = 1;', at => 'start', allow => ['aok://host/*']);
    is(flag_at($b, 'aok://host/p'), 1,     'allow: runs on the allow-listed origin');
    is(flag_at($b, 'ano://host/p'), undef, 'allow: does NOT run on a different origin');
    $b->quit;
}

# deny: runs everywhere EXCEPT the denied origin.
{
    my $b = EV::WebKit->new(window => [200,150]);
    $b->mock_scheme('dno', sub { ('<html><body>dno</body></html>','text/html') });
    $b->mock_scheme('dok', sub { ('<html><body>dok</body></html>','text/html') });
    $b->add_user_script('window.__m = 1;', at => 'start', deny => ['dno://host/*']);
    is(flag_at($b, 'dno://host/p'), undef, 'deny: does NOT run on the denied origin');
    is(flag_at($b, 'dok://host/p'), 1,     'deny: runs on a non-denied origin');
    $b->quit;
}

# validation: allow/deny must be arrayrefs of strings.
{
    my $b = EV::WebKit->new(window => [200,150]);
    eval { $b->add_user_script('x', allow => 'aok://host/*') };
    like($@, qr/allow => .* must be an arrayref/, 'non-arrayref allow croaks');
    eval { $b->add_user_script('x', deny => [ {} ]) };
    like($@, qr/deny entries must be strings/,    'non-string deny entry croaks');
    $b->quit;
}

done_testing;
```

- [ ] **Step 2: Run the test -- it should PASS immediately**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/96-user-match.t`
Expected: PASS (6 assertions). The builder from Task 1 already threads and validates `allow`/`deny`; this test confirms it. If the two behavioral `allow`/`deny` cases fail, re-check that `@opt{qw/allow deny/}` is passed as the 4th/5th args to `WebKit::UserScript->new` (arrayref, not flattened) -- see Task 1 Step 4.

- [ ] **Step 3: Commit**

```bash
git add t/96-user-match.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "user-content: allow/deny URL-pattern scoping + validation coverage"
```

---

## Task 4: User stylesheets (add_user_style, level, remove)

**Files:**
- Test: `t/97-user-styles.t` (create). No `lib/EV/WebKit.pm` change: `add_user_style` and the style branch of the builder (level, `add_style_sheet`) and `remove_all_user_styles` already exist from Tasks 1-2. This task proves CSS behavior.

**Interfaces:**
- Consumes: `add_user_style($css, level => 'author'|'user', frames => ..., allow/deny => ...)` -> handle; `remove_all_user_styles`; the handle's `->remove` (dispatches to `remove_style_sheet` for `kind eq 'style'`).
- Produces: nothing new -- behavioral coverage only.

- [ ] **Step 1: Write the failing test**

Create `t/97-user-styles.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

# read is_visible('#h') after loading $url on $b.
sub visible_at {
    my ($b, $url) = @_;
    my $vis;
    $b->go($url, sub { $b->find('#h', sub { $_[0]->is_visible(sub { $vis = $_[0]; EV::break }) }) });
    TWK::run_with_timeout(15);
    return $vis;
}

# a user-level stylesheet beats the page's own CSS and hides the element;
# ->remove restores it on the next navigation.
{
    my $b = EV::WebKit->new(window => [200,150]);
    $b->mock_scheme('sty', sub {
        ('<html><head><style>h1{display:block}</style></head><body><h1 id=h>Hi</h1></body></html>','text/html');
    });
    my $h = $b->add_user_style('h1 { display:none !important }', level => 'user');
    isa_ok($h, 'EV::WebKit::UserContent', 'add_user_style returns a handle');
    is(visible_at($b, 'sty://host/p'), 0, 'user-level style hid the element (beat page CSS)');
    $h->remove;
    ok(visible_at($b, 'sty://host/p2'), 'element visible again after the style was removed');
    $b->quit;
}

# remove_all_user_styles clears every user style.
{
    my $b = EV::WebKit->new(window => [200,150]);
    $b->mock_scheme('sty2', sub { ('<html><body><h1 id=h>Hi</h1></body></html>','text/html') });
    $b->add_user_style('h1 { display:none !important }', level => 'user');
    $b->remove_all_user_styles;
    ok(visible_at($b, 'sty2://host/p'), 'remove_all_user_styles cleared the hiding style');
    $b->quit;
}

# validation: bad level croaks.
{
    my $b = EV::WebKit->new(window => [200,150]);
    eval { $b->add_user_style('h1{}', level => 'important') };
    like($@, qr/level => 'important' is invalid/, 'bad level croaks');
    $b->quit;
}

done_testing;
```

- [ ] **Step 2: Run the test -- it should PASS immediately**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/97-user-styles.t`
Expected: PASS (5 assertions). The style path was implemented in Tasks 1-2; this confirms CSS hiding, level, per-item remove, remove_all, and level validation.

- [ ] **Step 3: Commit**

```bash
git add t/97-user-styles.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "user-content: user stylesheets (level, hide, remove) coverage"
```

---

## Task 5: Lifecycle -- teardown clears registries, collectability, post-quit safety

**Files:**
- Modify: `lib/EV/WebKit.pm` -- `_teardown` clears the two registries.
- Test: `t/98-user-lifecycle.t` (create)

**Interfaces:**
- Consumes: `_teardown` (line ~2113-2145; the `delete @{$self}{qw/view win ucm session context chrome/};` line ~2143); the handle's weak-browser guard from Task 1.
- Produces: `_teardown` additionally deletes `_user_scripts`/`_user_styles`.

- [ ] **Step 1: Write the failing test**

Create `t/98-user-lifecycle.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use Scalar::Util qw(weaken);
use EV; use EV::WebKit;

sub spin { for (1..4) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run } }

# a still-held handle must NOT keep its browser alive after the browser is
# dropped (the handle's browser ref is weak).
{
    my $h; my $wb;
    {
        my $b = EV::WebKit->new(window => [200,150]);
        weaken($wb = $b);
        $h = $b->add_user_script('window.__x = 1;');
    }   # $b dropped; $h still in scope
    spin();
    ok(!defined $wb, 'a dangling user-content handle does not keep the browser alive');
    my $ok = eval { $h->remove; 1 };
    ok($ok, 'handle->remove after the browser is gone is a safe no-op');
}

# remove() after quit() is a no-op, and quit() cleared the registry.
{
    my $b = EV::WebKit->new(window => [200,150]);
    my $h = $b->add_user_script('window.__x = 1;');
    $b->quit;
    my $ok = eval { $h->remove; 1 };
    ok($ok, 'handle->remove after quit() is a safe no-op');
    is($b->{_user_scripts}, undef, 'quit cleared the user-script registry');
}

# adding to an already-closed browser croaks (synchronous call, no callback to
# carry a 'browser closed' error, so croak rather than drop silently).
{
    my $b = EV::WebKit->new(window => [200,150]);
    $b->quit;
    eval { $b->add_user_script('window.__x=1') };
    like($@, qr/browser closed/, 'add_user_script on a closed browser croaks');
}

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/98-user-lifecycle.t`
Expected: FAIL on `is($b->{_user_scripts}, undef, ...)` -- teardown does not yet delete the registry (the other assertions may already pass because the handle guards on `!$b->{ucm}`).

- [ ] **Step 3: Clear the registries in teardown**

In `lib/EV/WebKit.pm`, in `_teardown`, change the native-release line (line ~2143):

```perl
    delete @{$self}{qw/view win ucm session context chrome/};
```

to:

```perl
    delete @{$self}{qw/view win ucm session context chrome _user_scripts _user_styles/};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/98-user-lifecycle.t`
Expected: PASS (5 assertions).

- [ ] **Step 5: Commit**

```bash
git add lib/EV/WebKit.pm t/98-user-lifecycle.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "user-content: clear registries on teardown; handle lifecycle coverage"
```

---

## Task 6: Documentation and packaging

**Files:**
- Modify: `lib/EV/WebKit.pm` -- POD for the four methods (under `=head1 METHODS`) and a `=head1 EV::WebKit::UserContent` section (near the `=head1 EV::WebKit::Dialog`/`Policy` sections, line ~3039-3090).
- Modify: `Changes` -- one bullet under the `0.01` block.
- Modify: `MANIFEST` -- add the five new test files.

**Interfaces:**
- Consumes: nothing. Produces: docs + manifest.

- [ ] **Step 1: Add METHODS POD**

In `lib/EV/WebKit.pm`, under `=head1 METHODS`, after the `=head2 find_all` block (line ~2602, before the next unrelated `=head2`), add:

```pod
=head2 add_user_script

    my $h = $b->add_user_script($js, %opts);

Inject C<$js> into every page this instance loads, from the B<next> navigation
onward (WebKit injects user content at load time, so it does not affect the page
already showing). Returns an L</EV::WebKit::UserContent> handle whose C<remove>
takes just this script back out.

Options:

=over 4

=item at => 'end' (default) | 'start'

When the script runs relative to the page's own scripts. C<start> runs before
any page script -- but the DOM does not exist yet (C<document.body> is C<undef>),
so a script that touches the DOM should use C<end>.

=item world => 'main' (default) | 'isolated'

C<main> shares the page's JavaScript globals (what the page's own code sees).
C<isolated> gets a private global scope the page cannot read or corrupt, while
still sharing the one DOM -- use it to observe or rewrite a page without the page
noticing your variables.

=item frames => 'all' (default) | 'top'

Inject into all frames, or only the top-level document.

=item allow => [ globs ], deny => [ globs ]

Optional URL-pattern allow/deny lists. A pattern is C<scheme://host/path> with
C<*> wildcards and B<must> include a path component (C<'https://*.example.com/*'>,
not C<'https://*.example.com'>). With C<allow>, the script runs only on matching
URLs; C<deny> excludes matching URLs; C<deny> wins over C<allow>.

=back

Croaks on an undefined source or an invalid option value.

=head2 add_user_style

    my $h = $b->add_user_style($css, %opts);

Like L</add_user_script> but injects a CSS stylesheet. Accepts C<frames>,
C<allow>, and C<deny> as above (no C<world> -- WebKit user stylesheets have
none), plus:

=over 4

=item level => 'author' (default) | 'user'

C<author> mixes with the page's own author styles. C<user> is a user-agent-level
override that beats page CSS -- use it to reliably hide elements
(C<< 'div.ad { display:none !important }' >>).

=back

Returns an L</EV::WebKit::UserContent> handle.

=head2 remove_all_user_scripts

    $b->remove_all_user_scripts;

Remove every script added with L</add_user_script>. Does not touch the module's
own internal injection (the element registry that L</find> and L</html> rely on).
Chainable.

=head2 remove_all_user_styles

    $b->remove_all_user_styles;

Remove every stylesheet added with L</add_user_style>. Chainable.
```

- [ ] **Step 2: Add the handle-class POD**

In `lib/EV/WebKit.pm`, after the `=head1 EV::WebKit::Policy` block (ends line ~3090, before `=head1 LIMITATIONS`), add:

```pod
=head1 EV::WebKit::UserContent

The handle returned by L</add_user_script> and L</add_user_style>.

=head2 remove

    $h->remove;

Remove just this injected script or stylesheet. Takes effect from the next
navigation. Idempotent and safe: calling it twice, or after the browser has been
closed or collected, is a harmless no-op.
```

Note: do NOT add a `=cut` after this block. The whole file tail from `=head1 NAME`
(line ~2224) to EOF is one continuous POD block already terminated by a single
`=cut` at end-of-file; there is no code after it. Both this insert and the METHODS
insert in Step 1 land mid-POD -- a stray `=cut` would resume code parsing on the
following `=head1 LIMITATIONS` and break the build.

- [ ] **Step 3: Verify POD is well formed**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/90-pod.t`
Expected: PASS (`all_pod_files_ok`). If it reports an error, fix the POD syntax it names.

- [ ] **Step 4: Add a Changes entry**

In `Changes`, under the `0.01  2026-07-02` block, add one bullet in the existing style (plain ASCII, `--` for dashes):

```
        - user content: add_user_script/add_user_style inject caller JS/CSS (document start/end, main or isolated world, all/top frames, allow/deny URL globs); each returns a handle with ->remove; remove_all_user_scripts/remove_all_user_styles clear only the caller's items (never the module's own BOOT)
```

- [ ] **Step 5: Add the new test files to MANIFEST**

In `MANIFEST`, add these four lines among the `t/` entries (keep the file's ordering):

```
t/94-user-scripts.t
t/95-user-remove.t
t/96-user-match.t
t/97-user-styles.t
t/98-user-lifecycle.t
```

- [ ] **Step 6: Run the whole suite**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -l t/`
Expected: all files pass, including the five new `t/9[4-8]-*.t`. Confirm no regression in `t/40-find.t`/`t/70-console.t` (the BOOT/console injections the clobber guard protects).

- [ ] **Step 7: Commit**

```bash
git add lib/EV/WebKit.pm Changes MANIFEST
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "user-content: POD, Changes, MANIFEST"
```

---

## Self-review notes

- **Spec coverage:** API (Task 1/4), per-item + `remove_all` removal and the clobber guard (Task 2), allow/deny + validation (Task 3), styles/level (Task 4), collectability + post-quit + teardown clearing (Task 5), errors (Tasks 1/3/4/5), docs (Task 6). All spec sections map to a task.
- **Type consistency:** the handle class is `EV::WebKit::UserContent` everywhere; registries are `_user_scripts`/`_user_styles`; builder is `_add_user_content($kind, $source, %opt)` with `$kind` in `('script','style')`; nick maps `%USER_FRAMES`/`%USER_AT`/`%USER_LEVEL` and `%USER_WORLD_OK`; the isolated world is `$USER_WORLD = 'EVWebKitUser'`. These names are used identically across all tasks.
- **Ordering:** Tasks 3 and 4 add only tests (their code landed in Tasks 1-2) -- deliberate, so the allow/deny and CSS behaviors get their own review gate without a code change to reject. If a reviewer prefers, Tasks 1 and 3 can be squashed and Tasks 2 and 4 can be squashed; the tests still pass in either grouping.
```
