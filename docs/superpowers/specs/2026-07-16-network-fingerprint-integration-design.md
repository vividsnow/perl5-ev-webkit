# EV::WebKit network-fingerprint integration -- design

**Status:** approved design, pre-implementation
**Date:** 2026-07-16
**Program:** sub-project 3 (final) of the network-fingerprint program. Sub-project
1 (`Curl::Impersonate`) and 2 (`Proxy::Impersonate`) are DONE.

## Goal

Make an EV::WebKit browser's B<connection> fingerprint (TLS JA3/JA4 + HTTP/2
Akamai) match its already-spoofed JS/property-level device fingerprint, so a
fingerprinter sees one coherent device at every layer. EV::WebKit already spoofs
the JS layer via `fingerprint => <profile>` (a web-process extension). This wires
the network layer: an in-process `Proxy::Impersonate` re-originates every request
as the matching real browser.

## Decisions (from brainstorming)

- **Lifecycle:** in-process. EV::WebKit holds a `Proxy::Impersonate` object whose
  accept + curl_multi watchers run in the browser's own shared `EV::run` loop
  (EV + EV::Glib). No child process.
- **Activation:** a new opt-in `network_fingerprint => 1` that REQUIRES
  `fingerprint =>` and derives the curl target from that profile. Heavy deps
  (`Proxy::Impersonate`, `Net::SSLeay`, curl-impersonate) load only when enabled.
- **Coherence:** refresh all four presets to versions with EXACT curl targets, so
  the JS-implied and TLS-implied browser versions agree.
- **OS coherence via header overrides (added after a spike):** curl-impersonate
  ships only macOS desktop Chrome (`chrome131`) and Android Chrome
  (`chrome131_android`) -- no Windows Chrome. But Windows and macOS Chrome 131
  share an IDENTICAL TLS ClientHello + HTTP/2 (JA4 is OS-independent); they differ
  only in a few header VALUES (User-Agent + `Sec-CH-UA-platform`). Verified: with
  `chrome131` and those two headers overridden to Windows values, the origin sees
  JA4 `t13d...` (unchanged) + a Windows UA, no duplicate headers, Chrome header
  order preserved. So the proxy gains an `override_headers` set that EV::WebKit
  populates from the profile's identity headers (UA + `Sec-CH-UA`/`-mobile`/
  `-platform`), applied to every upstream request. This keeps `windows-chrome` as
  Windows and makes ALL four profiles fully coherent -- one shared TLS target,
  OS in the headers.

## Architecture and data flow

When `network_fingerprint` is set, the constructor (after the network session
exists): resolves the curl target from the fingerprint profile, creates an
in-process `Proxy::Impersonate` bound to `127.0.0.1:0`, tells the network session
to accept the proxy's self-signed cert, and routes through it.

```
WebKit --localhost, TLS-terminated--> Proxy::Impersonate --Curl::Impersonate(chrome131)--> origin
        (set_proxy + set_tls_errors_policy IGNORE)          (JA3/JA4/Akamai match the JS layer)
```

Everything runs in one process and one EV loop: the browser's GLib watchers (via
EV::Glib), the proxy's accept watcher, and curl_multi's socket/timer watchers.

## Components (files)

**EV::WebKit** (`~/dev/perl-modules/EV-WebKit`):
- `lib/EV/WebKit/Fingerprint.pm` -- refresh the four presets (Chrome 131 /
  Safari 18) and add the profile->curl-target map `%CURL_TARGET` +
  `curl_target($profile)`. Owns the profile data, so the mapping lives here.
- `lib/EV/WebKit.pm` -- add `network_fingerprint` to `%KNOWN_NEW`; in the
  constructor wire the proxy + session (below); croak clearly if deps are
  unavailable; shut the proxy down on teardown; add `network_fingerprint` and
  `proxy_port` accessors.
- `t/99-fingerprint.t` (+ a small network test) -- refreshed preset assertions +
  the wiring/coherence tests.

**Proxy::Impersonate** (`~/dev/perl-modules/Proxy-Impersonate`, bump to 0.02):
- `lib/Proxy/Impersonate.pm` -- add `shutdown`: drop the accept watcher, `_close`
  every active Connection (frees SSL/CTX, breaks the watcher-closure cycles,
  cancels in-flight upstream), release the multi + its watchers. Teardown WITHOUT
  `EV::break` (the shared loop keeps running the browser; `stop` breaks and is
  wrong for the in-process case).

