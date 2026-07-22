# EV::WebKit Fingerprint Ceiling Hardening -- Design

**Goal:** Close the JS-layer fingerprint gaps the `network_fingerprint` work left
untouched -- canvas / AudioContext / WebGL-pixel readback hashing, the WebGL
numeric capability set, and DOM feature-presence -- so each of the four fingerprint
presets presents an interface set and a hardware-readback fingerprint consistent
with the real browser it impersonates, and does not leak the automation host's GL
stack (llvmpipe/software).

**Architecture:** All hardening is implemented as injected JS wrappers in the
existing web-process extension (`wext/evwk_fp.c`), driven by config carried in the
same GVariant `a{sv}` the coherence layer already uses. Native C hooks into the
canvas/WebGL implementations are not possible (no WebKit internals / dev headers).
The wrappers use the module's established anti-detection shape: method-shorthand
definitions (no `.prototype`), `toString` bound to the original, installed on the
interface prototype.

**Tech Stack:** C (glib/gobject, hand-declared webkit/jsc externs; built without
dev headers), Perl (`Fingerprint.pm` profile data + GVariant build, `EV/WebKit.pm`
option plumbing), injected JavaScript.

## Global Constraints

- Four presets only: `windows-chrome`, `macos-safari`, `iphone-safari`,
  `pixel-chrome`. Chrome family = has `ua_data`; Safari family = no `ua_data`.
- Must stay coherent with the existing spoof: navigator/screen native getters,
  `webgl_vendor`/`webgl_renderer` strings, `window.chrome`, `userAgentData`,
  `matchMedia`, touch/orientation. New data must not contradict it (e.g. WebGL
  caps must match the already-set renderer string; the feature set must match the
  Chrome-vs-Safari family).
- The extension is built WITHOUT webkit/jsc dev headers; new code may only use
  glib/gobject headers + the existing hand-declared `jsc_*`/`webkit_*` externs.
  No new webkit/jsc symbols beyond those already declared, unless added to the
  extern block with opaque types.
- Readback noise is OPT-IN via a `seed` integer. Absent `seed` => today's behavior
  exactly (no readback wrapping), so existing callers/tests are unaffected.
- Preserve graceful degradation: if the extension is unavailable
  (`fingerprint_available` false), none of this applies (unchanged).
- NUL-free, ASCII, no em-dashes in any user-facing string or POD (module standard).
- Author `vividsnow`; no LLM attribution in commits; keep commits local.

## Config Flow (shared plumbing, built in Phase 1)

`EV::WebKit->new(fingerprint => $profile, seed => $int)`:

1. `EV/WebKit.pm` validates `seed` (a non-negative integer; croak otherwise) and
   passes it to `Fingerprint::gvariant`.
2. `Fingerprint::gvariant` adds to the `a{sv}`:
   - `seed` => `Glib::Variant('d', $seed)` (only when defined).
   - The per-profile `webgl_params` / `webgl_extensions` / `webgl_precision`
     (Phase 2) and `features` (Phase 3) are serialized INTO the existing
     `coherence` JSON blob built by `Fingerprint::_coherence` (they are JS-layer
     config, same as `chrome`/`ua_data`/`media`), NOT as separate GVariant keys.
     `seed` is passed as its own GVariant double so the extension can read it
     without JSON.
3. The extension reads `seed` (double -> guint32) in
   `webkit_web_process_extension_initialize_with_user_data`, stores it in
   `Profile P`, and injects it into the noise JS as a number literal. The
   `coherence` JSON already reaches the JS via `__evwk_cfg`; Phases 2 and 3 read
   their blocks from that same `cfg` object.

Injection order in `on_window_object_cleared` (after the existing getters):
`NOISE_JS` (Phase 1, only if `seed` present) -> extended `WEBGL_WRAPPER_JS`
(Phase 2) -> `COHERENCE_JS` (existing) -> `FEATURES_JS` (Phase 3). Each guarded by
its config being present.

## Phase 1 -- Readback noise

