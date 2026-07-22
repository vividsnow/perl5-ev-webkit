# EV::WebKit network-fingerprint integration -- Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an EV::WebKit browser's TLS/HTTP2 connection fingerprint match its JS-spoofed device profile by routing it through an in-process Proxy::Impersonate.

**Architecture:** A new opt-in `network_fingerprint => 1` (requires `fingerprint =>`) creates an in-process `Proxy::Impersonate` on the browser's shared EV loop, tells the WebKitNetworkSession to accept its self-signed cert (`set_tls_errors_policy('ignore')`), and routes through it (`set_proxy`). The four presets are refreshed to versions with exact curl targets so both layers agree.

**Tech Stack:** Perl, EV + EV::Glib, Glib::Object::Introspection (WebKitGTK 6.0), Proxy::Impersonate 0.02 (+ Curl::Impersonate 0.02, Net::SSLeay, Alien::curlimpersonate).

> **Revision (2026-07-16, during execution):** curl-impersonate has no Windows Chrome (only macOS `chrome131` + Android `chrome131_android`). Since Windows/macOS Chrome 131 share an identical TLS/HTTP2 (JA4 is OS-independent -- SPIKED: overriding UA + `Sec-CH-UA-platform` keeps JA4 `t13d...` and Chrome header order, no dup headers), OS coherence is achieved via **header overrides**, not a new TLS target. Changes: **Task 1b** (NEW) adds `override_headers` to `Proxy::Impersonate`; **Task 2** keeps `windows-chrome` as Windows (version-refresh only); **Task 3** also computes the profile's identity headers (UA + `Sec-CH-UA`/`-mobile`/`-platform` from `ua_data`) and passes them as `override_headers`. All four profiles end fully coherent.

## Global Constraints

- Two dists: `~/dev/perl-modules/EV-WebKit` (branch `network-fingerprint`, spec committed there) and a small addition to `~/dev/perl-modules/Proxy-Impersonate`.
- Commit author: `git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit`. No Co-Authored-By / LLM attribution.
- POD plain ASCII; use `--` not em-dashes.
- Never use `sed`; never monkeypatch GI methods.
- Build/test EV::WebKit under `xvfb-run` (bring-your-own-display; GI setup is display-independent but views need a display).
- Curl target map: windows-chrome->chrome131, macos-safari->safari18_0, iphone-safari->safari18_0_ios, pixel-chrome->chrome131_android.
- `set_tls_errors_policy` nick is `'ignore'` (WebKitTLSErrorsPolicy; verified via GI introspection: WebKit::NetworkSession has set_tls_errors_policy / allow_tls_certificate_for_host / set_proxy_settings).
- JS eval API: `$b->script('return <expr>;', sub { my ($result, $err) = @_ })`.

---

## Task 1: Proxy::Impersonate::shutdown (0.02)

In-process teardown that closes active connections WITHOUT `EV::break` (the shared loop keeps running the browser).

**Files:**
- Modify: `~/dev/perl-modules/Proxy-Impersonate/lib/Proxy/Impersonate.pm`
- Modify: `~/dev/perl-modules/Proxy-Impersonate/Changes`
- Test: `~/dev/perl-modules/Proxy-Impersonate/t/50-shutdown.t`

**Interfaces:**
- Produces: `$proxy->shutdown` -- drops the accept watcher, `_close`s every active connection, releases the curl_multi watchers + multi. Returns `$proxy`. Does NOT call `EV::break`.

- [ ] **Step 1: Write the failing test**

