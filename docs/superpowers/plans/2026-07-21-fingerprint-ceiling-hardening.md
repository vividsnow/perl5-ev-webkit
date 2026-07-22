# Fingerprint Ceiling Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the JS-layer fingerprint gaps the `network_fingerprint` work left untouched -- seeded canvas / AudioContext / WebGL-pixel readback noise, the WebGL numeric capability set, and DOM feature-presence -- so each of the four presets presents an interface set and a hardware-readback fingerprint consistent with the browser it impersonates, and hides the automation host's GL stack (llvmpipe).

**Architecture:** All hardening is injected JavaScript in the existing web-process extension (`wext/evwk_fp.c`), driven by config carried in the same GVariant `a{sv}` the coherence layer already uses. Readback noise is opt-in via a new `seed` integer passed as its own GVariant double; WebGL caps and feature lists ride inside the existing `coherence` JSON blob. The wrappers use the module's established anti-detection shape: method-shorthand definitions (no `.prototype`), `toString` bound to the original, installed on the interface prototype.

**Tech Stack:** C (glib/gobject, hand-declared webkit/jsc externs; built without dev headers), Perl (`Fingerprint.pm` profile data + GVariant build, `EV/WebKit.pm` option plumbing), injected JavaScript, Test::More under `xvfb-run`.

## Global Constraints