**Deliverable:** seeded, session-stable, host-hiding noise on canvas/audio/WebGL
readback, opt-in via `seed`.

**Noise primitive (JS).** A pure function `noise(seed, index)` returning a small
signed integer in `{-1,0,+1}` (or 0/1 for byte channels), derived by hashing
`(seed, index)` with a fast integer mix (e.g. a mulberry32/xorshift step over
`seed ^ (index*0x9E3779B1)`). Content-INDEPENDENT: depends only on `seed` and the
element index, not the pixel/sample value.

**Properties this yields:**
- Stable within a session: the same canvas content hashed twice yields the same
  bytes (the perturbation is a fixed function of position).
- `!=` the true host output: LSBs are altered, so the hash no longer matches the
  host GL/audio stack (hides llvmpipe).
- `!=` across seeds/instances: a different `seed` gives different perturbations.

**Wrapped methods** (each: method-shorthand, `toString` bound to original,
installed on the interface prototype, delegates to the captured original):
- `CanvasRenderingContext2D.prototype.getImageData` -> call original, then
  `for i in data: data[i] ^= (noise affects LSB of R/G/B; alpha left untouched)`.
- `HTMLCanvasElement.prototype.toDataURL` and `.toBlob` -> render the source canvas
  (2D OR WebGL) onto an offscreen 2D canvas via `drawImage`, `getImageData` (real),
  perturb, `putImageData`, then call the original `toDataURL`/`toBlob` on the
  offscreen canvas so the ENCODED output carries the noise.
- `AudioBuffer.prototype.getChannelData` and `.copyFromChannel` -> add
  `noise(seed,i) * 1e-7` (relative to the sample) per sample.
- `AnalyserNode.prototype.getFloatFrequencyData` / `.getByteFrequencyData` -> add
  a tiny per-bin seed offset after the real call.
- `WebGLRenderingContext.prototype.readPixels` /
  `WebGL2RenderingContext.prototype.readPixels` -> perturb the destination
  `ArrayBufferView` bytes after the real call.

**Detectability / limits (documented residuals):**
- The wrappers are `Function.prototype.toString.call`-detectable, same ceiling as
  the existing WebGL/matchMedia wrappers.
- Content-independent noise: a script that renders a KNOWN image and reads it back
  can recover the fixed per-position perturbation and undo it. Acceptable for the
  anti-bot threat model; content-dependent (Brave-style) farbling is a future
  hardening, out of scope here.

## Phase 2 -- WebGL full capability set

**Deliverable:** `getParameter` (numeric pnames), `getSupportedExtensions`, and
`getShaderPrecisionFormat` return per-profile values matching the claimed GPU, for
both WebGL1 and WebGL2, coherent with the already-spoofed renderer string.

**Profile data (`Fingerprint.pm`), carried in the coherence JSON:**
```
webgl => {
  # WebGL1 and WebGL2 param maps: JS numeric pname (int) -> value
  # (number, [number,number], or Int32Array-like [ints])
  params1 => { 3379 => 16384, 3386 => [32767,32767], 34921 => 16, ... },
  params2 => { 32883 => 2048, 35071 => 2048, 34852 => 8, ... },  # WebGL2 extras
  extensions1 => [ "ANGLE_instanced_arrays", "EXT_blend_minmax", ... ],
  extensions2 => [ "EXT_color_buffer_float", ... ],
  # shader precision: shaderType.precisionType -> {rangeMin,rangeMax,precision}
  precision => { "FRAGMENT.HIGH_FLOAT" => [127,127,23], ... },
}
```

