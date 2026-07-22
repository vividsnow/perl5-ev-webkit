# EV::WebKit -- Design Spec

Date: 2026-07-01
Status: Draft for review
Author: vividsnow

## 1. Overview

`EV::WebKit` is an asynchronous, in-process browser-automation library built on
**WebKitGTK 6.0** (the GTK4 successor to webkit2gtk) driven from Perl through
**GObject Introspection**. It is a Firefox::Marionette-*inspired* toolkit --
navigate, find elements, click/type, wait, evaluate JavaScript, screenshot,
manage cookies -- but with a **WebKit-native, EV-callback API** rather than the
Marionette wire protocol or a synchronous facade. No separate browser process:
WebKit runs embedded in the Perl process, driven by the GLib main loop bridged
into `EV`.

It joins the author's `EV::*` family (EV::Pg, EV::Kafka, EV::ClickHouse,
EV::Redis, EV::Nats, EV::Websockets, ...) and mirrors that house style:
`new(on_error => ...)`, `on_<event>` handlers, and terminal callbacks with a
`($result, $err)` signature run under `EV::run`.

### Motivation

The author already has GTK3 + WebKit2 (4.0/4.1) screenshot/PDF scripts
(`~/dev/tmp/webkit2-shot.pl`, `screenshot.pl`, `pdfshot-webkit2.pl`). Those do
static rendering only. This module adds the missing *interaction/introspection*
layer (find, click, type, wait, extract) and moves to the GTK4/WebKit-6.0 stack,
as a lighter, embeddable alternative to Firefox::Marionette (no Firefox binary,
no external process, native EV integration).

## 2. Non-goals (v1)

- No Marionette/WebDriver wire-protocol compatibility (WebKit-native API instead).
- No synchronous/blocking facade -- async EV/callbacks only.
- No multi-tab / multi-view management (single WebView per browser object).
- No web-process extension (native DOM via a content-process shared lib) -- a
  documented future power-up; v1 uses injected JS only.
- No macOS support (WebKitGTK is Linux/BSD). v1 target: **Linux**.
- No media/WebRTC/download management.

## 3. Target environment & dependencies

Verified present on the dev host (2026-07-01):

- GTK4 **4.22**, typelib `Gtk-4.0` / `Gdk-4.0` / `Gsk-4.0`.
- **`WebKit-6.0`** typelib (lib `libwebkitgtk-6.0.so.4`); deps
  `Soup-3.0 | JavaScriptCore-6.0 | Gtk-4.0`, all present.
- `JavaScriptCore-6.0` typelib (result marshalling).
- `Xvfb` + `xvfb-run` available.

**No XS, no pkg-config `-dev` packages, no extra `gir1.2-*` needed** -- the
runtime typelibs alone suffice via `Glib::Object::Introspection`.

CPAN prereqs (runtime): `EV`, `EV::Glib`, `Glib`, `Glib::Object::Introspection`,
a JSON codec (`Cpanel::JSON::XS` preferred, `JSON::PP` fallback). Non-CPAN
runtime deps (documented, checked at load with a helpful error): the WebKit-6.0 /
Gtk-4.0 / JavaScriptCore-6.0 typelibs + `Xvfb`.

## 4. Architecture

```
EV::WebKit            public browser object: display+session lifecycle, WebView,
                      navigation, JS eval, screenshot/PDF, cookies, settings,
                      events (on_load/on_console/on_dialog/...).
EV::WebKit::Element   opaque DOM handle { view, world, id }; click/type/text/
                      attr/prop/value/is_visible/tag/find -- each compiles to JS.
EV::WebKit::Display   (internal) private Xvfb lifecycle: pick free display,
                      spawn, set $ENV{DISPLAY}, reap on DESTROY.
EV::WebKit::Bridge    (internal) the injected boot script (handle registry +
                      atoms in an isolated JS world) + JSCValue<->Perl JSON
                      marshalling helpers.
```

Proposed file layout:

```
lib/EV/WebKit.pm
lib/EV/WebKit/Element.pm
lib/EV/WebKit/Display.pm
lib/EV/WebKit/Bridge.pm        # marshalling + boot-JS text
Makefile.PL  cpanfile  MANIFEST  MANIFEST.SKIP  Changes  README.md
t/...  xt/...
.github/workflows/ci.yml
```

