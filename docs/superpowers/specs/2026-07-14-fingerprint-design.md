# EV::WebKit fingerprint spoofing (device profiles) -- design

Date: 2026-07-14
Status: approved, ready for an implementation plan

## Problem

A page can read a large set of JavaScript-exposed properties (`navigator.*`,
`screen.*`, WebGL `getParameter`) to fingerprint the browser and detect that it
is an automated/atypical environment. `EV::WebKit` can already spoof the
User-Agent, but the UA then conflicts with the real `navigator.platform`, GPU
string, screen size, etc. -- which fingerprinters (amiunique, whatismybrowser,
CreepJS) flag as an inconsistency. A prior investigation established that:

- pure-JS `Object.defineProperty` overrides are **toString-detectable** (a JS
  getter's `.toString()` returns its source, not `[native code]`), an unwinnable
  arms race; and
- a **C web-process extension (injected bundle)** installs NATIVE property
  accessors that report `[native code]` and cannot be distinguished from the
  engine's own -- PROVEN end-to-end by a spike (`navigator.platform` returned
  `Win32` and `getter.toString()` was `function get() { [native code] }`).

This feature makes a browser instance present as a chosen, internally-coherent
real device at the JavaScript-property layer, using that proven approach.

## Ceiling (stated honestly, in code and POD)

The native-getter approach covers the JS-property layer: `navigator`, `screen`,
`devicePixelRatio`, and WebGL vendor/renderer strings. It CANNOT touch
canvas/WebGL-*pixel* hashes, AudioContext hashes, or network-layer fingerprints
(TLS JA3, HTTP/2), which live below the JSC layer. A determined fingerprinter
that hashes a canvas or inspects the TLS handshake will still detect a mismatch.
This feature defeats the JS-property + toString vectors, not everything, and a
self-consistent *custom* profile is the caller's responsibility.

## Approach

The approach (injected C bundle) is settled -- it is the whole premise of the
feature and the alternative (pure-JS) was rejected in the investigation. One
`.so`, loaded into the web process, serves ANY profile: the device profile is
passed at runtime as a GVariant, so there are no per-profile rebuilds.

## API

Construct-time only. WebKit requires the web-process-extension directory and its
initialization user-data to be set BEFORE the web process spawns (before the
first navigation), so the device is fixed for the instance's life -- use a fresh
instance for a different device (documented limitation).

```perl
# a preset by name
my $b = EV::WebKit->new(fingerprint => 'windows-chrome');

# a preset as a base, with per-field overrides
my $b = EV::WebKit->new(fingerprint => {
    profile      => 'windows-chrome',
    screen       => [1920, 1080],
    deviceMemory => 16,
});

EV::WebKit::fingerprint_available();   # was the .so built at install?
EV::WebKit->fingerprint_profiles;      # list of preset names
$b->fingerprint;                       # the resolved profile (read-only hashref), or undef
```

### Presets

An initial set of coherent real-device profiles: `windows-chrome`,
`macos-safari`, `iphone-safari`, `pixel-chrome`. Each declares the fields that
device actually exposes (see the sparse-profile rule below):

- `user_agent`, `platform`, `vendor`, `languages` (arrayref),
  `hardwareConcurrency`, `deviceMemory`, `maxTouchPoints`,
  `screen` (`[width, height]`, plus optional `avail`/`colorDepth`),
  `devicePixelRatio`, `webgl_vendor`, `webgl_renderer`.

### The sparse-profile rule (coherence)

A profile overrides ONLY the fields it declares; the `.so` installs a native
getter ONLY for declared fields. So a Safari preset that omits `deviceMemory`
leaves `navigator.deviceMemory` as `undefined` (as on a real Mac), rather than
inventing a property the real device lacks. The GVariant carries only the
present keys; the C side installs conditionally.

### UA coherence

The profile's `user_agent` drives WebKit's existing native `set_user_agent`,
which coherently sets BOTH the HTTP `User-Agent` header AND `navigator.userAgent`
-- so the `.so` never overrides `userAgent`. Passing both `fingerprint` and the
separate `user_agent` constructor option croaks (they would conflict); override
the UA through the profile instead (`fingerprint => { ..., user_agent => ... }`).

### Errors (all fail-loud)

- `fingerprint =>` with no `.so` built -> croak, pointing at
  `fingerprint_available()`.
- unknown preset name -> croak listing valid names.
- `fingerprint` + `user_agent` together -> croak.
- override with an unknown field key or a wrong-typed value -> croak.
- a runtime failure wiring the extension directory or init user-data in `new()`
  -> croak (never a silent non-spoof).

## The C extension (`wext/evwk_fp.c` -> `evwk_fp.so`)

Entry point `webkit_web_process_extension_initialize_with_user_data(ext,
GVariant *profile)`: parse the GVariant -- a dict `a{sv}` carrying only the
present keys, values typed per field (string, int32, double, or string-array for
`languages`) -- into a C struct held for the process's life, then
`g_signal_connect(webkit_script_world_get_default(), "window-object-cleared",
cb, struct)`. The callback (document-start, all frames) gets the frame's
JSCContext for the default world and installs native accessors via
`jsc_value_object_define_property_accessor` (CONFIGURABLE, correct GType),
reading from the struct:

- `navigator.{platform, vendor, languages, hardwareConcurrency, deviceMemory,
  maxTouchPoints}`