**Reference data per GPU family (SOURCED + cited in the plan; finalized against a
canonical WebGL report -- e.g. browserleaks.com/webgl captures -- during
implementation):**
- `windows-chrome`: ANGLE / Direct3D11 on NVIDIA (renderer already
  `ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)`).
  Representative canonical values: `MAX_TEXTURE_SIZE=16384`,
  `MAX_VIEWPORT_DIMS=[32767,32767]`, `MAX_RENDERBUFFER_SIZE=16384`,
  `MAX_VERTEX_ATTRIBS=16`, `MAX_TEXTURE_IMAGE_UNITS=16`,
  `MAX_COMBINED_TEXTURE_IMAGE_UNITS=32`, `MAX_CUBE_MAP_TEXTURE_SIZE=16384`,
  `ALIASED_LINE_WIDTH_RANGE=[1,1]`, `ALIASED_POINT_SIZE_RANGE=[1,1024]`,
  `VERSION="WebGL 1.0 (OpenGL ES 2.0 Chromium)"`,
  `SHADING_LANGUAGE_VERSION="WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)"`;
  ANGLE extension list.
- `macos-safari` / `iphone-safari`: Apple GPU (Metal); Apple's param values +
  extension list (no ANGLE-specific extensions; Apple `VERSION`/SL strings).
- `pixel-chrome`: Qualcomm Adreno 730 (OpenGL ES via ANGLE); Adreno param values +
  extension list.

**Wrapper (extends the existing `WEBGL_WRAPPER_JS`):**
- `getParameter(p)`: if `p` is UNMASKED_VENDOR/RENDERER -> existing string spoof;
  else if `p` is in this context's param map -> return the mapped value (numbers
  returned directly; vector values as the appropriate typed array / array);
  else delegate to the original.
- `getSupportedExtensions()` -> return the profile's target extension list (a fresh
  array each call).
- `getExtension(name)` wrapped so the advertised list and `getExtension` agree:
  if `name` is genuinely supported by the host GL, return the real object; else if
  `name` is in our advertised list, return a minimal stub exposing that
  extension's numeric CONSTANTS (enough for the common
  `getParameter(ext.CONSTANT)` fingerprinting pattern, e.g.
  `WEBGL_debug_renderer_info` / `EXT_texture_filter_anisotropic`); else delegate
  (returns null). Residual: a stub extension's full runtime behavior is not real
  -- a script exercising an advertised extension's actual functionality could
  detect it (documented, same class as the RTC ICE gap).
- `getShaderPrecisionFormat(shaderType, precisionType)` -> return a
  `WebGLShaderPrecisionFormat`-shaped `{rangeMin,rangeMax,precision}` from the
  profile.

**Coherence:** the caps must not contradict the renderer string. NVIDIA renderer
=> NVIDIA/ANGLE caps; Apple renderer => Apple caps.

**Residual risk:** exact capability values vary by driver/OS version; we use the
most-common canonical set per GPU family and note (POD + spec) that a
capability-level fingerprinter with a per-driver database could still find a
mismatch. This is a realism improvement, not a guarantee.

## Phase 3 -- DOM feature-presence

**Deliverable:** each profile presents the interface set the real browser exposes;
functional where feasible; never clobbers a real API.

**Profile data (`Fingerprint.pm` -> coherence JSON):** a `features` list naming
which stub groups to install, per family:
- Chrome (`windows-chrome`, `pixel-chrome`):
  `["connection","storage","battery","usb","bluetooth","hid","serial","scheduling","rtc"]`
- Safari (`macos-safari`, `iphone-safari`): `["storage","rtc"]`
  (NO connection/battery/usb/bluetooth/hid/serial -- correct; Safari lacks them.)

The EXACT per-profile list (which additional APIs real Chrome 131 / Safari 18
expose that this WebKitGTK build lacks) is enumerated in the plan from a live
capability diff (drive each real profile, list `in`-checks, subtract what
WebKitGTK already has).

**Stubs (`FEATURES_JS`, each installed only if `!(name in target)`):**
- `navigator.connection` (NetworkInformation): `{effectiveType:"4g", rtt:50,
  downlink:10, saveData:false, type:"..."/undefined, onchange:null}` + EventTarget
  methods; installed as a getter on `Navigator.prototype`.
- `navigator.storage` (StorageManager): `estimate()` -> `Promise.resolve({quota,
  usage, usageDetails:{}})`, `persist()`/`persisted()` -> Promise<bool>.
- `navigator.getBattery` (Chrome): `() -> Promise.resolve(BatteryManager-shaped
  {charging:true, chargingTime:0, dischargingTime:Infinity, level:1, on*:null} +
  EventTarget)`.