Create `t/50-shutdown.t`:
```perl
use v5.10; use strict; use warnings;
use Test::More;
use EV;
use File::Temp qw(tempdir);
use Proxy::Impersonate;

my $p = Proxy::Impersonate->new(impersonate => 'chrome131',
    listen => '127.0.0.1:0', cert_dir => tempdir(CLEANUP => 1));

# inject a fake active connection to prove shutdown closes it
my $closed = 0;
{ package FakeConn; sub _close { ${ $_[0] } = 1 } }
my $fake = bless \$closed, 'FakeConn';
$p->{conns}{$fake} = $fake;

# shutdown must NOT break the loop: a later timer still fires
my $ran_after = 0;
my $t1 = EV::timer(0,    0, sub { $p->shutdown });
my $t2 = EV::timer(0.05, 0, sub { $ran_after = 1; EV::break() });
EV::run;

ok($closed, 'shutdown closed the active connection');
ok($ran_after, 'EV loop kept running after shutdown (no EV::break)');
is_deeply($p->{conns}, {}, 'connections cleared');
ok(!$p->{aw}, 'accept watcher dropped');
ok(!$p->{multi}, 'multi released');
done_testing;
```

- [ ] **Step 2: Run (RED)**

Run: `cd ~/dev/perl-modules/Proxy-Impersonate && prove -l t/50-shutdown.t`
Expected: FAIL (`shutdown` undefined -> the timer that calls it dies, `$closed`/`$ran_after` stay 0).

- [ ] **Step 3: Implement shutdown**

In `lib/Proxy/Impersonate.pm`, add after `sub stop`:
```perl
# In-process teardown: stop accepting, close active connections, release the
# curl_multi wiring. Unlike stop(), does NOT EV::break -- the caller's shared
# loop keeps running (e.g. EV::WebKit's browser loop).
sub shutdown {
    my ($self) = @_;
    undef $self->{aw};
    my @conns = values %{ $self->{conns} || {} };   # snapshot: _close mutates {conns} via on_close
    $self->{conns} = {};
    for my $c (@conns) { eval { $c->_close } }
    $self->{cio} = {};
    undef $self->{ctimer};
    undef $self->{multi};
    return $self;
}
```

- [ ] **Step 4: Run (GREEN)** -- `prove -l t/50-shutdown.t` -- Expected: PASS (5 tests).

- [ ] **Step 5: Version bump + Changes + commit**

Bump `our $VERSION = '0.02';` in `lib/Proxy/Impersonate.pm`. Prepend to `Changes`:
```
0.02  2026-07-16
    - Add shutdown(): in-process teardown that closes active connections and
      releases the curl_multi wiring without EV::break, for embedding the proxy
      in another EV loop (e.g. EV::WebKit).
```
```bash
git add lib/Proxy/Impersonate.pm Changes t/50-shutdown.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "Proxy::Impersonate 0.02: shutdown() for in-process teardown (no EV::break)"
```
Then `make install` so EV::WebKit consumes 0.02.

---

## Task 2: Fingerprint preset refresh + curl-target map

Refresh the four presets to versions with exact curl targets, and add the profile->target mapping. Runs in the EV-WebKit `network-fingerprint` branch.

**Files:**
- Modify: `~/dev/perl-modules/EV-WebKit/lib/EV/WebKit/Fingerprint.pm`
- Test: `~/dev/perl-modules/EV-WebKit/t/98-curl-target.t` (new)

**Interfaces:**
- Produces: `EV::WebKit::Fingerprint::curl_target($profile_name)` -> curl-impersonate target string, or undef for an unknown/override-only name. Consumed by Task 3.

- [ ] **Step 1: Write the failing test**