- Four presets only: `windows-chrome`, `macos-safari`, `iphone-safari`, `pixel-chrome`. Chrome family = has `ua_data`; Safari family = no `ua_data`.
- New data must not contradict the existing spoof: WebGL caps must match the already-set `webgl_renderer` string; the feature set must match the Chrome-vs-Safari family and the platform (desktop vs Android).
- The extension is built WITHOUT webkit/jsc dev headers; new code may only use glib/gobject headers + the existing hand-declared `jsc_*`/`webkit_*` externs. No new webkit/jsc symbols. Inject dynamic values (the seed literal) via `g_strdup_printf` into the JS source -- do NOT introduce a `jsc_value_new_number` extern.
- Readback noise is OPT-IN via a `seed` integer. Absent `seed` => today's behavior exactly (no readback wrapping). `seed` requires `fingerprint` (the extension that injects it only loads with a profile).
- Preserve graceful degradation: if `fingerprint_available` is false, none of this applies.
- NUL-free, ASCII, no em-dashes in any user-facing string or POD. Use `--` not the em-dash character.
- Commit author `vividsnow` / `vividsnow@pm.me` via `git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit`. No Co-Authored-By, no LLM attribution. Keep commits local (do not push).
- Never use `sed`; use the Edit tool or a Perl one-liner. Never monkeypatch GObject-Introspection methods.
- Build/test under `xvfb-run -a`. Rebuild the extension after editing `wext/evwk_fp.c` with `perl Makefile.PL && make` (this reruns `build_wext`, recompiling `share/wext/evwk_fp.so` and copying it into `blib`, which the tests' `_so_dir` resolves first).

## File Structure

- `lib/EV/WebKit.pm` -- MODIFY. Constructor: add `seed` to `%KNOWN_NEW`, validate it, plumb to `Fingerprint::gvariant`. POD: document `seed`, rewrite the `Ceiling` paragraph. Bump `$VERSION`.
- `lib/EV/WebKit/Fingerprint.pm` -- MODIFY. Add per-preset `webgl` + `features` data; add `webgl`/`features` validators to `%FIELD` + `resolve`; fold both into the `_coherence` JSON; add the `seed` param to `gvariant`.
- `wext/evwk_fp.c` -- MODIFY. Add `seed` to `Profile` + GVariant parse; add `NOISE_JS` (Phase 1); extend `WEBGL_WRAPPER_JS` to read `cfg.webgl` (Phase 2); add `FEATURES_JS` (Phase 3); rework `__evwk_cfg` lifetime so the WebGL wrapper can read `cfg` before `COHERENCE_JS`, with a single C-side final delete.
- `t/99-fingerprint.t` -- MODIFY (pure-Perl assertions for seed plumbing + webgl/features data + validation).
- `t/A0-readback-noise.t` -- CREATE (Phase 1, live under xvfb).
- `t/A1-webgl-caps.t` -- CREATE (Phase 2, live under xvfb).
- `t/A2-features.t` -- CREATE (Phase 3, live under xvfb).
- `MANIFEST` -- MODIFY (add the three new test files).
- `Changes` -- MODIFY (0.03 entry).

**Task order:** 1 (seed Perl) -> 2 (Phase 1a: seed C + noise primitive + canvas) -> 3 (Phase 1b: audio + readPixels) -> 4 (Phase 2a: webgl data) -> 5 (Phase 2b: webgl wrapper) -> 6 (Phase 3a: features data) -> 7 (Phase 3b: features JS) -> 8 (docs + packaging). Tasks 1, 4, 6 are pure-Perl (no browser). Tasks 2, 3, 5, 7 are live (xvfb).

---

### Task 1: `seed` option plumbing (Perl)

**Files:**
- Modify: `lib/EV/WebKit.pm:172-178` (`%KNOWN_NEW`), after `:196` (validation), `:365` (gvariant call)
- Modify: `lib/EV/WebKit/Fingerprint.pm:208-231` (`gvariant`)
- Test: `t/99-fingerprint.t` (append)

**Interfaces:**
- Produces: `EV::WebKit::Fingerprint::gvariant($resolved_profile, $seed)` -- `$seed` optional; when defined (a non-negative integer), the returned `a{sv}` GVariant carries `seed => Glib::Variant('d', $seed)`. `EV::WebKit->new(fingerprint => ..., seed => $int)` validates `$int` and forwards it.

- [ ] **Step 1: Write the failing test** -- append to `t/99-fingerprint.t` (before the final `done_testing;`):

```perl
# --- seed plumbing (pure Perl) ---
my $gv_seed = EV::WebKit::Fingerprint::gvariant(
    EV::WebKit::Fingerprint::resolve('windows-chrome'), 12345);
like($gv_seed->print(1), qr/'seed'/, 'gvariant carries seed when given');
my $gv_noseed = EV::WebKit::Fingerprint::gvariant(
    EV::WebKit::Fingerprint::resolve('windows-chrome'));
unlike($gv_noseed->print(1), qr/'seed'/, 'gvariant omits seed when not given');

eval { EV::WebKit->new(window => [200,150], fingerprint => 'windows-chrome', seed => -1) };
like($@, qr/seed must be a non-negative integer/, 'negative seed croaks');
eval { EV::WebKit->new(window => [200,150], fingerprint => 'windows-chrome', seed => 'x') };
like($@, qr/seed must be a non-negative integer/, 'non-integer seed croaks');
eval { EV::WebKit->new(window => [200,150], seed => 5) };
like($@, qr/seed requires fingerprint/, 'seed without fingerprint croaks');
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xvfb-run -a make test TEST_FILES=t/99-fingerprint.t`
Expected: FAIL -- `gvariant` ignores the 2nd arg (no `'seed'` in output) and `new` does not know `seed` (croaks "unknown option(s): seed", not the expected messages).

- [ ] **Step 3: Add `seed` to `%KNOWN_NEW`** -- `lib/EV/WebKit.pm`, change the qw list (currently ends `fingerprint network_fingerprint`):

```perl
    fingerprint network_fingerprint seed
```

- [ ] **Step 4: Validate `seed` in `new`** -- in `lib/EV/WebKit.pm`, immediately AFTER the `if (defined $o{fingerprint}) { ... }` block (the line with `$fp = EV::WebKit::Fingerprint::resolve($o{fingerprint});` and its closing `}`, around line 196), insert:

```perl
    if (defined $o{seed}) {
        Carp::croak('EV::WebKit: seed must be a non-negative integer')
            unless !ref $o{seed} && $o{seed} =~ /\A\d+\z/;
        Carp::croak('EV::WebKit: seed requires fingerprint => <profile>') unless $fp;
    }
```

- [ ] **Step 5: Forward `seed` to `gvariant`** -- in `lib/EV/WebKit.pm:365`, change:

```perl
        $context->set_web_process_extensions_initialization_user_data(EV::WebKit::Fingerprint::gvariant($fp));
```
to:
```perl
        $context->set_web_process_extensions_initialization_user_data(EV::WebKit::Fingerprint::gvariant($fp, $o{seed}));
```

- [ ] **Step 6: Accept + carry `seed` in `gvariant`** -- in `lib/EV/WebKit/Fingerprint.pm`, change the sub signature `sub gvariant { my ($p) = @_;` to `sub gvariant { my ($p, $seed) = @_;` and, just before the `_coherence` block (before `if (my $coh = _coherence($p)) {`), insert:

```perl
    # Readback-noise seed (opt-in). Passed as its own double so the extension can
    # read it without parsing the coherence JSON; folded to guint32 in C.
    $d{seed} = Glib::Variant->new('d', $seed + 0) if defined $seed;
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `xvfb-run -a make test TEST_FILES=t/99-fingerprint.t`
Expected: PASS (all new assertions green; existing ones unchanged).

- [ ] **Step 8: Commit**

```bash
git -c user.name=vividsnow -c user.email=vividsnow@pm.me add lib/EV/WebKit.pm lib/EV/WebKit/Fingerprint.pm t/99-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: seed option plumbing for readback noise"
```

---

### Task 2: Phase 1a -- extension seed parse + noise primitive + canvas noise

**Files:**
- Modify: `wext/evwk_fp.c` (Profile struct `:132-139`, GVariant parse `:251-260`, new `NOISE_JS` string, injection in `on_window_object_cleared` `:171-235`)
- Test: `t/A0-readback-noise.t` (create)

**Interfaces:**
- Consumes: `gvariant(..., $seed)` from Task 1 (the `seed` double in the `a{sv}`).
- Produces: when `seed` is present, `CanvasRenderingContext2D.prototype.getImageData`, `HTMLCanvasElement.prototype.toDataURL`, and `HTMLCanvasElement.prototype.toBlob` return content-independent, seed-stable, host-hiding output. `NOISE_JS` exposes a global-free IIFE; a later task extends it (audio + readPixels).

- [ ] **Step 1: Write the failing test** -- create `t/A0-readback-noise.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit; use EV::WebKit::Fingerprint;
plan skip_all => 'web-process extension not built' unless EV::WebKit::Fingerprint::available();

# Drive a data: canvas in the web process and return a JSON blob of readback probes.
sub probe {
    my (%opt) = @_;                       # seed => N (or none)
    my $b = EV::WebKit->new(window => [200,150], fingerprint => 'windows-chrome', %opt);
    $b->mock_scheme('fp', sub { ('<html><body></body></html>','text/html') });
    my $out;
    $b->go('fp://host/p', sub {
        $b->script(<<'JS', sub { $out = $_[0]; EV::break });
          var c = document.createElement('canvas'); c.width=32; c.height=32;
          var g = c.getContext('2d');
          g.fillStyle = '#4080c0'; g.fillRect(0,0,32,32);
          var d1 = g.getImageData(0,0,32,32).data;
          var url1 = c.toDataURL();
          var url2 = c.toDataURL();               // same content -> must equal url1
          // sample the fill pixel (LSB-only: within 1 of the true channel)
          return JSON.stringify({ url1:url1, url2:url2, r:d1[0], g:d1[1], b:d1[2], a:d1[3] });
JS
    });
    TWK::run_with_timeout(20);
    $b->quit;
    require Cpanel::JSON::XS; return Cpanel::JSON::XS::decode_json($out // '{}');
}

my $s1 = probe(seed => 111);
my $s1b = probe(seed => 111);
my $s2 = probe(seed => 222);
my $none = probe();

ok($s1->{url1} eq $s1->{url2}, 'same seed, same content: toDataURL is stable within a call');
is($s1->{url1}, $s1b->{url1}, 'same seed across instances: identical encoded output');
isnt($s1->{url1}, $s2->{url1}, 'different seed: different encoded output');
isnt($s1->{url1}, $none->{url1}, 'seeded output differs from the un-noised host output');
# LSB-only: fill was #4080c0 = (64,128,192); each channel within 1 of the truth.
ok(abs($s1->{r}-64) <= 1 && abs($s1->{g}-128) <= 1 && abs($s1->{b}-192) <= 1,
   'getImageData noise is LSB-only (canvas still renders the fill)');
is($s1->{a}, 255, 'alpha channel is never perturbed');

done_testing;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES=t/A0-readback-noise.t`
Expected: FAIL -- with no noise wired, `isnt($s1->{url1}, $none->{url1})` fails (seeded == un-noised) and `isnt($s1->{url1}, $s2->{url1})` fails (seed ignored).

- [ ] **Step 3: Add `seed` to the `Profile` struct** -- in `wext/evwk_fp.c`, in the `typedef struct { ... } Profile;` (lines 132-139), add to the flag/number group:

```c
    gboolean has_seed; guint32 seed;
```

- [ ] **Step 4: Parse `seed` from the GVariant** -- in `webkit_web_process_extension_initialize_with_user_data`, after the `screen_pixelDepth` lookup (line 260), add:

```c
        if (g_variant_lookup (ud, "seed", "d", &d)) { P.has_seed = TRUE; P.seed = (guint32) d; }
```

- [ ] **Step 5: Add the `NOISE_JS` string** -- in `wext/evwk_fp.c`, after the `WEBGL_WRAPPER_JS` definition (after line 61), add a `printf`-template string (one `%u` for the seed literal). The noise is a content-INDEPENDENT function of `(seed, index)` -- so re-reading the same canvas is stable, but the LSBs no longer match the host GL/audio output:

```c
/* Readback noise (opt-in via seed). A content-INDEPENDENT per-index perturbation:
 * noise(i) depends only on the seed and the element index, so re-hashing the same
 * pixels is stable within a session, yet the LSBs no longer match the true host
 * output (hides llvmpipe). Only the seed literal is interpolated (%u); everything
 * else is fixed JS. Canvas 2D getImageData/toDataURL/toBlob are wrapped here;
 * audio + WebGL readPixels are added in a later task by extending this IIFE. */
static const char *NOISE_JS_TMPL =
    "(function(){"
    "  var SEED=%u>>>0;"
    "  function nz(i){"                              /* mulberry32 step -> 0 or 1 */
    "    var t=(SEED + Math.imul(i,0x6D2B79F5))|0;"
    "    t=Math.imul(t ^ (t>>>15), t|1);"
    "    t ^= t + Math.imul(t ^ (t>>>7), t|61);"
    "    return ((t ^ (t>>>14))>>>0) & 1; }"
    "  function bind(w,orig){ try{ w.toString=orig.toString.bind(orig); }catch(e){} return w; }"
    "  function perturbRGBA(data){"                  /* toggle LSB of R,G,B; leave A */
    "    for(var i=0;i<data.length;i+=4){ data[i]^=nz(i); data[i+1]^=nz(i+1); data[i+2]^=nz(i+2); }"
    "    return data; }"
    "  var C2 = window.CanvasRenderingContext2D && window.CanvasRenderingContext2D.prototype;"
    "  if(C2 && C2.getImageData){"
    "    var gid=C2.getImageData;"
    "    C2.getImageData=bind(({ getImageData(){ var im=gid.apply(this,arguments); perturbRGBA(im.data); return im; } }).getImageData, gid);"
    "  }"
    "  var HC = window.HTMLCanvasElement && window.HTMLCanvasElement.prototype;"
    "  function noisyCopy(canvas){"                  /* offscreen 2D copy carrying noise; covers 2D AND WebGL sources */
    "    var w=canvas.width, h=canvas.height, off=document.createElement('canvas');"
    "    off.width=w; off.height=h; var octx=off.getContext('2d');"
    "    octx.drawImage(canvas,0,0);"
    "    var im=gid.call(octx,0,0,w,h);"             /* ORIGINAL getImageData -> no double-noise */
    "    perturbRGBA(im.data); octx.putImageData(im,0,0); return off; }"
    "  if(HC && HC.toDataURL){"
    "    var tdu=HC.toDataURL;"
    "    HC.toDataURL=bind(({ toDataURL(){ try{ return tdu.apply(noisyCopy(this),arguments); }catch(e){ return tdu.apply(this,arguments); } } }).toDataURL, tdu);"
    "  }"
    "  if(HC && HC.toBlob){"
    "    var tb=HC.toBlob;"
    "    HC.toBlob=bind(({ toBlob(){ try{ return tb.apply(noisyCopy(this),arguments); }catch(e){ return tb.apply(this,arguments); } } }).toBlob, tb);"
    "  }"
    "})();";
```

Note: `nz`, `bind`, `perturbRGBA`, and `noisyCopy` are locals of this IIFE. Task 3 extends the SAME IIFE (inserting before the closing `})();`), so it reaches them directly -- no window globals are exposed.

- [ ] **Step 6: Inject `NOISE_JS` when a seed is present** -- in `on_window_object_cleared`, BEFORE the `if (P.webgl_vendor || P.webgl_renderer)` block (before line 210), add:

```c
    if (P.has_seed) {
        char *js = g_strdup_printf (NOISE_JS_TMPL, (unsigned) P.seed);
        JSCValue *r = jsc_context_evaluate (ctx, js, -1);
        if (r) g_object_unref (r);
        g_free (js);
    }