Boundaries: `Fingerprint.pm` = profile data + mapping; `WebKit.pm` = proxy
lifecycle + session wiring; `Proxy::Impersonate::shutdown` = clean in-process
teardown.

## Preset refresh

Bring the four presets to current versions that have exact curl targets. UA
strings, `ua_data` (`uaFullVersion`, `brands`, `fullVersionList`), and the
version-bearing test assertions move together. GPU (`webgl_*`), screens, and
device knobs are unchanged.

| Profile | Was | Refresh to | curl target |
| --- | --- | --- | --- |
| windows-chrome | Chrome 120 | Chrome 131 | `chrome131` |
| macos-safari | Safari 17.1 | Safari 18.0 | `safari18_0` |
| iphone-safari | Safari 17.1 iOS | Safari 18.0 iOS | `safari18_0_ios` |
| pixel-chrome | Chrome 120 Android | Chrome 131 Android | `chrome131_android` |

Exact build numbers (real Chrome 131 / Safari 18 / iOS 18 strings) are pinned in
the implementation plan.

## API, mapping, trust wiring

`EV::WebKit->new`:
- `network_fingerprint => 1` -- enable; derive the target from the `fingerprint`
  profile via `curl_target`.
- `network_fingerprint => 'chrome124'` -- enable with an explicit target override.
- Requires `fingerprint => <profile>`; croaks otherwise.
- Accessors: `network_fingerprint` -> active target (or undef); `proxy_port`.

Wiring (constructor, when enabled, after the session exists):

```perl
eval { require Proxy::Impersonate; 1 }
    or Carp::croak("network_fingerprint requested but Proxy::Impersonate is unavailable: $@");
my $target = $override || EV::WebKit::Fingerprint::curl_target($profile)
    || Carp::croak("no curl target for fingerprint '$profile'");
$self->{proxy} = Proxy::Impersonate->new(impersonate => $target, listen => '127.0.0.1:0');
$session->set_tls_errors_policy('ignore');          # accept the proxy self-signed cert
$self->set_proxy("http://127.0.0.1:" . $self->{proxy}->port);
```

`cert_dir` is left to `Proxy::Impersonate`'s default (an ephemeral tempdir; fine
under IGNORE). Because activation is explicit opt-in, a missing dependency
CROAKS (not silent-degrade), matching how `fingerprint` croaks when its extension
was not built. `set_tls_errors_policy('ignore')` is global on the session, which
is acceptable: all traffic is proxied through localhost and the proxy re-verifies
the real origin upstream (`verify => 1`, the default).

## Teardown

EV::WebKit's close/quit path calls `$self->{proxy}->shutdown; delete
$self->{proxy}` (guarded on existence), EARLY in teardown so no proxy traffic
races the GI/window teardown. `shutdown` is a plain Perl/EV operation (no GI
callbacks), simpler than the IN_DISPATCH/_flush_later dance, and must not
`EV::break`.

## Testing

- **Preset refresh:** update `t/99-fingerprint.t` version assertions to
  Chrome 131 / Safari 18.
- **Mapping unit:** `curl_target($profile)` returns the right target per preset;
  unknown -> undef.
- **Wiring (no network, xvfb):** `network_fingerprint=>1` without `fingerprint`
  croaks; with it, `proxy_port` is set and `network_fingerprint` reports the
  target.
- **Flagship live e2e (CI_LIVE + xvfb) -- the capstone:** one EV::WebKit with
  `fingerprint=>'windows-chrome', network_fingerprint=>1` navigates to
  `https://tls.peet.ws/api/all`, reads the page JSON, and asserts BOTH layers
  agree -- the JA4 is Chrome (`t13d...`) AND `navigator.userAgent` says
  Chrome 131. Proves coherence end-to-end in a single browser.
- **Teardown:** create + close a `network_fingerprint` browser; assert it closes
  cleanly with the proxy shut down. C-level cleanliness leans on sub-project 2's
  valgrind.

## Scope / non-goals

In scope: the four-preset refresh, the `network_fingerprint` option + in-process
proxy wiring + teardown, the `Proxy::Impersonate::shutdown` method, tests. Out of
scope: new device profiles, WebSockets/HTTP/3 (deferred in sub-project 2), a
child-process proxy mode, per-request target switching.

## Dependencies

`Proxy::Impersonate` >= 0.02 (adds `shutdown`), which pulls `Curl::Impersonate`
0.02 + `Net::SSLeay` + curl-impersonate (via `Alien::curlimpersonate`). All are
optional at the EV::WebKit level -- required only when `network_fingerprint` is
used.