Create `t/98-curl-target.t`:
```perl
use v5.10; use strict; use warnings;
use Test::More;
use EV::WebKit::Fingerprint;

is(EV::WebKit::Fingerprint::curl_target('windows-chrome'), 'chrome131',        'windows-chrome -> chrome131');
is(EV::WebKit::Fingerprint::curl_target('macos-safari'),   'safari18_0',       'macos-safari -> safari18_0');
is(EV::WebKit::Fingerprint::curl_target('iphone-safari'),  'safari18_0_ios',   'iphone-safari -> safari18_0_ios');
is(EV::WebKit::Fingerprint::curl_target('pixel-chrome'),   'chrome131_android','pixel-chrome -> chrome131_android');
is(EV::WebKit::Fingerprint::curl_target('nope'), undef, 'unknown profile -> undef');

# every preset has a curl target (coherence)
ok(EV::WebKit::Fingerprint::curl_target($_), "preset $_ maps to a target")
    for EV::WebKit::Fingerprint::profiles();

# refreshed versions
my $wc = EV::WebKit::Fingerprint::resolve('windows-chrome');
like($wc->{user_agent}, qr{Chrome/131\.}, 'windows-chrome UA is Chrome 131');
like($wc->{ua_data}{uaFullVersion}, qr{^131\.}, 'windows-chrome uaFullVersion is 131');
my $ms = EV::WebKit::Fingerprint::resolve('macos-safari');
like($ms->{user_agent}, qr{Version/18\.}, 'macos-safari UA is Safari 18');
done_testing;
```

- [ ] **Step 2: Run (RED)** -- `cd ~/dev/perl-modules/EV-WebKit && prove -lv t/98-curl-target.t` -- Expected: FAIL (`curl_target` undefined + old versions).

- [ ] **Step 3: Refresh the presets**

In `lib/EV/WebKit/Fingerprint.pm`, update the four `%PRESET` entries. Change ONLY the version-bearing fields (UA strings, `ua_data`); leave `webgl_*`, `screen`, device knobs untouched.

`windows-chrome`:
```perl
        user_agent => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        # ... unchanged platform/vendor/screen/webgl ...
        ua_data => { platform => 'Windows', platformVersion => '10.0.0', architecture => 'x86', bitness => '64', model => '', uaFullVersion => '131.0.6778.86',
                     brands          => [ {brand=>'Not_A Brand',version=>'24'},       {brand=>'Chromium',version=>'131'},          {brand=>'Google Chrome',version=>'131'} ],
                     fullVersionList => [ {brand=>'Not_A Brand',version=>'24.0.0.0'}, {brand=>'Chromium',version=>'131.0.6778.86'}, {brand=>'Google Chrome',version=>'131.0.6778.86'} ] },
```
`macos-safari`:
```perl
        user_agent => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
```
`iphone-safari`:
```perl
        user_agent => 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
```
`pixel-chrome`:
```perl
        user_agent => 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
        # ... unchanged ...
        ua_data => { platform => 'Android', platformVersion => '14.0.0', architecture => '', bitness => '', model => 'Pixel 8', uaFullVersion => '131.0.6778.86',
                     brands          => [ {brand=>'Not_A Brand',version=>'24'},       {brand=>'Chromium',version=>'131'},          {brand=>'Google Chrome',version=>'131'} ],
                     fullVersionList => [ {brand=>'Not_A Brand',version=>'24.0.0.0'}, {brand=>'Chromium',version=>'131.0.6778.86'}, {brand=>'Google Chrome',version=>'131.0.6778.86'} ] },
```
NOTE: confirm `131.0.6778.86` and the GREASE brand (`Not_A Brand`;v=`24`) against a current real Chrome 131 `Sec-CH-UA` / UA before finalizing (as the curl target list was confirmed empirically in sub-project 1). Adjust the exact build/GREASE if they differ; the structure stays.

- [ ] **Step 4: Add the curl-target map + accessor**

In `lib/EV/WebKit/Fingerprint.pm`, after `%PRESET` (near `sub profiles`), add:
```perl
my %CURL_TARGET = (
    'windows-chrome' => 'chrome131',
    'macos-safari'   => 'safari18_0',
    'iphone-safari'  => 'safari18_0_ios',
    'pixel-chrome'   => 'chrome131_android',
);
sub curl_target { $CURL_TARGET{ $_[0] // '' } }
```

- [ ] **Step 5: Run (GREEN)** -- `prove -l t/98-curl-target.t` -- Expected: PASS. Then run the existing fingerprint suite to catch any version-hardcoded assertion: `xvfb-run -a prove -l t/99-fingerprint.t` -- Expected: PASS (t/99 tests structure, not exact versions; fix any that pinned 120/17.1).