```

- [ ] **Step 7: Rebuild and run the test to verify it passes**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES=t/A0-readback-noise.t`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git -c user.name=vividsnow -c user.email=vividsnow@pm.me add wext/evwk_fp.c t/A0-readback-noise.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: seeded canvas readback noise (getImageData/toDataURL/toBlob)"
```

---

### Task 3: Phase 1b -- audio + WebGL readPixels noise

**Files:**
- Modify: `wext/evwk_fp.c` (extend `NOISE_JS_TMPL` before its closing IIFE)
- Test: `t/A0-readback-noise.t` (append)

**Interfaces:**
- Consumes: Task 2's `NOISE_JS_TMPL` IIFE -- this task inserts more wrappers into the SAME IIFE, reaching its in-scope `nz`/`bind` locals (no window globals).
- Produces: `AudioBuffer.prototype.getChannelData`/`.copyFromChannel`, `AnalyserNode.prototype.getFloatFrequencyData`/`.getByteFrequencyData`, and `WebGLRenderingContext`/`WebGL2RenderingContext` `.prototype.readPixels` return seeded, host-hiding readback.

- [ ] **Step 1: Write the failing test** -- append to `t/A0-readback-noise.t` (before `done_testing;`), covering audio + WebGL readPixels:

```perl
# --- audio + webgl readPixels ---
# NB: EV::WebKit::script wraps the body in `await (async()=>{ ... })()` and
# JSON-stringifies the returned value -- so the body uses `return await`, NOT a
# trailing done-callback.
sub probe_av {
    my (%opt) = @_;
    my $b = EV::WebKit->new(window => [200,150], fingerprint => 'windows-chrome', %opt);
    $b->mock_scheme('fp', sub { ('<html><body></body></html>','text/html') });
    my $out;
    $b->go('fp://host/p', sub {
        $b->script(<<'JS', sub { $out = $_[0]; EV::break });
          const res = { hasAudio:false, hasGL:false, audio:null, px:[0,0,0,0], pxhash:0 };
          const OAC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
          if (OAC) {
            res.hasAudio = true;
            const ac = new OAC(1, 4096, 44100);
            const osc = ac.createOscillator(); osc.type='triangle'; osc.frequency.value=440;
            osc.connect(ac.destination); osc.start(0);
            const buf = await ac.startRendering();
            const ch = buf.getChannelData(0);
            let sum = 0; for (let i=0;i<ch.length;i++) sum += Math.abs(ch[i]);
            res.audio = sum;
          }
          const cv = document.createElement('canvas'); cv.width=8; cv.height=8;
          const gl = cv.getContext('webgl') || cv.getContext('experimental-webgl');
          if (gl) { res.hasGL = true; gl.clearColor(0.25,0.5,0.75,1); gl.clear(gl.COLOR_BUFFER_BIT);
                    const b2 = new Uint8Array(8*8*4); gl.readPixels(0,0,8,8,gl.RGBA,gl.UNSIGNED_BYTE,b2);
                    res.px = [b2[0],b2[1],b2[2],b2[3]];
                    let s=0; for (let i=0;i<b2.length;i++) s=(Math.imul(s,31)+b2[i])>>>0; res.pxhash=s; }  // position-weighted hash: robust cross-seed compare
          return JSON.stringify(res);
JS
    });
    TWK::run_with_timeout(25);
    $b->quit;
    require Cpanel::JSON::XS; return Cpanel::JSON::XS::decode_json($out // '{}');
}

my $a1 = probe_av(seed => 111);
my $a1b = probe_av(seed => 111);
my $a2 = probe_av(seed => 222);
my $an = probe_av();
SKIP: {
    skip 'no Web Audio in this build', 3 unless $a1->{hasAudio};
    is($a1->{audio}, $a1b->{audio}, 'audio hash stable for a fixed seed');
    isnt($a1->{audio}, $a2->{audio}, 'audio hash differs across seeds');
    isnt($a1->{audio}, $an->{audio}, 'seeded audio hash differs from the host output');
}
SKIP: {
    skip 'no WebGL in this build', 3 unless $a1->{hasGL};
    # clear was (0.25,0.5,0.75) = (64,128,191); LSB-only after readPixels noise.
    ok(abs($a1->{px}[0]-64) <= 1 && abs($a1->{px}[1]-128) <= 1 && abs($a1->{px}[2]-191) <= 2,
       'readPixels noise is LSB-only (still the clear color)');
    isnt($a1->{pxhash}, $a2->{pxhash}, 'readPixels differs across seeds (whole-buffer hash)');
    is($a1->{px}[3], 255, 'readPixels alpha not perturbed');
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES=t/A0-readback-noise.t`
Expected: FAIL -- audio + readPixels are un-noised, so `isnt(...host...)` and cross-seed assertions fail.

- [ ] **Step 3: Extend `NOISE_JS_TMPL` with audio + readPixels** -- in `wext/evwk_fp.c`, insert these blocks into `NOISE_JS_TMPL` immediately BEFORE the closing `"})();";` line (same IIFE, so `nz`/`bind` are in scope):

```c
    "  function sgn(i){ return nz(i) ? 1 : -1; }"
    "  var AB = window.AudioBuffer && window.AudioBuffer.prototype;"
    "  if(AB && AB.getChannelData){"
    "    var seen = new WeakSet();"                  /* perturb a live channel at most once -> stable */
    "    var gcd=AB.getChannelData;"
    "    AB.getChannelData=bind(({ getChannelData(){ var a=gcd.apply(this,arguments);"
    "      if(!seen.has(a)){ seen.add(a); for(var i=0;i<a.length;i++) a[i]+=sgn(i)*1e-7; } return a; } }).getChannelData, gcd);"
    "    if(AB.copyFromChannel){ var cfc=AB.copyFromChannel;"
    "      AB.copyFromChannel=bind(({ copyFromChannel(dst){ cfc.apply(this,arguments); for(var i=0;i<dst.length;i++) dst[i]+=sgn(i)*1e-7; } }).copyFromChannel, cfc); }"
    "  }"
    "  var AN = window.AnalyserNode && window.AnalyserNode.prototype;"
    "  if(AN){"
    "    if(AN.getFloatFrequencyData){ var gff=AN.getFloatFrequencyData;"
    "      AN.getFloatFrequencyData=bind(({ getFloatFrequencyData(a){ gff.apply(this,arguments); for(var i=0;i<a.length;i++) a[i]+=sgn(i)*1e-4; } }).getFloatFrequencyData, gff); }"
    "    if(AN.getByteFrequencyData){ var gbf=AN.getByteFrequencyData;"
    "      AN.getByteFrequencyData=bind(({ getByteFrequencyData(a){ gbf.apply(this,arguments); for(var i=0;i<a.length;i++){ var v=a[i]^nz(i); a[i]=v; } } }).getByteFrequencyData, gbf); }"
    "  }"
    "  function patchRP(proto){"
    "    if(!proto||!proto.readPixels) return; var rp=proto.readPixels;"
    "    proto.readPixels=bind(({ readPixels(x,y,w,h,fmt,type,dst){ rp.apply(this,arguments);"
    "      if(dst && dst.BYTES_PER_ELEMENT===1){ for(var i=0;i<dst.length;i+=4){ dst[i]^=nz(i); dst[i+1]^=nz(i+1); dst[i+2]^=nz(i+2); } } } }).readPixels, rp); }"
    "  patchRP(window.WebGLRenderingContext && window.WebGLRenderingContext.prototype);"
    "  patchRP(window.WebGL2RenderingContext && window.WebGL2RenderingContext.prototype);"
```

- [ ] **Step 4: Rebuild and run the test to verify it passes**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES=t/A0-readback-noise.t`
Expected: PASS (audio stable-per-seed + differs across seeds/host; readPixels LSB-only + seed-varying when GL present).

- [ ] **Step 5: Commit**

```bash
git -c user.name=vividsnow -c user.email=vividsnow@pm.me add wext/evwk_fp.c t/A0-readback-noise.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: seeded audio + WebGL readPixels readback noise"
```

---

### Task 4: Phase 2a -- WebGL capability data (Fingerprint.pm)

**Files:**
- Modify: `lib/EV/WebKit/Fingerprint.pm` (`%PRESET` `:33-76`, `%FIELD` `:79-85`, `resolve` `:170-201`, `_coherence` `:236-258`)
- Test: `t/99-fingerprint.t` (append)

**Interfaces:**
- Produces: each preset gains a `webgl => { params1, params2, extensions1, extensions2, precision }` hash. `_coherence` folds it into the JSON under key `webgl`. `resolve` validates a `webgl` override as a hashref. Consumed by Task 5's wrapper via `cfg.webgl`.

Reference note: the values below are the canonical per-GPU-family set (ANGLE/D3D11 NVIDIA for windows-chrome; Apple/Metal shared by both Safari presets; Adreno for pixel-chrome). If a live browser of a family is reachable during implementation, capture `getParameter` for these pnames from a WebGL report and reconcile; otherwise ship these. Per the spec's accepted residual, a per-driver database could still find a mismatch. Pname keys are the JS WebGL numeric constants (decimal). `params1` also carries the masked VENDOR (7936)="WebKit" and RENDERER (7937)="WebKit WebGL", matching real Chrome/Safari.

- [ ] **Step 1: Write the failing test** -- append to `t/99-fingerprint.t`:

```perl
# --- webgl capability data (pure Perl) ---
for my $name (EV::WebKit::Fingerprint::profiles()) {
    my $p = EV::WebKit::Fingerprint::resolve($name);
    is(ref $p->{webgl}, 'HASH', "$name has a webgl block");
    is($p->{webgl}{params1}{3379}, 16384, "$name MAX_TEXTURE_SIZE = 16384");
    is(ref $p->{webgl}{extensions1}, 'ARRAY', "$name has a WebGL1 extension list");
    ok(scalar(@{$p->{webgl}{extensions2}}) > 0, "$name has a WebGL2 extension list");
    ok((grep { $_ eq 'WEBGL_debug_renderer_info' } @{$p->{webgl}{extensions1}}),
       "$name advertises WEBGL_debug_renderer_info");
}
# folded into the coherence JSON
my $coh = EV::WebKit::Fingerprint::gvariant(EV::WebKit::Fingerprint::resolve('windows-chrome'))->print(1);
like($coh, qr/webgl/, 'coherence JSON carries the webgl block');
# validator: a non-hash webgl override croaks
eval { EV::WebKit::Fingerprint::resolve({ profile => 'windows-chrome', webgl => [1] }) };
like($@, qr/webgl.*must be a hashref/, 'non-hash webgl override croaks');
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xvfb-run -a make test TEST_FILES=t/99-fingerprint.t`
Expected: FAIL -- presets have no `webgl` key.

- [ ] **Step 3: Add shared WebGL data tables** -- in `lib/EV/WebKit/Fingerprint.pm`, ABOVE `my %PRESET` (line 33), add three reusable table builders (shared so the two Safari presets are identical and drift-free):

```perl
# Canonical per-GPU-family WebGL capability sets (see the plan's Task 4 note).
# pname keys are JS WebGL numeric constants (decimal); values are number,
# [n,n] (a 2-vector), or string. VENDOR(7936)/RENDERER(7937) are the MASKED
# values real Chrome/Safari report; the UNMASKED vendor/renderer come from the
# preset's webgl_vendor/webgl_renderer via the existing string spoof.
my %WEBGL_ANGLE_NVIDIA = (
    params1 => {
        7936 => 'WebKit', 7937 => 'WebKit WebGL',
        7938 => 'WebGL 1.0 (OpenGL ES 2.0 Chromium)',
        35724 => 'WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)',
        3379 => 16384, 34076 => 16384, 34024 => 16384, 3386 => [32767,32767],
        34921 => 16, 36347 => 4096, 36348 => 30, 36349 => 1024,
        35660 => 16, 34930 => 16, 35661 => 32,
        33902 => [1,1], 33901 => [1,1024], 34047 => 16,
    },
    params2 => {
        32883 => 2048, 35071 => 2048, 36063 => 8, 34852 => 8, 36183 => 8,
        35376 => 65536, 34045 => 2, 36203 => 4294967294,
        35373 => 12, 35371 => 12, 35657 => 4096, 37157 => 120, 37154 => 64,
    },
    extensions1 => [qw(
        ANGLE_instanced_arrays EXT_blend_minmax EXT_clip_control
        EXT_color_buffer_half_float EXT_depth_clamp EXT_disjoint_timer_query
        EXT_float_blend EXT_frag_depth EXT_polygon_offset_clamp EXT_shader_texture_lod
        EXT_texture_compression_bptc EXT_texture_compression_rgtc
        EXT_texture_filter_anisotropic EXT_texture_mirror_clamp_to_edge EXT_sRGB
        KHR_parallel_shader_compile OES_element_index_uint OES_fbo_render_mipmap
        OES_standard_derivatives OES_texture_float OES_texture_float_linear
        OES_texture_half_float OES_texture_half_float_linear OES_vertex_array_object
        WEBGL_blend_func_extended WEBGL_color_buffer_float
        WEBGL_compressed_texture_s3tc WEBGL_compressed_texture_s3tc_srgb
        WEBGL_debug_renderer_info WEBGL_debug_shaders WEBGL_depth_texture
        WEBGL_draw_buffers WEBGL_lose_context WEBGL_multi_draw WEBGL_polygon_mode
    )],
    extensions2 => [qw(
        EXT_clip_control EXT_color_buffer_float EXT_color_buffer_half_float
        EXT_conservative_depth EXT_depth_clamp EXT_disjoint_timer_query_webgl2
        EXT_float_blend EXT_polygon_offset_clamp EXT_render_snorm
        EXT_texture_compression_bptc EXT_texture_compression_rgtc
        EXT_texture_filter_anisotropic EXT_texture_mirror_clamp_to_edge
        EXT_texture_norm16 KHR_parallel_shader_compile
        NV_shader_noperspective_interpolation OES_draw_buffers_indexed
        OES_sample_variables OES_shader_multisample_interpolation
        OES_texture_float_linear OVR_multiview2 WEBGL_blend_func_extended
        WEBGL_clip_cull_distance WEBGL_compressed_texture_s3tc
        WEBGL_compressed_texture_s3tc_srgb WEBGL_debug_renderer_info
        WEBGL_debug_shaders WEBGL_lose_context WEBGL_multi_draw WEBGL_polygon_mode
        WEBGL_provoking_vertex WEBGL_stencil_texturing
    )],
    precision => {   # shaderType.precisionType -> [rangeMin,rangeMax,precision]
        'VERTEX.HIGH_FLOAT'   => [127,127,23], 'VERTEX.MEDIUM_FLOAT' => [127,127,23],
        'VERTEX.LOW_FLOAT'    => [127,127,23], 'FRAGMENT.HIGH_FLOAT' => [127,127,23],
        'FRAGMENT.MEDIUM_FLOAT'=> [127,127,23],'FRAGMENT.LOW_FLOAT'  => [127,127,23],
        'VERTEX.HIGH_INT'     => [31,30,0],    'FRAGMENT.HIGH_INT'   => [31,30,0],
    },
);
my %WEBGL_APPLE = (
    params1 => {
        7936 => 'WebKit', 7937 => 'WebKit WebGL',
        7938 => 'WebGL 1.0', 35724 => 'WebGL GLSL ES 1.0',
        3379 => 16384, 34076 => 16384, 34024 => 16384, 3386 => [16384,16384],
        34921 => 16, 36347 => 1024, 36348 => 31, 36349 => 1024,
        35660 => 16, 34930 => 16, 35661 => 32,
        33902 => [1,1], 33901 => [1,511], 34047 => 16,
    },
    params2 => {
        32883 => 2048, 35071 => 2048, 36063 => 8, 34852 => 8, 36183 => 4,
        35376 => 65536, 34045 => 2, 36203 => 4294967294,
        35373 => 12, 35371 => 12, 35657 => 1024, 37157 => 60, 37154 => 64,
    },
    extensions1 => [qw(
        ANGLE_instanced_arrays EXT_blend_minmax EXT_clip_control EXT_color_buffer_half_float
        EXT_float_blend EXT_frag_depth EXT_shader_texture_lod
        EXT_texture_filter_anisotropic EXT_sRGB KHR_parallel_shader_compile
        OES_element_index_uint OES_fbo_render_mipmap OES_standard_derivatives
        OES_texture_float OES_texture_float_linear OES_texture_half_float
        OES_texture_half_float_linear OES_vertex_array_object
        WEBGL_color_buffer_float WEBGL_compressed_texture_astc
        WEBGL_compressed_texture_etc WEBGL_compressed_texture_pvrtc
        WEBGL_debug_renderer_info WEBGL_depth_texture WEBGL_draw_buffers WEBGL_lose_context
    )],
    extensions2 => [qw(
        EXT_clip_control EXT_color_buffer_float EXT_color_buffer_half_float
        EXT_float_blend EXT_texture_filter_anisotropic EXT_texture_norm16
        KHR_parallel_shader_compile OES_draw_buffers_indexed OES_texture_float_linear
        OVR_multiview2 WEBGL_clip_cull_distance WEBGL_compressed_texture_astc
        WEBGL_compressed_texture_etc WEBGL_debug_renderer_info WEBGL_lose_context
        WEBGL_multi_draw WEBGL_provoking_vertex
    )],
    precision => {
        'VERTEX.HIGH_FLOAT'   => [127,127,23], 'VERTEX.MEDIUM_FLOAT' => [127,127,23],
        'VERTEX.LOW_FLOAT'    => [127,127,23], 'FRAGMENT.HIGH_FLOAT' => [127,127,23],
        'FRAGMENT.MEDIUM_FLOAT'=> [127,127,23],'FRAGMENT.LOW_FLOAT'  => [127,127,23],
        'VERTEX.HIGH_INT'     => [31,30,0],    'FRAGMENT.HIGH_INT'   => [31,30,0],
    },
);
my %WEBGL_ADRENO = (
    params1 => {
        7936 => 'WebKit', 7937 => 'WebKit WebGL',
        7938 => 'WebGL 1.0 (OpenGL ES 2.0 Chromium)',
        35724 => 'WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)',
        3379 => 16384, 34076 => 16384, 34024 => 16384, 3386 => [16384,16384],
        34921 => 16, 36347 => 256, 36348 => 31, 36349 => 224,
        35660 => 16, 34930 => 16, 35661 => 32,
        33902 => [1,8], 33901 => [1,1023], 34047 => 16,
    },
    params2 => {
        32883 => 2048, 35071 => 2048, 36063 => 8, 34852 => 8, 36183 => 4,
        35376 => 65536, 34045 => 2, 36203 => 4294967294,
        35373 => 24, 35371 => 24, 35657 => 3584, 37157 => 124, 37154 => 124,
    },
    extensions1 => [qw(
        ANGLE_instanced_arrays EXT_blend_minmax EXT_clip_control EXT_color_buffer_half_float
        EXT_disjoint_timer_query EXT_float_blend EXT_frag_depth EXT_shader_texture_lod
        EXT_texture_filter_anisotropic EXT_sRGB KHR_parallel_shader_compile
        OES_element_index_uint OES_fbo_render_mipmap OES_standard_derivatives
        OES_texture_float OES_texture_float_linear OES_texture_half_float
        OES_texture_half_float_linear OES_vertex_array_object WEBGL_color_buffer_float
        WEBGL_compressed_texture_astc WEBGL_compressed_texture_etc
        WEBGL_compressed_texture_etc1 WEBGL_debug_renderer_info WEBGL_debug_shaders
        WEBGL_depth_texture WEBGL_draw_buffers WEBGL_lose_context WEBGL_multi_draw
    )],
    extensions2 => [qw(
        EXT_clip_control EXT_color_buffer_float EXT_color_buffer_half_float
        EXT_disjoint_timer_query_webgl2 EXT_float_blend EXT_texture_filter_anisotropic
        EXT_texture_norm16 KHR_parallel_shader_compile OES_draw_buffers_indexed
        OES_sample_variables OES_shader_multisample_interpolation OES_texture_float_linear
        OVR_multiview2 WEBGL_clip_cull_distance WEBGL_compressed_texture_astc
        WEBGL_compressed_texture_etc WEBGL_debug_renderer_info WEBGL_lose_context
        WEBGL_multi_draw WEBGL_provoking_vertex
    )],
    precision => {
        'VERTEX.HIGH_FLOAT'   => [127,127,23], 'VERTEX.MEDIUM_FLOAT' => [127,127,23],
        'VERTEX.LOW_FLOAT'    => [127,127,23], 'FRAGMENT.HIGH_FLOAT' => [127,127,23],
        'FRAGMENT.MEDIUM_FLOAT'=> [127,127,23],'FRAGMENT.LOW_FLOAT'  => [127,127,23],
        'VERTEX.HIGH_INT'     => [31,30,0],    'FRAGMENT.HIGH_INT'   => [31,30,0],
    },
);
```

- [ ] **Step 4: Attach `webgl` to each preset** -- in `%PRESET`, add a `webgl` key to each entry:
  - `windows-chrome`: `webgl => \%WEBGL_ANGLE_NVIDIA,`
  - `macos-safari`: `webgl => \%WEBGL_APPLE,`
  - `iphone-safari`: `webgl => \%WEBGL_APPLE,`
  - `pixel-chrome`: `webgl => \%WEBGL_ADRENO,`

- [ ] **Step 5: Add the `webgl` validator** -- in `%FIELD` (line 79-85), add `webgl => 'webgl',` and in `resolve`'s validator chain (before the closing of the `for my $k` loop), add a branch:

```perl
        elsif ($t eq 'webgl') { Carp::croak("fingerprint: webgl must be a hashref") unless ref $v eq 'HASH' }
```

- [ ] **Step 6: Fold `webgl` into the coherence JSON** -- in `_coherence` (line 236-258), before `return %c ? \%c : undef;`, add:

```perl
    $c{webgl} = $p->{webgl} if $p->{webgl};
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `xvfb-run -a make test TEST_FILES=t/99-fingerprint.t`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git -c user.name=vividsnow -c user.email=vividsnow@pm.me add lib/EV/WebKit/Fingerprint.pm t/99-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: per-profile WebGL capability data"
```

---

### Task 5: Phase 2b -- WebGL capability wrapper (extension)

**Files:**
- Modify: `wext/evwk_fp.c` (`WEBGL_WRAPPER_JS` `:44-61`, `__evwk_cfg` lifetime in `on_window_object_cleared` `:210-235`)
- Test: `t/A1-webgl-caps.t` (create)

**Interfaces:**
- Consumes: `cfg.webgl` (from Task 4) via `window.__evwk_cfg`; the existing `__evwk_wv`/`__evwk_wr` string spoof.
- Produces: `getParameter(pname)`, `getSupportedExtensions()`, `getExtension(name)`, `getShaderPrecisionFormat(type,ptype)` return the profile's values on both WebGL1 and WebGL2, coherent with the UNMASKED renderer string.

**`__evwk_cfg` lifetime rework (do this first):** the WebGL wrapper now needs `cfg` BEFORE `COHERENCE_JS` runs. Set `__evwk_cfg` on the global up front, have each JS block parse it without deleting, and delete it once in C at the end.

- [ ] **Step 1: Write the failing test** -- create `t/A1-webgl-caps.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit; use EV::WebKit::Fingerprint;
plan skip_all => 'web-process extension not built' unless EV::WebKit::Fingerprint::available();

sub caps {
    my ($name) = @_;
    my $b = EV::WebKit->new(window => [200,150], fingerprint => $name);
    $b->mock_scheme('fp', sub { ('<html><body></body></html>','text/html') });
    my $out;
    $b->go('fp://host/p', sub {
        $b->script(<<'JS', sub { $out = $_[0]; EV::break });
          var c=document.createElement('canvas'); var gl=c.getContext('webgl')||c.getContext('experimental-webgl');
          if(!gl) return JSON.stringify({hasGL:false});
          var dbg=gl.getExtension('WEBGL_debug_renderer_info');
          return JSON.stringify({
            hasGL:true,
            maxTex: gl.getParameter(3379),
            viewport: Array.from(gl.getParameter(3386)),
            attribs: gl.getParameter(34921),
            combined: gl.getParameter(35661),
            version: gl.getParameter(7938),
            renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : null,
            exts: gl.getSupportedExtensions(),
            prec: (function(){ var p=gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.HIGH_FLOAT);
                               return p ? [p.rangeMin,p.rangeMax,p.precision] : null; })(),
          });
JS
    });
    TWK::run_with_timeout(20);
    $b->quit;
    require Cpanel::JSON::XS; return Cpanel::JSON::XS::decode_json($out // '{}');
}

for my $name (qw(windows-chrome macos-safari pixel-chrome)) {
    my $p = EV::WebKit::Fingerprint::resolve($name);
    my $r = caps($name);
    SKIP: { skip "no WebGL for $name", 6 unless $r->{hasGL};
        is($r->{maxTex}, $p->{webgl}{params1}{3379}, "$name MAX_TEXTURE_SIZE matches profile");
        is_deeply($r->{viewport}, $p->{webgl}{params1}{3386}, "$name MAX_VIEWPORT_DIMS matches");
        is($r->{attribs}, $p->{webgl}{params1}{34921}, "$name MAX_VERTEX_ATTRIBS matches");
        is($r->{version}, $p->{webgl}{params1}{7938}, "$name VERSION string matches");
        is($r->{renderer}, $p->{webgl_renderer}, "$name UNMASKED_RENDERER is coherent with the caps");
        ok((grep { $_ eq 'WEBGL_debug_renderer_info' } @{$r->{exts}}),
           "$name getSupportedExtensions returns the profile list");
    }
}
# negative control: no fingerprint -> host caps, NOT the spoofed VERSION string
{
    my $b = EV::WebKit->new(window => [200,150]);
    $b->mock_scheme('fp', sub { ('<html><body></body></html>','text/html') });
    my $ver;
    $b->go('fp://host/p', sub {
        $b->script('var c=document.createElement("canvas");var gl=c.getContext("webgl")||c.getContext("experimental-webgl");return gl?gl.getParameter(7938):"nogl";',
                   sub { $ver = $_[0]; EV::break });
    });
    TWK::run_with_timeout(20); $b->quit;
    unlike($ver // '', qr/Chromium/, 'no fingerprint: VERSION is the host string, not the spoof')
        if defined $ver && $ver ne 'nogl';
}
done_testing;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES=t/A1-webgl-caps.t`
Expected: FAIL -- `getParameter(3379)` returns the host value, not the profile's; the version string is not spoofed.

- [ ] **Step 3: Rework the `__evwk_cfg` lifetime in C** -- in `on_window_object_cleared`, replace the `if (P.webgl_vendor || P.webgl_renderer) { ... }` block and the `if (P.coherence) { ... }` block (lines 210-231) with this ordering (set `__evwk_cfg` first, inject the WebGL wrapper, then coherence, and delete cfg once at the end):

```c
    if (P.coherence) {
        JSCValue *c = jsc_value_new_string (ctx, P.coherence);
        jsc_value_object_set_property (global, "__evwk_cfg", c);
        g_object_unref (c);
    }

    if (P.webgl_vendor || P.webgl_renderer || P.coherence) {
        if (P.webgl_vendor) {
            JSCValue *v = jsc_value_new_string (ctx, P.webgl_vendor);
            jsc_value_object_set_property (global, "__evwk_wv", v);
            g_object_unref (v);
        }
        if (P.webgl_renderer) {
            JSCValue *v = jsc_value_new_string (ctx, P.webgl_renderer);
            jsc_value_object_set_property (global, "__evwk_wr", v);
            g_object_unref (v);
        }
        JSCValue *r = jsc_context_evaluate (ctx, WEBGL_WRAPPER_JS, -1);
        if (r) g_object_unref (r);
    }

    if (P.coherence) {
        JSCValue *r = jsc_context_evaluate (ctx, COHERENCE_JS, -1);
        if (r) g_object_unref (r);
        /* cfg is consumed by the WebGL wrapper, COHERENCE_JS, and later FEATURES_JS;
         * delete it once here, after the last reader, so it leaves no window tell. */
        JSCValue *d = jsc_context_evaluate (ctx, "delete window.__evwk_cfg;", -1);
        if (d) g_object_unref (d);
    }
```

- [ ] **Step 4: Stop `COHERENCE_JS` from deleting cfg** -- in `COHERENCE_JS` (line 69), remove the `"  delete window.__evwk_cfg;"` line so the cfg survives for the C-side delete (the WebGL wrapper already ran before it, and FEATURES_JS in Task 7 will run after). Keep the `JSON.parse` guard.

- [ ] **Step 5: Extend `WEBGL_WRAPPER_JS`** -- replace the `WEBGL_WRAPPER_JS` definition (lines 44-61) with a version that reads `cfg.webgl` and handles the numeric pnames, extensions, and precision. It still deletes `__evwk_wv`/`__evwk_wr`; it reads (does not delete) `__evwk_cfg`:

```c
static const char *WEBGL_WRAPPER_JS =
    "(function(){"
    "  var V=window.__evwk_wv, R=window.__evwk_wr;"
    "  delete window.__evwk_wv; delete window.__evwk_wr;"
    "  var W=null; try{ var cfg=JSON.parse(window.__evwk_cfg); W=cfg.webgl||null; }catch(e){}"
    "  function bind(w,orig){ try{ w.toString=orig.toString.bind(orig); }catch(e){} return w; }"
    "  function conv(p,val){"                       /* [a,b] -> typed array; type is per-pname, NOT per-value */
    "    if(!Array.isArray(val)) return val;"
    "    var isF = (p===33901 || p===33902 || p===2928);"  /* ALIASED_POINT/LINE_WIDTH_RANGE, DEPTH_RANGE -> Float32Array */
    "    return isF ? new Float32Array(val) : new Int32Array(val); }"  /* MAX_VIEWPORT_DIMS etc -> Int32Array */
    "  function patch(proto, isGL2){"
    "    if(!proto||!proto.getParameter) return;"
    "    var pm = W ? Object.assign({}, W.params1, isGL2?W.params2:null) : null;"
    "    var gp=proto.getParameter;"
    "    proto.getParameter=bind(({ getParameter(p){"
    "      if(R!==undefined && p===37446) return R;"
    "      if(V!==undefined && p===37445) return V;"
    "      if(pm && Object.prototype.hasOwnProperty.call(pm,p)){ var v=pm[p];"
    "        return (typeof v==='number'||typeof v==='string') ? v : conv(p,v); }"
    "      return gp.apply(this, arguments);"
    "    } }).getParameter, gp);"
    "    if(W && W.extensions1){ var exts=(isGL2?W.extensions2:W.extensions1)||[];"
    "      var gse=proto.getSupportedExtensions;"
    "      proto.getSupportedExtensions=bind(({ getSupportedExtensions(){ return exts.slice(); } }).getSupportedExtensions, gse);"
    "      var ge=proto.getExtension;"
    "      proto.getExtension=bind(({ getExtension(name){"
    "        var real=ge.apply(this, arguments); if(real) return real;"     /* real object wins */
    "        if(exts.indexOf(name)<0) return null;"                          /* not advertised -> null */
    "        if(name==='WEBGL_debug_renderer_info') return {UNMASKED_VENDOR_WEBGL:37445, UNMASKED_RENDERER_WEBGL:37446};"
    "        if(name==='EXT_texture_filter_anisotropic'||name==='MOZ_EXT_texture_filter_anisotropic'||name==='WEBKIT_EXT_texture_filter_anisotropic')"
    "          return {TEXTURE_MAX_ANISOTROPY_EXT:34046, MAX_TEXTURE_MAX_ANISOTROPY_EXT:34047};"
    "        return {};"                                                     /* advertised but no real impl: constants-only stub */
    "      } }).getExtension, ge);"
    "    }"
    "    if(W && W.precision && proto.getShaderPrecisionFormat){"
    "      var ST={35633:'VERTEX',35632:'FRAGMENT'}, PT={36336:'LOW_FLOAT',36337:'MEDIUM_FLOAT',36338:'HIGH_FLOAT',36339:'LOW_INT',36340:'MEDIUM_INT',36341:'HIGH_INT'};"
    "      var gspf=proto.getShaderPrecisionFormat;"
    "      proto.getShaderPrecisionFormat=bind(({ getShaderPrecisionFormat(st,pt){"
    "        var key=(ST[st]||'')+'.'+(PT[pt]||''); var v=W.precision[key];"
    "        if(v) return {rangeMin:v[0], rangeMax:v[1], precision:v[2]};"
    "        return gspf.apply(this, arguments);"
    "      } }).getShaderPrecisionFormat, gspf);"
    "    }"
    "  }"
    "  patch(window.WebGLRenderingContext && window.WebGLRenderingContext.prototype, false);"
    "  patch(window.WebGL2RenderingContext && window.WebGL2RenderingContext.prototype, true);"
    "})();";
```

- [ ] **Step 6: Rebuild and run the test to verify it passes**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES=t/A1-webgl-caps.t`
Expected: PASS.

- [ ] **Step 7: Run the existing coherence + fingerprint tests (no regressions)**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES="t/99-fingerprint.t t/97-network-fingerprint.t t/98-curl-target.t"`
Expected: PASS (the cfg-lifetime rework must not disturb userAgentData/matchMedia/etc.).

- [ ] **Step 8: Commit**

```bash
git -c user.name=vividsnow -c user.email=vividsnow@pm.me add wext/evwk_fp.c t/A1-webgl-caps.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: WebGL numeric caps + extensions + precision wrapper"
```

---

### Task 6: Phase 3a -- feature-presence data (Fingerprint.pm)

**Files:**
- Modify: `lib/EV/WebKit/Fingerprint.pm` (`%PRESET`, `%FIELD`, `resolve`, `_coherence`)
- Test: `t/99-fingerprint.t` (append)

**Interfaces:**
- Produces: each preset gains a `features => [ ... ]` list naming which stub groups to install. `_coherence` folds it into the JSON under key `features`. `resolve` validates `features` as an arrayref of strings. Consumed by Task 7 via `cfg.features`.

Per-profile lists (platform-accurate: Android Chrome lacks WebHID/Web Serial; Safari lacks connection/battery/usb/bluetooth/hid/serial/scheduling):
- `windows-chrome`: `[qw(connection storage battery usb bluetooth hid serial scheduling rtc)]`
- `pixel-chrome`: `[qw(connection storage battery usb bluetooth scheduling rtc)]`
- `macos-safari`: `[qw(storage rtc)]`
- `iphone-safari`: `[qw(storage rtc)]`

- [ ] **Step 1: Write the failing test** -- append to `t/99-fingerprint.t`:

```perl
# --- feature-presence data (pure Perl) ---
my %want = (
    'windows-chrome' => [qw(connection storage battery usb bluetooth hid serial scheduling rtc)],
    'pixel-chrome'   => [qw(connection storage battery usb bluetooth scheduling rtc)],
    'macos-safari'   => [qw(storage rtc)],
    'iphone-safari'  => [qw(storage rtc)],
);
for my $name (sort keys %want) {
    my $p = EV::WebKit::Fingerprint::resolve($name);
    is_deeply($p->{features}, $want{$name}, "$name has the expected feature list");
}
ok(!grep({ $_ eq 'usb' } @{EV::WebKit::Fingerprint::resolve('macos-safari')->{features}}),
   'Safari does not advertise WebUSB');
ok(!grep({ $_ eq 'serial' } @{EV::WebKit::Fingerprint::resolve('pixel-chrome')->{features}}),
   'Android Chrome does not advertise Web Serial');
my $cj = EV::WebKit::Fingerprint::gvariant(EV::WebKit::Fingerprint::resolve('windows-chrome'))->print(1);
like($cj, qr/features/, 'coherence JSON carries the features list');
eval { EV::WebKit::Fingerprint::resolve({ profile => 'windows-chrome', features => 'x' }) };
like($@, qr/features.*arrayref/, 'non-arrayref features override croaks');
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xvfb-run -a make test TEST_FILES=t/99-fingerprint.t`
Expected: FAIL -- presets have no `features` key.

- [ ] **Step 3: Attach `features` to each preset** -- in `%PRESET`, add the per-profile `features => [ ... ]` from the lists above to each entry.

- [ ] **Step 4: Add the `features` validator** -- in `%FIELD`, add `features => 'features',` and in `resolve`, add a branch:

```perl
        elsif ($t eq 'features') { Carp::croak("fingerprint: features must be an arrayref of strings")
                                       unless ref $v eq 'ARRAY' && !grep { ref($_) || !defined($_) || index($_,"\0") >= 0 } @$v }
```

- [ ] **Step 5: Fold `features` into the coherence JSON** -- in `_coherence`, before the return, add:

```perl
    $c{features} = $p->{features} if $p->{features};
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `xvfb-run -a make test TEST_FILES=t/99-fingerprint.t`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git -c user.name=vividsnow -c user.email=vividsnow@pm.me add lib/EV/WebKit/Fingerprint.pm t/99-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: per-profile DOM feature-presence data"
```

---

### Task 7: Phase 3b -- feature-presence stubs (extension)

**Files:**
- Modify: `wext/evwk_fp.c` (new `FEATURES_JS` string, injection in `on_window_object_cleared`)
- Test: `t/A2-features.t` (create)

**Interfaces:**
- Consumes: `cfg.features` (from Task 6) via `window.__evwk_cfg` (still present -- the C-side delete from Task 5 runs AFTER this block once it is inserted before that delete).
- Produces: each named feature stub installed only if `!(name in target)`, never clobbering a real WebKitGTK API.

- [ ] **Step 1: Write the failing test** -- create `t/A2-features.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit; use EV::WebKit::Fingerprint;
plan skip_all => 'web-process extension not built' unless EV::WebKit::Fingerprint::available();

# NB: body uses `return await` (script wraps it in an async IIFE + JSON.stringify).
sub feat {
    my ($name) = @_;
    my $b = EV::WebKit->new(window => [200,150], fingerprint => $name);
    $b->mock_scheme('fp', sub { ('<html><body></body></html>','text/html') });
    my $out;
    $b->go('fp://host/p', sub {
        $b->script(<<'JS', sub { $out = $_[0]; EV::break });
          const res = {
            connection: 'connection' in navigator,
            usb: 'usb' in navigator, bluetooth: 'bluetooth' in navigator,
            hid: 'hid' in navigator, serial: 'serial' in navigator,
            battery: typeof navigator.getBattery === 'function',
            scheduling: 'scheduling' in navigator,
            rtc: 'RTCPeerConnection' in window,
            storage: !!(navigator.storage && navigator.storage.estimate),
            effType: navigator.connection ? navigator.connection.effectiveType : null,
            estimateOk: false, batteryLevel: null,
          };
          try {
            if (navigator.storage && navigator.storage.estimate) {
              const est = await navigator.storage.estimate();
              res.estimateOk = est && typeof est.quota === 'number';
            }
            if (typeof navigator.getBattery === 'function') {
              const bat = await navigator.getBattery();
              res.batteryLevel = bat ? bat.level : null;
            }
          } catch (e) {}
          return JSON.stringify(res);
JS
    });
    TWK::run_with_timeout(20);
    $b->quit;
    require Cpanel::JSON::XS; return Cpanel::JSON::XS::decode_json($out // '{}');
}

my $c = feat('windows-chrome');
ok($c->{connection}, 'Chrome: navigator.connection present');
ok($c->{usb} && $c->{bluetooth} && $c->{hid} && $c->{serial}, 'Chrome desktop: usb/bluetooth/hid/serial present');
ok($c->{battery}, 'Chrome: navigator.getBattery present');
ok($c->{scheduling} && $c->{rtc} && $c->{storage}, 'Chrome: scheduling/rtc/storage present');
is($c->{effType}, '4g', 'connection.effectiveType is functional');
ok($c->{estimateOk}, 'storage.estimate() resolves a StorageEstimate');
is($c->{batteryLevel}, 1, 'getBattery() resolves a BatteryManager');

my $s = feat('macos-safari');
ok(!$s->{connection}, 'Safari: no navigator.connection');
ok(!$s->{usb} && !$s->{bluetooth} && !$s->{battery}, 'Safari: no usb/bluetooth/battery');
ok($s->{rtc} && $s->{storage}, 'Safari: rtc + storage present');

my $px = feat('pixel-chrome');
ok($px->{usb} && $px->{bluetooth}, 'Android Chrome: usb + bluetooth present');
ok(!$px->{hid} && !$px->{serial}, 'Android Chrome: no hid/serial (desktop-only)');
done_testing;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES=t/A2-features.t`
Expected: FAIL -- none of the stubs installed (WebKitGTK exposes neither set), so the Chrome presence assertions fail.

- [ ] **Step 3: Add the `FEATURES_JS` string** -- in `wext/evwk_fp.c`, after `COHERENCE_JS` (after line 129), add:

```c
/* DOM feature-presence stubs. Each installed ONLY if the target does not already
 * expose it (in-guarded), so a WebKitGTK build that ships an API keeps the real
 * one. Functional where feasible; no real ICE/USB/etc. Same detectability ceiling
 * (JS getters/methods). Driven by cfg.features (an array of group names). */
static const char *FEATURES_JS =
    "(function(){"
    "  var F; try{ F=JSON.parse(window.__evwk_cfg).features; }catch(e){ return; }"
    "  if(!F || !F.length) return;"
    "  var has=function(n){ return F.indexOf(n)>=0; };"
    "  var ET={ addEventListener(){}, removeEventListener(){}, dispatchEvent(){ return false; } };"
    "  function defNav(name,obj){ try{ if(!(name in Navigator.prototype) && !(name in navigator))"
    "    Object.defineProperty(Navigator.prototype,name,{get:function(){ return obj; },enumerable:true,configurable:true}); }catch(e){} }"
    "  function defNavVal(name,val){ try{ if(!(name in Navigator.prototype) && !(name in navigator))"
    "    Object.defineProperty(Navigator.prototype,name,{value:val,writable:true,enumerable:true,configurable:true}); }catch(e){} }"
    "  if(has('connection')){ var ci=Object.assign({effectiveType:'4g',rtt:50,downlink:10,saveData:false,onchange:null},ET); defNav('connection',ci); }"
    "  if(has('storage')){ try{ if(!(navigator.storage && navigator.storage.estimate)){"
    "    var sm={ estimate(){ return Promise.resolve({quota:2**41, usage:0, usageDetails:{}}); },"
    "             persist(){ return Promise.resolve(false); }, persisted(){ return Promise.resolve(false); } };"
    "    defNav('storage',sm); } }catch(e){} }"
    "  if(has('battery')){ defNavVal('getBattery', function getBattery(){ return Promise.resolve(Object.assign("
    "    {charging:true,chargingTime:0,dischargingTime:Infinity,level:1,onchargingchange:null,onchargingtimechange:null,ondischargingtimechange:null,onlevelchange:null},ET)); }); }"
    "  function devs(name){ if(has(name)) defNav(name, Object.assign({"
    "    getDevices(){ return Promise.resolve([]); },"
    "    requestDevice(){ return Promise.reject(new DOMException('No device selected.','NotFoundError')); },"
    "    requestPort(){ return Promise.reject(new DOMException('No port selected.','NotFoundError')); } }, ET)); }"
    "  devs('usb'); devs('bluetooth'); devs('hid'); devs('serial');"
    "  if(has('scheduling')){ defNavVal('scheduling', { isInputPending: function isInputPending(){ return false; } }); }"
    "  if(has('rtc') && !('RTCPeerConnection' in window)){ try{"
    "    var RPC=function RTCPeerConnection(){ this.localDescription=null; this.remoteDescription=null;"
    "      this.iceGatheringState='new'; this.iceConnectionState='new'; this.connectionState='new'; this.signalingState='stable';"
    "      this.onicecandidate=null; this.ontrack=null; this.ondatachannel=null; this.onconnectionstatechange=null; };"
    "    RPC.prototype.createOffer=function(){ return Promise.resolve({type:'offer',sdp:''}); };"
    "    RPC.prototype.createAnswer=function(){ return Promise.resolve({type:'answer',sdp:''}); };"
    "    RPC.prototype.setLocalDescription=function(){ return Promise.resolve(); };"
    "    RPC.prototype.setRemoteDescription=function(){ return Promise.resolve(); };"
    "    RPC.prototype.addIceCandidate=function(){ return Promise.resolve(); };"
    "    RPC.prototype.createDataChannel=function(){ return Object.assign({ send(){}, close() {} }, ET); };"
    "    RPC.prototype.getStats=function(){ return Promise.resolve(new Map()); };"
    "    RPC.prototype.addEventListener=function(){}; RPC.prototype.removeEventListener=function(){};"
    "    RPC.prototype.close=function(){};"
    "    Object.defineProperty(window,'RTCPeerConnection',{value:RPC,writable:true,enumerable:false,configurable:true});"
    "    Object.defineProperty(window,'webkitRTCPeerConnection',{value:RPC,writable:true,enumerable:false,configurable:true});"
    "  }catch(e){} }"
    "})();";
```

- [ ] **Step 4: Inject `FEATURES_JS`** -- in `on_window_object_cleared`, inside the `if (P.coherence) { ... }` block from Task 5, AFTER the `COHERENCE_JS` eval and BEFORE the `delete window.__evwk_cfg;` eval, add:

```c
        JSCValue *f = jsc_context_evaluate (ctx, FEATURES_JS, -1);
        if (f) g_object_unref (f);
```

- [ ] **Step 5: Rebuild and run the test to verify it passes**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES=t/A2-features.t`
Expected: PASS.

- [ ] **Step 6: Full fingerprint-suite regression check**

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES="t/99-fingerprint.t t/A0-readback-noise.t t/A1-webgl-caps.t t/A2-features.t t/97-network-fingerprint.t t/98-curl-target.t"`
Expected: PASS across all.

- [ ] **Step 7: Commit**

```bash
git -c user.name=vividsnow -c user.email=vividsnow@pm.me add wext/evwk_fp.c t/A2-features.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: DOM feature-presence stubs (connection/storage/battery/usb/rtc/...)"
```

---

### Task 8: Docs + packaging

**Files:**
- Modify: `lib/EV/WebKit.pm` (POD: `seed` option, `Ceiling` rewrite, `$VERSION`)
- Modify: `MANIFEST` (add the 3 test files)
- Modify: `Changes` (0.03 entry)

- [ ] **Step 1: Document the `seed` option** -- in `lib/EV/WebKit.pm`, in the CONSTRUCTOR POD, add a `=item` after the `fingerprint => ...` block and before `network_fingerprint => ...` (before line 2789):

```pod
=item C<< seed => 12345 >>

Enable seeded B<readback noise> on canvas, C<AudioContext>, and WebGL pixel
readback (opt-in; requires C<fingerprint>). The seed is a non-negative integer.
The perturbation is a content-independent function of the seed and the readback
index: LSB-only for image/pixel channels, a tiny relative offset for audio
samples. This makes the hardware-readback hash stable within a session yet
different from the automation host's real output (hiding llvmpipe/software GL)
and different across seeds. Without C<seed>, readback is untouched (the default).
Residual: content-independent noise is recoverable by a script that renders a
known image and reads it back, and the wrappers remain
C<Function.prototype.toString.call>-detectable (see L</Ceiling>).
```

- [ ] **Step 2: Rewrite the WebGL + Ceiling paragraphs** -- in `lib/EV/WebKit.pm`, replace the two paragraphs at lines 2772-2787 (the "WebGL specifically spoofs only ... strings" paragraph and the "B<Ceiling:>" paragraph) with:

```pod
WebGL now spoofs the full per-profile capability set, not only the UNMASKED
vendor/renderer strings: the numeric parameters (C<MAX_TEXTURE_SIZE> and friends),
the supported-extension list, and C<getShaderPrecisionFormat> return the claimed
GPU family's values on both WebGL1 and WebGL2, coherent with the renderer string.
C<getExtension> returns the real object when the host GL supports it, a
constants-only stub for an advertised-but-absent extension, or null. The DOM
feature set is also aligned per profile (see C<seed> and below): a Chrome profile
exposes C<navigator.connection>/C<usb>/C<bluetooth>/C<getBattery>/C<scheduling>
and C<RTCPeerConnection>; a Safari profile exposes only C<storage> and
C<RTCPeerConnection>; each stub is installed only when the build lacks the real
API.

B<Ceiling:> the spoof is thorough but not perfect, and these residuals remain.
The JS wrappers (C<userAgentData>/C<matchMedia>/WebGL/readback/feature stubs) show
JS source under a C<Function.prototype.toString.call> (or getter-C<toString>)
check, so a determined script can still detect them. Readback noise (when C<seed>
is set) is content-independent, so a known-image probe can recover and undo it;
without C<seed>, canvas/audio/WebGL readback reflects the real host output. The
WebGL capability values are the canonical set for each GPU family, so a
fingerprinter with a per-driver database could still find a mismatch. Stubbed
extensions and C<RTCPeerConnection> have no real runtime behaviour (no ICE), so a
script that exercises their functionality can detect the stub. And this is all the
JS layer only -- the network-layer fingerprint (TLS JA3/JA4, HTTP/2) is unchanged
unless you also enable C<network_fingerprint> (below). A self-consistent B<custom>
profile is your responsibility.
```

- [ ] **Step 3: Bump `$VERSION`** -- in `lib/EV/WebKit.pm:3`, change `our $VERSION = '0.01';` to `our $VERSION = '0.03';` (the 0.02 network_fingerprint work is already in Changes; this cycle ships as 0.03).

- [ ] **Step 4: Add the test files to `MANIFEST`** -- add these three lines to `MANIFEST` in the `t/` block (keep the file's existing ordering):

```
t/A0-readback-noise.t
t/A1-webgl-caps.t
t/A2-features.t
```

- [ ] **Step 5: Add the `Changes` entry** -- at the top of `Changes`, above the `0.02` entry, add:

```
0.03  2026-07-21
        - fingerprint: close the JS-layer readback + capability + feature-presence gaps. Opt-in readback noise via a new seed => <int> option perturbs canvas (getImageData/toDataURL/toBlob), AudioContext (AudioBuffer/AnalyserNode), and WebGL readPixels with a seeded, content-independent, LSB-only function -- stable within a session, different from the automation host's output (hides llvmpipe), different across seeds. Without seed, readback is untouched.
        - fingerprint: WebGL now spoofs the full per-profile capability set (numeric getParameter pnames, getSupportedExtensions, getExtension, getShaderPrecisionFormat) for both WebGL1 and WebGL2, matching the claimed GPU family (ANGLE/NVIDIA for windows-chrome, Apple/Metal for the Safari presets, Adreno for pixel-chrome) and coherent with the spoofed renderer string, instead of only the UNMASKED vendor/renderer strings.
        - fingerprint: DOM feature-presence now matches the impersonated browser. A Chrome profile exposes navigator.connection/usb/bluetooth/getBattery/scheduling and RTCPeerConnection (Android drops hid/serial); a Safari profile exposes only storage + RTCPeerConnection. Each stub is in-guarded, so a WebKitGTK build that ships a real API keeps it. Functional where feasible; no real ICE/device access (documented residual).
        - doc: the Ceiling POD is rewritten to reflect the new state and its honest residuals (toString-detectable wrappers, undoable content-independent noise, canonical-per-family caps, non-functional stub extensions/RTC).
```

- [ ] **Step 6: Verify the dist is coherent** -- run the POD test and the full fingerprint suite:

Run: `perl Makefile.PL && make && xvfb-run -a make test TEST_FILES="t/90-pod.t t/99-fingerprint.t t/A0-readback-noise.t t/A1-webgl-caps.t t/A2-features.t"`
Expected: PASS (POD well-formed; all assertions green).

- [ ] **Step 7: Commit**

```bash
git -c user.name=vividsnow -c user.email=vividsnow@pm.me add lib/EV/WebKit.pm MANIFEST Changes
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: document ceiling hardening; MANIFEST + Changes + version 0.03"
```

---

## Final Verification (after all tasks)

- [ ] Run the FULL suite under xvfb to confirm nothing regressed:

Run: `perl Makefile.PL && make && xvfb-run -a make test`
Expected: all files pass (the three new t/A* included; existing t/9x coherence green).

- [ ] Confirm graceful degradation: with the extension NOT built (temporarily rename `share/wext/evwk_fp.so`), `t/A0`/`t/A1`/`t/A2` `skip_all` cleanly and `EV::WebKit->new(fingerprint => ...)` croaks the documented "extension was not built" message. Restore the `.so` afterward.

- [ ] Hand off to `superpowers:finishing-a-development-branch`.