- `navigator.usb`/`bluetooth`/`hid`/`serial` (Chrome): objects with
  `getDevices() -> Promise.resolve([])`, `requestDevice()/requestPort() -> reject
  (NotFoundError/SecurityError-shaped)`, EventTarget methods.
- `navigator.scheduling` (Chrome): `{isInputPending: () => false}`.
- `window.RTCPeerConnection` (+ `webkitRTCPeerConnection` alias) (both families):
  a class with the full method shape (`createOffer`/`createAnswer`/
  `createDataChannel`/`addIceCandidate`/`setLocal|RemoteDescription`/
  `getStats`/`close`/event handlers). CAVEAT: no real ICE (no WebRTC in this
  build), so `createOffer` resolves a plausible SDP but ICE gathering yields
  nothing. Documented residual -- a WebRTC-probing fingerprinter can still detect
  the stub. (If the production WebKitGTK enables `ENABLE_WEB_RTC`, the real API is
  present and the stub is skipped by the `in`-check.)

**Coherence:** Chrome profiles get the Chrome set; Safari profiles the Safari set;
each matches its `userAgentData`/UA family. Because stubs are `in`-guarded, a build
that already ships an API keeps the real one.

## Testing (all under xvfb, following the existing t/9x style + TWK helper)

- **Phase 1** (`t/A0-readback-noise.t`, gated on `fingerprint_available`): with a
  fixed `seed`, draw a deterministic canvas, `toDataURL` twice -> IDENTICAL
  (stable); with a different `seed` -> DIFFERENT; with NO `seed` -> matches the raw
  host output (noise off) and differs from the seeded output. Repeat for
  `getImageData`, `AudioBuffer.getChannelData` (a rendered OfflineAudioContext),
  and WebGL `readPixels`. Assert the canvas still renders (a known solid-fill
  reads back the fill color +/- 1, i.e. noise is LSB-only).
- **Phase 2** (`t/A1-webgl-caps.t`): for each profile, read `getParameter` for the
  key pnames + `getSupportedExtensions` + `getShaderPrecisionFormat`; assert they
  equal the profile's expected set and are coherent with `UNMASKED_RENDERER`.
  Negative control: a non-fingerprint browser reports the host's real caps.
- **Phase 3** (`t/A2-features.t`): per profile assert the expected interface set
  (`'connection' in navigator` true for Chrome / false for Safari;
  `'RTCPeerConnection' in window` true for both; `usb`/`bluetooth` present only for
  Chrome) AND basic functionality (`connection.effectiveType`,
  `await storage.estimate()`, `await getBattery()`), and that a real WebKitGTK API
  is NOT clobbered (a stub is skipped when the API already exists).
- The existing coherence suite (`t/96` live, `t/97`, `t/98`, `t/99`) stays green:
  the seed/caps/features must not disturb navigator/screen/UA/media/network
  coherence.

## Coherence + documented residuals (POD `Ceiling` update)

The ceiling POD is updated to reflect the new state: canvas/audio/WebGL readback
is now seeded-noised (opt-in via `seed`), WebGL capabilities match the claimed GPU
family, and the DOM interface set matches the claimed browser -- with these honest
residuals: the wrappers remain `Function.prototype.toString.call`-detectable;
content-independent noise is undoable by a known-image probe; WebGL caps are
canonical-per-family (a per-driver database could still mismatch); and
`RTCPeerConnection` cannot perform real ICE.

## Build / packaging

- `wext/evwk_fp.c` grows (new wrapper JS strings + seed field + config parsing).
  No new build dependency; still compiles without dev headers.
- `Fingerprint.pm` presets gain `webgl` + `features` data and (via `gvariant`) the
  `seed` passthrough; `resolve` validates the new fields; `_coherence` folds
  `webgl`/`features` into the JSON.
- `EV/WebKit.pm`: `seed` in `%KNOWN_NEW`, validated, plumbed to `gvariant`.
- New tests added to MANIFEST; Changes updated.