- [ ] **Step 6: Commit**

```bash
git add lib/EV/WebKit/Fingerprint.pm t/98-curl-target.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: refresh presets to Chrome 131 / Safari 18 + curl-target map"
```

---

## Task 3: EV::WebKit network_fingerprint wiring + teardown

The option, proxy creation, session wiring, accessors, croaks, and shutdown-on-quit -- all in `EV/WebKit.pm`.

**Files:**
- Modify: `~/dev/perl-modules/EV-WebKit/lib/EV/WebKit.pm`
- Test: `~/dev/perl-modules/EV-WebKit/t/97-network-fingerprint.t` (new)

**Interfaces:**
- Consumes: `EV::WebKit::Fingerprint::curl_target` (Task 2), `Proxy::Impersonate->new`/`->port`/`->shutdown` (Task 1).
- Produces: `network_fingerprint => 1|<target>` constructor option; `$b->network_fingerprint` -> active target or undef; `$b->proxy_port` -> port or undef.

- [ ] **Step 1: Write the failing test (unit, no navigation)**

Create `t/97-network-fingerprint.t`:
```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;
plan skip_all => 'network_fingerprint needs Proxy::Impersonate'
    unless eval { require Proxy::Impersonate; 1 };

# requires fingerprint
eval { EV::WebKit->new(window => [400,300], network_fingerprint => 1) };
like($@, qr/network_fingerprint requires fingerprint/, 'croaks without a fingerprint profile');

# conflict with an explicit proxy
eval { EV::WebKit->new(window => [400,300], fingerprint => 'windows-chrome',
                       network_fingerprint => 1, proxy => 'http://x:1') };
like($@, qr/network_fingerprint/, 'croaks when combined with an explicit proxy');

# enabled: derives the target, spins an in-process proxy, reports the port
my $b = EV::WebKit->new(window => [400,300],
    fingerprint => 'windows-chrome', network_fingerprint => 1);
is($b->network_fingerprint, 'chrome131', 'derived curl target from the profile');
ok($b->proxy_port, 'proxy_port is set (in-process proxy bound)');

# override form
my $b2 = EV::WebKit->new(window => [400,300],
    fingerprint => 'windows-chrome', network_fingerprint => 'chrome124');
is($b2->network_fingerprint, 'chrome124', 'explicit target override honored');

# off by default
my $b3 = EV::WebKit->new(window => [400,300], fingerprint => 'windows-chrome');
is($b3->network_fingerprint, undef, 'off unless requested');
is($b3->proxy_port, undef, 'no proxy when off');

# teardown is clean (proxy shut down, no hang)
my $port = $b->proxy_port;
$b->quit;
ok(!$b->proxy_port, 'proxy_port cleared after quit');
done_testing;
```

- [ ] **Step 2: Run (RED)** -- `xvfb-run -a prove -l t/97-network-fingerprint.t` -- Expected: FAIL (`network_fingerprint` is an unknown option -> croak from the KNOWN_NEW guard).

- [ ] **Step 3: Register the option**

In `lib/EV/WebKit.pm`, add `network_fingerprint` to `%KNOWN_NEW` (the `qw(...)` list around line 172-178, next to `fingerprint`).

- [ ] **Step 4: Early validation**

In the constructor, right after `$fp = EV::WebKit::Fingerprint::resolve($o{fingerprint});` (around line 195, still inside the `if (defined $o{fingerprint})` region -- place these checks just after that block closes):
```perl
    if ($o{network_fingerprint}) {
        Carp::croak('EV::WebKit: network_fingerprint requires fingerprint => <profile>')
            unless $fp;
        Carp::croak('EV::WebKit: network_fingerprint and an explicit proxy => are mutually exclusive')
            if exists $o{proxy};
    }
```

- [ ] **Step 5: Wire the proxy after the session exists**