### Approach chosen

**Thin GI binding + JS-atom bridge.** Native WebKit calls for
navigation/snapshot/PDF/cookies/settings/proxy; DOM find+interact via injected
JavaScript + a JS-side handle registry, because **WebKitGTK 6.0 removed the
`WebKitDOM` API** -- JS is the only DOM path (the Selenium-atoms model).
Rejected alternatives: (B) web-process extension -- more robust but extensions
are C shared libs loaded by path, awkward from Perl, deferred; (C) external
`WebKitWebDriver` binary -- out-of-process, not EV-native, defeats the goal.

## 5. Async model

- Runs on **`EV` + `EV::Glib`** (EV drives the GLib main loop; same pattern as
  the author's existing `webkit2-shot.pl`). The user calls `EV::run` / `EV::break`.
- Every async method takes a trailing callback invoked as
  `sub { my ($result, $err) = @_ }`. On success `$err` is undef; on failure
  `$result` is undef and `$err` is a string (or lightweight error object).
- **GError**, **JS exceptions** (from `evaluate_javascript_finish` /
  `call_async_javascript_function_finish`), and **timeouts** all normalize to
  `$err`. The finish call is wrapped in `eval` and the trapped error stringified.
- A global `on_error => sub { my ($err) = @_ }` (constructor) receives errors
  from events that have no per-call callback (load-failed with no pending nav,
  console errors if opted in, etc.).
- **Timeouts & cancellation:** each async op may take `timeout =>` (seconds,
  default configurable). Implemented with an `EV::timer` + a
  `Glib::IO::Cancellable` passed to the WebKit call; on expiry the cancellable is
  cancelled and the callback fires with a timeout `$err`. The op-completion path
  cancels the timer.

## 6. Display management (auto Xvfb)

`EV::WebKit::Display`:

- Default `headless => 1`: pick a free display number (probe `/tmp/.X11-unix`),
  spawn `Xvfb :N -screen 0 <W>x<H>x24 -nolisten tcp` (size from
  `window => [w,h]`), wait for readiness, set `$ENV{DISPLAY} = ":N"` and
  `$ENV{GDK_BACKEND} = "x11"` (GTK4 needs x11 under Xvfb).
- Overrides: `visible => 1` (use the ambient `$DISPLAY`, show a real window for
  debugging -- mirrors the old scripts' `-d` flag) or `display => ':0'`.
- The Xvfb child is tracked and killed on `DESTROY`/global-destruct; PID guarded
  so a forked child never reaps the parent's server.
- Note: GTK4 has **no `OffscreenWindow`**. Headless rendering uses a normal
  `Gtk4::Window` containing the WebView, `present()`ed under Xvfb; snapshots come
  from the WebView itself (see 8.5).

## 7. JS bridge

- A **boot UserScript** is injected at `document-start` into a **dedicated
  isolated JS world** (`EV_WebKit`) via `WebKit::UserContentManager->add_script`,
  so page code cannot see or tamper with the registry (isolated worlds share the
  DOM but not JS globals).
- The boot script installs a registry:
  `globalThis.__evwk = { h:[], put(n){ this.h.push(n); return this.h.length-1 },
  get(i){ return this.h[i] } , ... }` plus a small set of "atoms"
  (query, click, setValue+dispatch input/change, textContent, getAttribute,
  visibility test, scoped query).
- **Argument passing:** prefer `call_async_javascript_function($body, ...,
  $arguments)` -- args (selector, element id, text) are passed as a GVariant
  `a{sv}` dict, **not string-interpolated**, eliminating injection and quoting
  bugs; the body may `await`.
- **Result marshalling:** JS side returns JSON-serializable values; helper wraps
  as `JSON.stringify(result)`; Perl reads `JSCValue->to_string` and
  `decode_json`. DOM nodes are non-serializable, so `find` returns
  `{ evwk_id: <int> }`, which Perl blesses into `EV::WebKit::Element`. Scalar JS
  results (string/number/bool/null/array/object) round-trip as plain Perl data.
- Staleness: element atoms check the node is still connected
  (`node.isConnected`); if not, the callback gets a `stale element` `$err`.

## 8. Public API

### 8.1 Constructor & lifecycle

```perl
my $b = EV::WebKit->new(
    headless   => 1,                 # default; else visible=>1 / display=>':0'
    window     => [1280, 960],       # viewport / Xvfb screen size
    user_agent => 'Mozilla/5.0 ...',
    settings   => { enable_javascript => 1, auto_load_images => 1, ... },
    ephemeral  => 1,                 # private NetworkSession (no disk)
    cookie_jar => '/path/cookies.sqlite',  # persistence (section 8.7)
    proxy      => 'http://127.0.0.1:8080', # or { default=>..., ignore=>[...] }
    timeout    => 30,                # default per-op seconds
    on_error   => sub { warn $_[0] },
    on_console => sub { my ($msg,$level,$src,$line)=@_; ... },
    on_dialog  => sub { my ($d)=@_; $d->accept },   # else auto-dismiss
    on_load    => sub { ... },       # every load-finished
    on_policy  => sub { ... },       # interception hook (section 8.9)
);
```

Construction detail: `WebKit::WebView` construct-only props
(`network-session`, `user-content-manager`, `web-context`) are set via
`Glib::Object::new('WebKit::WebView', ...)` (verify exact GI path in planning).

Lifecycle: `$b->quit` / implicit `DESTROY` -> stop loading, drop the view,
persist cookies if configured, reap Xvfb.

### 8.2 Navigation

- `go($uri, $cb)` -- `load_uri`; `$cb` fires on the next `finished` `load-changed`
  (or `$err` from `load-failed` / timeout).
- `load_html($html, $base_uri, $cb)`.
- `reload($cb)`, `back($cb)`, `forward($cb)`, `stop`.
- Accessors: `uri`, `title`, `html($cb)` (via `document.documentElement.outerHTML`),
  `is_loading`.

### 8.3 JavaScript evaluation

- `script($js, $cb)` -- evaluate `$js` (implicit `return` wrapper), marshalled
  result to `$cb`. Runs in the page's main world by default.
- `script_async($body, \%args, $cb)` -- `call_async_javascript_function`; `$body`
  may `await`; `%args` passed as a dict.

### 8.4 Elements

- `find($selector, $cb)` -> `($el, $err)`; `$el` is `EV::WebKit::Element` or undef
  if not found (not an error -- `$el` undef, `$err` undef).
- `find_all($selector, $cb)` -> `(\@els, $err)`.
- `wait_for($selector_or_coderef, %opt, $cb)` -- poll (default 50ms, `EV::timer`)
  a JS predicate (selector existence, or an arbitrary JS boolean expression)
  until true or `timeout`; `$cb` gets the element/true or a timeout `$err`.

`EV::WebKit::Element` methods (all async, `($result,$err)`):
`click`, `type($text)` / `send_keys`, `clear`, `text`, `html`, `attr($name)`,
`prop($name)`, `value`, `is_visible`, `tag`, `find($sel)` /
`find_all($sel)` (scoped), `focus`, `submit`.

### 8.5 Screenshot

- `screenshot($path_or_opts, $cb)` -- `get_snapshot(region, options, ...)` ->
  `GdkTexture` -> `save_to_png_bytes` -> write file (GTK 4.22 exposes only the
  bytes variant). Opts: `region => 'visible'|'full-document'`,
  `transparent => 1`, or `bytes => 1` to receive PNG bytes instead of writing.

### 8.6 PDF export

- `pdf($path, %opt, $cb)` -- port of the existing `WebKit::PrintOperation` code:
  A4/margins/resolution defaults, `output-file-format=pdf`,
  `printer='Print to File'`, `output-uri=file://...`; `$cb` on the `finished`
  signal (or `failed` -> `$err`).

### 8.7 Cookies

- `cookies($uri, $cb)` -> list of `{name,value,domain,path,...}` (from
  `Soup::Cookie`).
- `set_cookie(\%spec, $cb)` -- build `Soup::Cookie`, `add_cookie`.
- `clear_cookies($cb)`.
- Persistence: `cookie_jar => $file` sets
  `CookieManager->set_persistent_storage($file, 'sqlite')` (or `'text'`) at
  construction, so cookies survive across runs.

### 8.8 Settings, proxy, user-agent

- `user_agent` / `set_user_agent`.
- `settings(\%kv)` -- map to `WebKitSettings` properties (kebab-cased).
- Proxy (`proxy => ...` at construction, or `set_proxy` runtime):
  `NetworkSession->set_proxy_settings('custom',
  WebKit::NetworkProxySettings->new($uri, \@ignore))` or `'no-proxy'`/`'default'`.

### 8.9 Network interception

Honest capabilities (WebKit-6.0 has no CDP-style body rewriting):

- **Block / allow / redirect** navigations and resource responses via the
  `decide-policy` signal (`WebKitPolicyDecision`: `use`/`ignore`/`download`).
  Exposed as `on_policy => sub { my ($req)=@_; $req->block / $req->allow }` with
  URI + type available.
- **Mock custom schemes** (e.g. `mock://...`): `WebContext->register_uri_scheme`
  + `URISchemeRequest->finish($stream,$len,$mime)` -- serve module-provided data.
  Exposed as `mock_scheme($scheme, $cb)`.
- **Observe** every resource via `resource-load-started` ->
  `WebKitWebResource` (`finished`/`failed`/`received-data`).
- Full arbitrary-`http`-body mocking is **out of scope for v1** (would require an
  in-process proxy the NetworkSession points at); documented as a limitation with
  the local-proxy workaround noted for a future release.

## 9. Error handling summary

| Source                        | Surfaced as                                  |
|-------------------------------|----------------------------------------------|
| `load-failed` (GError)        | `$err` to the pending `go`/`load_html` cb    |
| JS exception (eval/async fn)  | `$err` to the `script`/element cb            |
| Snapshot/PDF/cookie GError    | `$err` to that op's cb                        |
| Per-op timeout                | `$err = "timeout"`, op cancelled              |
| Stale element                 | `$err = "stale element"`                      |
| Event w/o pending cb          | global `on_error`                            |

## 10. Testing strategy

- **Fixtures without network:** `load_html` / `data:` / `file://` pages under
  `t/fixtures/` to test find/click/type/text/wait/screenshot deterministically.
- **Bridge unit tests:** JSON round-trip of scalars/arrays/objects/null; element
  handle create + stale detection.
- **Integration under Xvfb:** the test harness auto-spawns Xvfb (the module does
  this anyway); assert navigation, DOM interaction, PNG output (non-empty, PNG
  magic), cookie set/get, dialog auto-dismiss, console capture.
- **CI:** GitHub Actions, Ubuntu, `apt-get install gir1.2-webkitgtk-6.0
  gir1.2-gtk-4.0 xvfb` + cpanm deps. (FreeBSD via vmactions is a stretch goal --
  the webkit2gtk port exists.) Author's usual multi-OS matrix is reduced to
  Linux for v1 because WebKitGTK is Linux/BSD-only.
- Skip-guard tests when typelibs/Xvfb are absent (graceful `plan skip_all`).

## 11. Risks / to-verify during planning

1. Setting construct-only props (`network-session`, `user-content-manager`,
   `web-context`) via `Glib::Object::new` under GOI 0.052.
2. Exact GI name/signature of `register_script_message_handler` and the
   `script-message-received` detail (not confirmed in the typelib string scan).
3. `call_async_javascript_function` GVariant `a{sv}` argument marshalling from
   Perl via GOI.
4. Snapshot requires the WebView realized/mapped -- confirm rendering works
   headless (normal window `present()`ed under Xvfb, no OffscreenWindow).
5. Free-display-number race when spawning Xvfb (retry on collision).
6. Isolated-world eval sharing the registry across separate
   `evaluate_javascript` / `call_async_javascript_function` calls.

## 12. v1 scope boundary

**In:** auto-Xvfb (headless default) + visible override; navigation; JS eval
(sync + async); find/find_all/wait_for + full Element interaction; PNG
screenshot; **PDF export**; cookies get/set/clear + **persistent jar**;
settings/user-agent; **proxy config**; **network interception** (block/allow +
custom-scheme mock + observation); console capture; dialog handling.

**Deferred:** web-process extension (native DOM); multi-tab/view; arbitrary
http-body mocking (local proxy); downloads; media; non-Linux platforms.

## 13. Open questions for the user

- Cookie-jar default format: `sqlite` (shared with normal WebKit storage) vs
  `text` (Netscape cookies.txt, greppable). Proposed default: `sqlite`.
- Default per-op `timeout` value. Proposed: 30s.
- Should `on_console` be opt-in (perf: it injects console proxies) or on by
  default? Proposed: on only if `on_console` is supplied.