- `screen.{width, height, availWidth, availHeight, colorDepth, pixelDepth}`
- `devicePixelRatio`

WebGL is the one non-property case: `getParameter` is a method, so the `.so`
replaces `WebGLRenderingContext.prototype.getParameter` and
`WebGL2RenderingContext.prototype.getParameter` with a native function that
returns `webgl_vendor`/`webgl_renderer` for pnames `UNMASKED_VENDOR_WEBGL`
(0x9245) / `UNMASKED_RENDERER_WEBGL` (0x9246) and delegates to the retained
original for every other pname. Same native `[native code]` result, a little
more JSC plumbing.

Built WITHOUT webkit/jsc dev headers (as the spike was): the handful of
webkit/jsc functions are hand-declared with opaque types and left unresolved at
link time (`-Wl,--unresolved-symbols=ignore-all`); they resolve at dlopen inside
the web process, which already has libwebkitgtk/libjavascriptcore loaded.
glib/gobject come from real headers via pkg-config.

## Build (Makefile.PL)

Detect `cc` (`$Config{cc}`) and `pkg-config --exists gobject-2.0 glib-2.0`. If
present, compile:

```
cc -shared -fPIC -o <dest>/evwk_fp.so wext/evwk_fp.c \
   $(pkg-config --cflags --libs gobject-2.0 glib-2.0) \
   -Wl,--unresolved-symbols=ignore-all
```

and install the `.so` into a DEDICATED share subdir that holds only it (so it can
be pointed at directly as the extensions directory). If the toolchain is absent,
`warn` and skip -- the module installs and stays fully usable; only fingerprint
is unavailable. At runtime the module locates that dir via `File::ShareDir` and
passes it to `set_web_process_extensions_directory` in `new()`, together with the
profile GVariant via `set_web_process_extensions_initialization_user_data`,
before the first navigation.

## Runtime wiring (lib/EV/WebKit.pm, thin)

In `new()`, when `fingerprint =>` is given: resolve+validate the profile via
`EV::WebKit::Fingerprint`, croak on the error conditions above, then after the
`WebContext` is created and before the first navigation call
`set_web_process_extensions_directory($dir)` and
`set_web_process_extensions_initialization_user_data($gvariant)`. Store the
resolved profile for `$b->fingerprint`. `fingerprint_available`,
`fingerprint_profiles`, and `$b->fingerprint` delegate to `Fingerprint`.

## File structure

- `wext/evwk_fp.c` -- the extension source (compiled at install).
- `lib/EV/WebKit/Fingerprint.pm` -- preset table, profile resolution +
  validation, GVariant construction, `available()`. One cohesive unit; keeps
  this out of the already-large `WebKit.pm`.
- `lib/EV/WebKit.pm` -- the thin `new()` hooks + delegating accessors.
- `Makefile.PL` -- compile + install the `.so`, degrade gracefully.
- `t/99-fingerprint.t` -- tests, `skip_all` when `fingerprint_available()` is
  false.

## The one un-spiked risk -- spike it FIRST

The spike proved the C-side native override end-to-end but HARDCODED the value;
it never passed a profile from Perl. The path "Perl builds a GVariant from the
profile hash -> `$context->set_web_process_extensions_initialization_user_data(
$gv)` -> C parses it in `initialize_with_user_data`" is a design assumption, not
yet proven. The implementation plan's FIRST task is a minimal end-to-end spike of
exactly this (build a small typed GVariant in Perl, read one field back from C,
navigate, confirm the value reached a native getter) so we fail fast if GI's
GVariant marshalling or the init-user-data call cannot express it. Only after
that spike passes does the full feature get built.

## Testing

Under `xvfb-run`; `plan skip_all` when `fingerprint_available()` is false (CI
without a toolchain, or a platform where the build was skipped).

- Preset applied: load a `mock_scheme` page, `script()` the spoofed
  `navigator.platform`/`vendor`/`hardwareConcurrency`/`screen.width`/
  `devicePixelRatio` and assert the profile's values.
- **Native, not JS (the whole point):** assert
  `Object.getOwnPropertyDescriptor(navigator,'platform').get.toString()`
  contains `[native code]`.
- WebGL: `canvas.getContext('webgl').getExtension('WEBGL_debug_renderer_info')`
  then `getParameter(UNMASKED_RENDERER_WEBGL)` returns the profile's renderer,
  and `getParameter.toString()` is `[native code]`; a non-spoofed pname still
  returns a real value (delegation works).
- Sparse rule: a preset that omits `deviceMemory` leaves `navigator.deviceMemory`
  `undefined`.
- UA coherence: `navigator.userAgent` matches the profile UA (via the existing
  `set_user_agent` path).
- Overrides: a preset + `{ screen => [w,h] }` reports the overridden screen.
- Errors: unknown preset, `fingerprint`+`user_agent`, unknown override key, and
  bad override type each croak; on a build without the `.so`,
  `fingerprint_available()` is false and `fingerprint =>` croaks.

## Not in scope

Canvas/audio/TLS spoofing (below the JSC layer -- the stated ceiling). Runtime
device switching (construct-time only). A large preset catalogue (start with the
four; more are just data). `navigator.userAgentData`/Client-Hints, plugins, and
the connection API (deferred; Core+WebGL coverage chosen). Automatic coherence
checking of custom overrides (type-validated only).