In the constructor, after `$self->set_proxy($o{proxy}) if exists $o{proxy};` (around line 325):
```perl
    if ($o{network_fingerprint}) {
        eval { require Proxy::Impersonate; 1 }
            or Carp::croak("EV::WebKit: network_fingerprint requested but Proxy::Impersonate is unavailable: $@");
        my $target = ($o{network_fingerprint} ne '1' && $o{network_fingerprint} =~ /\D/)
            ? $o{network_fingerprint}                                   # explicit target override
            : EV::WebKit::Fingerprint::curl_target($o{fingerprint});    # derive from the profile
        Carp::croak("EV::WebKit: no curl target for fingerprint '$o{fingerprint}'")
            unless $target;
        my $proxy = Proxy::Impersonate->new(impersonate => $target, listen => '127.0.0.1:0');
        $self->{proxy} = $proxy;
        $self->{network_fingerprint} = $target;
        $self->{session}->set_tls_errors_policy('ignore');             # accept the proxy self-signed cert
        $self->set_proxy('http://127.0.0.1:' . $proxy->port);
    }
```
NOTE: the override test is `$o{network_fingerprint}` being a target string vs a bare truthy `1`. `1` (or any all-digit-less value) derives; a value containing a non-digit (e.g. `chrome124`) is an explicit target. This keeps `network_fingerprint => 1` = derive.

- [ ] **Step 6: Accessors**

Add near the other accessors (e.g. after the `fingerprint` accessor):
```perl
sub network_fingerprint { $_[0]{network_fingerprint} }
sub proxy_port { my $s = shift; $s->{proxy} ? $s->{proxy}->port : undef }
```

- [ ] **Step 7: Teardown hook**

In `sub quit`, right after `$self->{_dead} = 1;` (line 2269):
```perl
    if (my $proxy = delete $self->{proxy}) { eval { $proxy->shutdown } }
    delete $self->{network_fingerprint};
```
This runs synchronously and early -- the proxy is plain EV/Perl (no GI callbacks), so it is safe even inside a dispatch frame, and stopping it before the GI/window teardown prevents proxy traffic from racing it.

- [ ] **Step 8: Run (GREEN)** -- `xvfb-run -a prove -l t/97-network-fingerprint.t` -- Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/EV/WebKit.pm t/97-network-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "EV::WebKit: network_fingerprint => in-process Proxy::Impersonate wiring + teardown"
```

---

## Task 4: Flagship live coherence test

Prove both layers agree in ONE browser against a real fingerprint endpoint.

**Files:**
- Test: `~/dev/perl-modules/EV-WebKit/t/96-network-coherence.t` (new)

- [ ] **Step 1: Write the live test**

Create `t/96-network-coherence.t`:
```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;
plan skip_all => 'live coherence test; set CI_LIVE=1' unless $ENV{CI_LIVE};
plan skip_all => 'needs Proxy::Impersonate' unless eval { require Proxy::Impersonate; 1 };

my $b = EV::WebKit->new(window => [1200,800],
    fingerprint => 'windows-chrome', network_fingerprint => 1);
my ($ua, $body, $err);
$b->go('https://tls.peet.ws/api/all', sub {
    my (undef, $e) = @_;
    if ($e) { $err = $e; EV::break(); return }
    $b->script('return JSON.stringify({ua: navigator.userAgent, body: document.body.innerText});', sub {
        my ($json, $se) = @_;
        if ($se) { $err = $se } else {
            require JSON::PP;
            my $d = eval { JSON::PP::decode_json($json) };
            ($ua, $body) = ($d->{ua}, $d->{body}) if $d;
        }
        EV::break();
    });
});
my $t = EV::timer(45, 0, sub { $err //= 'timeout'; EV::break() });
EV::run;

ok(!$err, 'navigated + read the page through the proxy') or diag($err);
# JS layer:
like($ua, qr{Chrome/131}, 'JS navigator.userAgent is Chrome 131');
# TLS layer (what the origin saw), from the fingerprint JSON body:
my ($ja4) = ($body // '') =~ /"ja4":\s*"([^"]+)"/;
ok($ja4, "origin reported a JA4 ($ja4)");
like($ja4, qr/^t13d/, 'origin-seen JA4 is Chrome-shaped -- coherent with the JS layer');
like($body, qr/"user_agent":\s*"[^"]*Chrome\/131/, 'origin-seen User-Agent is also Chrome 131');
done_testing;
```

- [ ] **Step 2: Run** -- `CI_LIVE=1 xvfb-run -a prove -l t/96-network-coherence.t` -- Expected: PASS (JS UA Chrome 131 AND origin JA4 t13d -- both layers coherent).

- [ ] **Step 3: Commit**

```bash
git add t/96-network-coherence.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "EV::WebKit: live coherence test (JS UA + origin JA4 both Chrome 131 in one browser)"
```

---

## Task 5: POD, Changes, full test pass

**Files:**
- Modify: `~/dev/perl-modules/EV-WebKit/lib/EV/WebKit.pm` (POD), `~/dev/perl-modules/EV-WebKit/Changes`

- [ ] **Step 1: POD**

In `EV/WebKit.pm`, document `network_fingerprint` in the constructor options POD and add `network_fingerprint`/`proxy_port` to the methods POD. Cover: it requires `fingerprint =>`; it spins an in-process `Proxy::Impersonate` on the shared EV loop and routes the browser through it so the origin's TLS/HTTP2 fingerprint matches the JS-spoofed device; it sets the network session to accept the proxy cert (`set_tls_errors_policy('ignore')` -- WebKitGTK has no custom-CA path, verified by a spike); it requires the optional `Proxy::Impersonate` toolchain (croaks if absent); accepts an explicit curl-target override; the mapping windows-chrome->chrome131 etc. Plain ASCII, `--` dashes.

- [ ] **Step 2: Changes**

Prepend an entry describing: `network_fingerprint =>` (in-process TLS/HTTP2 re-origination via Proxy::Impersonate), and the preset refresh to Chrome 131 / Safari 18.

- [ ] **Step 3: Full test pass**

Run: `xvfb-run -a prove -l t/` (structural + wiring), then `CI_LIVE=1 xvfb-run -a prove -l t/96-network-coherence.t`.
Expected: all pass; the live coherence test passes with network.

- [ ] **Step 4: Commit**

```bash
git add lib/EV/WebKit.pm Changes
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "EV::WebKit: POD + Changes for network_fingerprint + preset refresh"
```

---

## Self-review notes

- **Spec coverage:** in-process proxy on the shared loop (Task 3 wiring); opt-in derived option + mapping (Tasks 2-3); preset refresh (Task 2); trust wiring set_tls_errors_policy+set_proxy (Task 3 Step 5); teardown shutdown (Task 1 + Task 3 Step 7); dep-unavailable croak (Task 3 Step 5); accessors (Task 3 Step 6); flagship live coherence + wiring/croak unit tests (Tasks 3-4); POD/Changes (Task 5). Every spec section maps to a task.
- **Type consistency:** `curl_target($profile)` (Task 2) is consumed identically in Task 3; `Proxy::Impersonate->new(impersonate=>,listen=>)` / `->port` / `->shutdown` (Task 1) match Task 3's calls; `network_fingerprint`/`proxy_port` accessors (Task 3) are asserted in Tasks 3-4; the target map values match the Global Constraints.
- **Known soft spots (flagged):** the exact Chrome 131 build number + GREASE brand (Task 2 Step 3) are pinned to real-plausible values and confirmed against a current Chrome 131 UA at execution (as the curl target list was); the constructor insertion points (Task 3 Steps 4/5/7) are given by anchor line + surrounding code and matched to the real file at execution; `set_tls_errors_policy('ignore')` nick is verified via GI introspection.
