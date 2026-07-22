# EV::WebKit Fingerprint Spoofing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an `EV::WebKit` instance present as a chosen, coherent real device at the JavaScript-property layer (navigator/screen/WebGL), using native `[native code]` getters installed by a C web-process extension.

**Architecture:** One C `.so` (compiled at install against only glib/gobject) is loaded into WebKit's web process. It receives the device profile at runtime as a GVariant (`set_web_process_extensions_initialization_user_data`), parses it, and at `window-object-cleared` installs native accessors on `navigator`/`screen`/`window` and replaces WebGL `getParameter`. The Perl side (`EV::WebKit::Fingerprint`) owns the preset table, profile resolution/validation, and GVariant construction; `EV::WebKit->new` wires the extension directory + user-data before the first navigation and routes the profile's UA through the existing native `set_user_agent`.

**Tech Stack:** Perl 5.10+, Glib::Object::Introspection over WebKitGTK 6.0, EV, a C99 web-process extension, ExtUtils::MakeMaker + File::ShareDir(::Install).

## Global Constraints

- Commit author `vividsnow`, no name/email leak, no LLM attribution: `git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "..."`. No `Co-Authored-By`.
- POD is plain ASCII: no unicode, no em-dash -- use `--`.
- Run tests with `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/<file>.t`.
- Work on the `fingerprint` branch (already created; the spec is committed there).
- **The `fingerprint` option MUST be added to `%KNOWN_NEW`** (the constructor's known-key set, ~line 174) or `new(fingerprint=>...)` croaks "unknown option".
- Construct-time only: the extension dir + user-data must be set AFTER the `WebContext` is created and BEFORE the first navigation.
- `fingerprint` + `user_agent` together -> croak.
- Sparse-profile rule: a native getter is installed ONLY for fields the resolved profile declares (the GVariant carries only present keys).
- Ceiling, stated honestly in POD: JS-property + toString layer only; canvas-pixel/audio/TLS untouched.
- The `.so` is built WITHOUT webkit/jsc dev headers: webkit/jsc functions are hand-declared with opaque types and left unresolved at link (`-Wl,--unresolved-symbols=ignore-all`); glib/gobject come from pkg-config.

### Verified facts (do not re-derive)

- `WebKit::WebContext` HAS `set_web_process_extensions_directory` and `set_web_process_extensions_initialization_user_data` (GI-confirmed).
- Perl builds the profile GVariant with `Glib::Variant->new('a{sv}', { key => Glib::Variant->new('s'|'i'|'d'|'as', $val), ... })` (confirmed: prints `{'cores': <8>, 'platform': <'Win32'>}`).
- `File::ShareDir` and `File::ShareDir::Install` are both installed.
- The native-getter mechanism is PROVEN by the prior spike (`scratchpad/wext/webkit_spoof.c`): a `G_TYPE_STRING` accessor whose getter returns a `char*` yields the value AND `[native code]` in toString.
- `set_user_agent($ua)` (line 1286) sets both the HTTP header and `navigator.userAgent` natively; it reads back and croaks if WebKit rejected the UA.
- Highest existing test file is `t/98`; use `t/99-fingerprint.t`.

### GVariant profile schema (Perl builds it, C parses it -- names/types MUST match)

`a{sv}`, only present keys. Keys and value types:
`platform`(s), `vendor`(s), `webgl_vendor`(s), `webgl_renderer`(s), `languages`(as),
`hardwareConcurrency`(d), `deviceMemory`(d), `maxTouchPoints`(d), `devicePixelRatio`(d),
`screen_width`(d), `screen_height`(d), `screen_availWidth`(d), `screen_availHeight`(d),
`screen_colorDepth`(d), `screen_pixelDepth`(d).
(`user_agent` is NOT in the GVariant -- it goes through `set_user_agent`. All numbers are doubles: JS numbers are doubles, so one getter return type covers every numeric field.)

---

## Task 1: Spike the Perl -> GVariant -> C handoff (fail-fast)

The one un-spiked risk. Prove that a GVariant built in Perl reaches the C extension's `initialize_with_user_data` and drives a native getter, for BOTH a string (`platform`) and a number (`hardwareConcurrency`). If this fails, STOP and rethink before building anything else.

**Files:**
- Create: `wext/evwk_fp.c` (seed -- platform + hardwareConcurrency only)
- Create: `xt/fingerprint-spike.pl` (throwaway proof harness, kept for the record)

**Interfaces:**
- Produces: `wext/evwk_fp.c` with entry point `void webkit_web_process_extension_initialize_with_user_data(WebKitWebProcessExtension *ext, GVariant *user_data)` that installs `navigator.platform` (string) and `navigator.hardwareConcurrency` (double) from `user_data`.

- [ ] **Step 1: Write the seed C extension**

Create `wext/evwk_fp.c`:

```c
/* EV::WebKit fingerprint web-process extension.
 * Built WITHOUT webkit/jsc dev headers: the webkit/jsc functions are
 * hand-declared with opaque types and left unresolved at link time; they
 * resolve at dlopen inside the web process (which has libwebkitgtk +
 * libjavascriptcore loaded). glib/gobject come from real headers. */
#include <glib.h>
#include <glib-object.h>

typedef struct _WebKitWebProcessExtension WebKitWebProcessExtension;
typedef struct _WebKitScriptWorld          WebKitScriptWorld;
typedef struct _WebKitWebPage              WebKitWebPage;
typedef struct _WebKitFrame                WebKitFrame;
typedef struct _JSCContext                 JSCContext;
typedef struct _JSCValue                   JSCValue;

extern WebKitScriptWorld *webkit_script_world_get_default (void);
extern JSCContext        *webkit_frame_get_js_context_for_script_world (WebKitFrame *, WebKitScriptWorld *);
extern JSCValue          *jsc_context_get_global_object (JSCContext *);
extern JSCValue          *jsc_value_object_get_property (JSCValue *, const char *);
extern void               jsc_value_object_define_property_accessor (
                              JSCValue *, const char *name, int flags, GType type,
                              GCallback getter, GCallback setter, gpointer user_data, GDestroyNotify destroy);
#define JSC_VALUE_PROPERTY_CONFIGURABLE 1

/* The profile, parsed once from the GVariant and read by the getters. */
typedef struct {
    char   *platform;                 /* NULL => absent */
    gboolean has_hwc; double hwc;     /* has_* flags implement the sparse rule */
} Profile;
static Profile P;

/* G_TYPE_STRING getter: returns a freshly-allocated copy; JSC copies it. */
static char   *get_platform (void *a, void *b) { (void)a;(void)b; return g_strdup (P.platform); }
/* G_TYPE_DOUBLE getter: returns the number by value. */
static gdouble  get_hwc      (void *a, void *b) { (void)a;(void)b; return P.hwc; }

static void on_window_object_cleared (WebKitScriptWorld *world, WebKitWebPage *page,
                                      WebKitFrame *frame, gpointer ud)
{
    (void)page;(void)ud;
    JSCContext *ctx = webkit_frame_get_js_context_for_script_world (frame, world);
    if (!ctx) return;
    JSCValue *global = jsc_context_get_global_object (ctx);
    if (!global) return;
    JSCValue *nav = jsc_value_object_get_property (global, "navigator");
    if (!nav) return;
    if (P.platform)
        jsc_value_object_define_property_accessor (nav, "platform",
            JSC_VALUE_PROPERTY_CONFIGURABLE, G_TYPE_STRING,
            G_CALLBACK (get_platform), NULL, NULL, NULL);
    if (P.has_hwc)
        jsc_value_object_define_property_accessor (nav, "hardwareConcurrency",
            JSC_VALUE_PROPERTY_CONFIGURABLE, G_TYPE_DOUBLE,
            G_CALLBACK (get_hwc), NULL, NULL, NULL);
}

void webkit_web_process_extension_initialize_with_user_data (WebKitWebProcessExtension *ext,
                                                             GVariant *user_data)
{
    (void)ext;
    if (user_data) {
        const char *s = NULL;
        if (g_variant_lookup (user_data, "platform", "&s", &s) && s) P.platform = g_strdup (s);
        double d;
        if (g_variant_lookup (user_data, "hardwareConcurrency", "d", &d)) { P.has_hwc = TRUE; P.hwc = d; }
    }
    g_signal_connect (webkit_script_world_get_default (), "window-object-cleared",
                      G_CALLBACK (on_window_object_cleared), NULL);
}
```

- [ ] **Step 2: Compile the seed**

Run:
```bash
cd /home/yk/dev/perl-modules/EV-WebKit
mkdir -p .tmp/wext-spike
cc -shared -fPIC -o .tmp/wext-spike/evwk_fp.so wext/evwk_fp.c \
   $(pkg-config --cflags --libs gobject-2.0 glib-2.0) \
   -Wl,--unresolved-symbols=ignore-all
echo "exit=$?"; ls -l .tmp/wext-spike/evwk_fp.so
```
Expected: `exit=0` and the `.so` exists.

- [ ] **Step 3: Write the spike harness**

Create `xt/fingerprint-spike.pl`:

```perl
use v5.10; use strict; use warnings;
use lib 'lib';
use EV; use EV::WebKit; use Glib ();

# reach into a real instance's context and wire the extension BEFORE the first
# navigation -- exactly what the real feature does internally.
my $dir = "$ENV{PWD}/.tmp/wext-spike";
my $gv  = Glib::Variant->new('a{sv}', {
    platform            => Glib::Variant->new('s', 'Win32'),
    hardwareConcurrency => Glib::Variant->new('d', 8),
});

my $b = EV::WebKit->new(window => [200,150]);
$b->{context}->set_web_process_extensions_directory($dir);
$b->{context}->set_web_process_extensions_initialization_user_data($gv);
$b->mock_scheme('fp', sub { ('<html><body>fp</body></html>','text/html') });

my %g;
$b->go('fp://host/p', sub {
    $b->script('return navigator.platform', sub {
        $g{platform} = $_[0];
        $b->script('return navigator.hardwareConcurrency', sub {
            $g{hwc} = $_[0];
            $b->script('return Object.getOwnPropertyDescriptor(navigator,"platform").get.toString()', sub {
                $g{tostr} = $_[0]; EV::break;
            });
        });
    });
});
my $t = EV::timer(20,0,sub{ warn "TIMEOUT\n"; EV::break }); EV::run; undef $t;
$b->quit;

printf "platform = %s (expect Win32)\n", $g{platform} // 'undef';
printf "hwc      = %s (expect 8)\n",     $g{hwc}      // 'undef';
printf "toString = %s (expect [native code])\n", $g{tostr} // 'undef';
```

- [ ] **Step 4: Run the spike -- the fail-fast gate**

Run:
```bash
cd /home/yk/dev/perl-modules/EV-WebKit
TMPDIR="$PWD/.tmp" xvfb-run -a perl xt/fingerprint-spike.pl 2>&1 | grep -Ev "DRI3|MESA|libEGL|Xorg|GLib-GIO"
```
Expected:
```
platform = Win32 (expect Win32)
hwc      = 8 (expect 8)
toString = function get() {\n    [native code]\n} (expect [native code])
```
If `platform`/`hwc` do NOT round-trip, the Perl->GVariant->C handoff is broken -- STOP and diagnose (check `g_variant_lookup` format strings, the `a{sv}` types, and that `initialize_with_user_data` is the symbol WebKit looks up) before proceeding.

- [ ] **Step 5: Commit the proven seed**

```bash
git add wext/evwk_fp.c xt/fingerprint-spike.pl
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: spike the Perl->GVariant->C handoff (platform + hwc, native getters)"
```

---

## Task 2: Build system -- compile + install the .so, locate it at runtime

Turn the manual compile into a `Makefile.PL` step that installs the `.so` to a private share dir, and give the Perl side a way to find it and report availability.

**Files:**
- Modify: `Makefile.PL`
- Create: `lib/EV/WebKit/Fingerprint.pm` (this task: only `available` + `_so_dir`)
- Test: `t/99-fingerprint.t` (this task: availability + the .so exists after build)

**Interfaces:**
- Consumes: `wext/evwk_fp.c` (Task 1).
- Produces:
  - `EV::WebKit::Fingerprint::available()` -> bool (the `.so` is present).
  - `EV::WebKit::Fingerprint::_so_dir()` -> the directory holding ONLY `evwk_fp.so`, or undef.
  - Installed artifact: `<share>/wext/evwk_fp.so`.

- [ ] **Step 1: Rewrite Makefile.PL to build + install the .so**

Replace `Makefile.PL` with:

```perl
use v5.10; use strict; use warnings;
use ExtUtils::MakeMaker;
use File::ShareDir::Install;

# The web-process extension is compiled at install if the toolchain is present.
# It needs ONLY cc + glib/gobject (NOT webkit/jsc dev headers -- symbols resolve
# at dlopen in the web process). If unavailable, we warn and ship without it;
# the module stays fully usable and fingerprint => croaks at runtime.
my $so_built = build_wext();
install_share dist => 'share' if $so_built;

WriteMakefile(
    NAME             => 'EV::WebKit',
    VERSION_FROM     => 'lib/EV/WebKit.pm',
    ABSTRACT         => 'Async WebKitGTK 6.0 (GTK4) browser automation on EV',
    AUTHOR           => 'vividsnow',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.010',
    PREREQ_PM        => {
        'EV' => 0, 'EV::Glib' => 0, 'Glib' => 0,
        'Glib::Object::Introspection' => 0, 'Cpanel::JSON::XS' => 0,
        'Glib::IO' => 0, 'File::ShareDir' => 0,
    },
    CONFIGURE_REQUIRES => { 'File::ShareDir::Install' => 0 },
    TEST_REQUIRES    => { 'Test::More' => 0 },
    META_MERGE       => {
        'meta-spec' => { version => 2 },
        resources   => { repository => { type=>'git', url=>'https://github.com/vividsnow/perl5-ev-webkit.git', web=>'https://github.com/vividsnow/perl5-ev-webkit' } },
    },
);

package MY;
use File::ShareDir::Install;
sub postamble { my $self = shift; return File::ShareDir::Install::postamble($self) }

package main;
# Compile wext/evwk_fp.c -> share/wext/evwk_fp.so. Returns 1 on success.
sub build_wext {
    my $cc = $Config::Config{cc} || 'cc';
    system("pkg-config --exists gobject-2.0 glib-2.0") == 0
        or do { warn "EV::WebKit: pkg-config gobject-2.0/glib-2.0 not found -- fingerprint disabled\n"; return 0 };
    my $cflags = `pkg-config --cflags gobject-2.0 glib-2.0`; chomp $cflags;
    my $libs   = `pkg-config --libs gobject-2.0 glib-2.0`;   chomp $libs;
    File::Path::make_path('share/wext');
    my $cmd = "$cc -shared -fPIC -o share/wext/evwk_fp.so wext/evwk_fp.c "
            . "$cflags $libs -Wl,--unresolved-symbols=ignore-all";
    warn "EV::WebKit: building web-process extension:\n  $cmd\n";
    if (system($cmd) == 0 && -e 'share/wext/evwk_fp.so') { return 1 }
    warn "EV::WebKit: web-process extension build FAILED -- fingerprint disabled (module still installs)\n";
    return 0;
}
```

Add `use Config;` and `use File::Path;` at the top too (needed by `build_wext`):

```perl
use Config;
use File::Path;
```

- [ ] **Step 2: Write the availability module**

Create `lib/EV/WebKit/Fingerprint.pm`:

```perl
package EV::WebKit::Fingerprint;
use v5.10; use strict; use warnings;
use File::ShareDir ();

# The installed extension directory holds ONLY evwk_fp.so, so it can be handed
# straight to set_web_process_extensions_directory. Located via File::ShareDir
# in an installed dist, or the in-tree share/ during development/testing.
my $SO_DIR;
sub _so_dir {
    return $SO_DIR if defined $SO_DIR;
    my @cand;
    my $dist = eval { File::ShareDir::dist_dir('EV-WebKit') };
    push @cand, "$dist/wext" if defined $dist;
    # in-tree (blib during `make test`, or a plain checkout)
    for my $base (grep { defined } $ENV{PWD}) {
        push @cand, "$base/blib/lib/auto/share/dist/EV-WebKit/wext", "$base/share/wext";
    }
    for my $d (@cand) { if (-e "$d/evwk_fp.so") { return $SO_DIR = $d } }
    return $SO_DIR = '';   # cached "not found"
}

sub available { my $d = _so_dir(); return $d ne '' ? 1 : 0 }

1;
```

- [ ] **Step 3: Write the failing test**

Create `t/99-fingerprint.t`:

```perl
use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV::WebKit::Fingerprint;

plan skip_all => 'web-process extension not built (no cc/glib at install)'
    unless EV::WebKit::Fingerprint::available();

ok(EV::WebKit::Fingerprint::available(), 'fingerprint extension is available');
my $dir = EV::WebKit::Fingerprint::_so_dir();
ok(-e "$dir/evwk_fp.so", "the .so exists in the located dir ($dir)");

done_testing;
```

- [ ] **Step 4: Build and run**

Run:
```bash
cd /home/yk/dev/perl-modules/EV-WebKit
perl Makefile.PL && make 2>&1 | tail -5
TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t
```
Expected: `make` reports building the extension; `t/99` PASSES (2 assertions). (If your toolchain lacks glib, it SKIPS -- run the spike from Task 1 to confirm the toolchain, since this feature needs it.)

- [ ] **Step 5: Commit**

```bash
git add Makefile.PL lib/EV/WebKit/Fingerprint.pm t/99-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: Makefile.PL builds+installs the .so; Fingerprint::available/_so_dir"
```

---

## Task 3: Fingerprint.pm -- presets, resolution, validation, GVariant

The pure-Perl core: resolve a `fingerprint =>` argument to a profile, validate it, and build the GVariant. Unit-testable without a browser.

**Files:**
- Modify: `lib/EV/WebKit/Fingerprint.pm`
- Test: `t/99-fingerprint.t` (add unit tests)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `EV::WebKit::Fingerprint::profiles()` -> list of preset names (sorted).
  - `EV::WebKit::Fingerprint::resolve($arg)` -> validated profile hashref (`$arg` is a preset name string or `{ profile => name, <overrides> }`); croaks on unknown preset/field/type or a missing `.so`... (NB: the `.so`/user_agent-conflict checks live in the constructor, Task 4; `resolve` does preset+override+type validation only).
  - `EV::WebKit::Fingerprint::gvariant($profile)` -> a `Glib::Variant` `a{sv}` of present, non-`user_agent` keys.
  - Field set (the profile hash keys): `user_agent platform vendor languages hardwareConcurrency deviceMemory maxTouchPoints screen devicePixelRatio webgl_vendor webgl_renderer`. `screen` is `[w,h]` or `[w,h,availW,availH,colorDepth]`.

- [ ] **Step 1: Write the failing unit tests**

Add to `t/99-fingerprint.t` (before `done_testing`):

```perl
# --- resolution + validation (pure Perl, no browser) ---
my @names = EV::WebKit::Fingerprint::profiles();
ok(scalar(@names) >= 4, 'at least four presets');
ok((grep { $_ eq 'windows-chrome' } @names), 'windows-chrome preset present');

my $p = EV::WebKit::Fingerprint::resolve('windows-chrome');
is(ref $p, 'HASH', 'resolve(name) -> hashref');
is($p->{platform}, 'Win32', 'windows-chrome platform');
like($p->{user_agent}, qr/Windows NT/, 'windows-chrome UA looks like Windows');

my $o = EV::WebKit::Fingerprint::resolve({ profile => 'windows-chrome', deviceMemory => 16, screen => [1920,1080] });
is($o->{deviceMemory}, 16,             'override applied (deviceMemory)');
is_deeply($o->{screen}, [1920,1080],   'override applied (screen)');
is($o->{platform}, 'Win32',            'non-overridden field kept from preset');

eval { EV::WebKit::Fingerprint::resolve('no-such-device') };
like($@, qr/unknown fingerprint profile/, 'unknown preset croaks');
eval { EV::WebKit::Fingerprint::resolve({ profile => 'windows-chrome', bogus => 1 }) };
like($@, qr/unknown fingerprint field/,   'unknown override field croaks');
eval { EV::WebKit::Fingerprint::resolve({ profile => 'windows-chrome', platform => ['x'] }) };
like($@, qr/platform.*must be a string/,  'wrong-typed override croaks');

my $gv = EV::WebKit::Fingerprint::gvariant($o);
isa_ok($gv, 'Glib::Variant', 'gvariant() returns a Glib::Variant');
my $printed = $gv->print(1);
like($printed, qr/'platform'/,   'gvariant carries platform');
unlike($printed, qr/user_agent/, 'gvariant does NOT carry user_agent (goes via set_user_agent)');
like($printed, qr/screen_width/, 'gvariant flattens screen to screen_width');
```

- [ ] **Step 2: Run it (RED)**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t`
Expected: FAIL -- `Undefined subroutine &EV::WebKit::Fingerprint::profiles`.

- [ ] **Step 3: Implement presets + resolve + gvariant**

In `lib/EV/WebKit/Fingerprint.pm`, add `use Carp ();` at the top and this before `1;`:

```perl
# Each preset declares ONLY the fields that real device exposes (sparse rule).
# Numbers are plain scalars; screen is [w,h] or [w,h,availW,availH,colorDepth].
my %PRESET = (
    'windows-chrome' => {
        user_agent => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        platform => 'Win32', vendor => 'Google Inc.', languages => ['en-US','en'],
        hardwareConcurrency => 8, deviceMemory => 8, maxTouchPoints => 0,
        screen => [1920,1080,1920,1040,24], devicePixelRatio => 1,
        webgl_vendor => 'Google Inc. (NVIDIA)',
        webgl_renderer => 'ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)',
    },
    'macos-safari' => {
        user_agent => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15',
        platform => 'MacIntel', vendor => 'Apple Computer, Inc.', languages => ['en-US','en'],
        hardwareConcurrency => 10, maxTouchPoints => 0,   # Safari omits deviceMemory
        screen => [1512,982,1512,944,30], devicePixelRatio => 2,
        webgl_vendor => 'Apple', webgl_renderer => 'Apple GPU',
    },
    'iphone-safari' => {
        user_agent => 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1',
        platform => 'iPhone', vendor => 'Apple Computer, Inc.', languages => ['en-US','en'],
        hardwareConcurrency => 6, maxTouchPoints => 5,
        screen => [390,844,390,844,24], devicePixelRatio => 3,
        webgl_vendor => 'Apple', webgl_renderer => 'Apple GPU',
    },
    'pixel-chrome' => {
        user_agent => 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        platform => 'Linux armv8l', vendor => 'Google Inc.', languages => ['en-US','en'],
        hardwareConcurrency => 8, deviceMemory => 8, maxTouchPoints => 5,
        screen => [412,915,412,915,24], devicePixelRatio => 2.625,
        webgl_vendor => 'Google Inc. (Qualcomm)',
        webgl_renderer => 'ANGLE (Qualcomm, Adreno (TM) 730, OpenGL ES 3.2)',
    },
);

# field => validator. 'str'/'num'/'strv'/'screen'.
my %FIELD = (
    user_agent => 'str', platform => 'str', vendor => 'str',
    webgl_vendor => 'str', webgl_renderer => 'str', languages => 'strv',
    hardwareConcurrency => 'num', deviceMemory => 'num', maxTouchPoints => 'num',
    devicePixelRatio => 'num', screen => 'screen',
);

sub profiles { return sort keys %PRESET }

sub resolve {
    my ($arg) = @_;
    my ($name, %ov);
    if (ref $arg eq 'HASH') { %ov = %$arg; $name = delete $ov{profile}; }
    elsif (!ref $arg)       { $name = $arg; }
    else { Carp::croak('fingerprint: expected a preset name or a hashref') }
    Carp::croak('fingerprint: a profile hashref needs a "profile" => <preset> base') unless defined $name;
    my $base = $PRESET{$name}
        or Carp::croak("fingerprint: unknown fingerprint profile '$name' (have: " . join(', ', profiles()) . ')');
    my %p = (%$base, %ov);   # overrides win
    for my $k (sort keys %p) {
        my $t = $FIELD{$k} or Carp::croak("fingerprint: unknown fingerprint field '$k'");
        my $v = $p{$k};
        if    ($t eq 'str')  { Carp::croak("fingerprint: $k must be a string")  if ref $v || !defined $v }
        elsif ($t eq 'num')  { Carp::croak("fingerprint: $k must be a number")  unless defined $v && !ref $v && $v =~ /\A-?\d+(?:\.\d+)?\z/ }
        elsif ($t eq 'strv') { Carp::croak("fingerprint: $k must be an arrayref of strings")
                                   unless ref $v eq 'ARRAY' && !grep { !defined || ref } @$v }
        elsif ($t eq 'screen') { Carp::croak("fingerprint: screen must be [w,h] or [w,h,availW,availH,colorDepth]")
                                   unless ref $v eq 'ARRAY' && (@$v == 2 || @$v == 5) && !grep { !defined || ref || !/\A\d+\z/ } @$v }
    }
    return \%p;
}

# Build the a{sv} GVariant of present, non-user_agent keys. screen is flattened
# to screen_width/height/availWidth/availHeight/colorDepth/pixelDepth; every
# number is a double ('d'); languages is 'as'.
sub gvariant {
    my ($p) = @_;
    my %d;
    $d{$_} = Glib::Variant->new('s', $p->{$_}) for grep { defined $p->{$_} } qw/platform vendor webgl_vendor webgl_renderer/;
    $d{languages} = Glib::Variant->new('as', $p->{languages}) if $p->{languages};
    $d{$_} = Glib::Variant->new('d', $p->{$_} + 0) for grep { defined $p->{$_} } qw/hardwareConcurrency deviceMemory maxTouchPoints devicePixelRatio/;
    if (my $s = $p->{screen}) {
        my ($w,$h,$aw,$ah,$cd) = @$s == 5 ? @$s : ($s->[0],$s->[1],$s->[0],$s->[1],24);
        $d{screen_width}       = Glib::Variant->new('d', $w);
        $d{screen_height}      = Glib::Variant->new('d', $h);
        $d{screen_availWidth}  = Glib::Variant->new('d', $aw);
        $d{screen_availHeight} = Glib::Variant->new('d', $ah);
        $d{screen_colorDepth}  = Glib::Variant->new('d', $cd);
        $d{screen_pixelDepth}  = Glib::Variant->new('d', $cd);
    }
    return Glib::Variant->new('a{sv}', \%d);
}
```

Add `use Glib ();` at the top of the module too (for `Glib::Variant`).

- [ ] **Step 4: Run it (GREEN)**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t`
Expected: PASS (the availability + unit tests).

- [ ] **Step 5: Commit**

```bash
git add lib/EV/WebKit/Fingerprint.pm t/99-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: presets + resolve/validate + gvariant builder"
```

---

## Task 4: Constructor wiring -- the fingerprint option end to end

Wire `fingerprint =>` into `new()`: resolve/validate, enforce the conflicts, set the extension dir + user-data on the context before first nav, route the UA through `set_user_agent`, and add the accessors. After this, `new(fingerprint=>'windows-chrome')` really spoofs `navigator.platform`.

**Files:**
- Modify: `lib/EV/WebKit.pm` (`%KNOWN_NEW`, `new`, add accessors + `fingerprint_available`)
- Test: `t/99-fingerprint.t` (add the end-to-end block)

**Interfaces:**
- Consumes: `EV::WebKit::Fingerprint::{resolve,gvariant,available,_so_dir}` (Tasks 2-3); `set_user_agent` (line 1286); `$self->{context}` (line 288).
- Produces: `new(fingerprint => ...)`; `$b->fingerprint` (resolved hashref or undef); `EV::WebKit->fingerprint_profiles`; `EV::WebKit::fingerprint_available()`.

- [ ] **Step 1: Write the failing end-to-end test**

Add to `t/99-fingerprint.t` (before `done_testing`):

```perl
# --- end to end via the real constructor ---
{
    my $b = EV::WebKit->new(window => [200,150], fingerprint => 'windows-chrome');
    is_deeply($b->fingerprint, EV::WebKit::Fingerprint::resolve('windows-chrome'), '$b->fingerprint returns the resolved profile');
    $b->mock_scheme('fp', sub { ('<html><body>fp</body></html>','text/html') });
    my %g;
    $b->go('fp://host/p', sub {
        $b->script('return navigator.platform', sub {
            $g{platform} = $_[0];
            $b->script('return navigator.userAgent', sub {
                $g{ua} = $_[0];
                $b->script('return Object.getOwnPropertyDescriptor(navigator,"platform").get.toString()', sub {
                    $g{tostr} = $_[0]; EV::break;
                });
            });
        });
    });
    TWK::run_with_timeout(20);
    is($g{platform}, 'Win32', 'navigator.platform spoofed via the constructor');
    like($g{ua}, qr/Windows NT/, 'navigator.userAgent matches the profile (set_user_agent path)');
    like($g{tostr}, qr/\[native code\]/, 'the platform getter is NATIVE (defeats toString detection)');
    $b->quit;
}

# conflict + availability errors
{
    eval { EV::WebKit->new(window=>[100,80], fingerprint=>'windows-chrome', user_agent=>'x') };
    like($@, qr/fingerprint.*user_agent/, 'fingerprint + user_agent croaks');
    ok(EV::WebKit::fingerprint_available(), 'fingerprint_available() true when built');
    is_deeply([EV::WebKit->fingerprint_profiles], [EV::WebKit::Fingerprint::profiles()], 'fingerprint_profiles lists presets');
}
```

- [ ] **Step 2: Run it (RED)**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t`
Expected: FAIL -- `new(fingerprint=>...)` croaks "unknown option(s): fingerprint" (not yet in `%KNOWN_NEW`).

- [ ] **Step 3: Add `fingerprint` to the known-key set**

In `lib/EV/WebKit.pm`, in `%KNOWN_NEW` (~line 174), add `fingerprint`:

```perl
my %KNOWN_NEW = map { $_ => 1 } qw(
    timeout window display
    on_load on_error on_close on_navigate on_console on_dialog on_policy
    data_dir cache_dir ephemeral cookie_jar jar_format
    proxy user_agent devtools title chrome
    fingerprint
);
```

- [ ] **Step 4: Resolve + conflict-check early in new()**

In `new()`, right after the unknown-key `croak` block (before the `bless`), add:

```perl
    my $fp;   # resolved fingerprint profile (or undef)
    if (defined $o{fingerprint}) {
        require EV::WebKit::Fingerprint;
        Carp::croak('EV::WebKit: fingerprint requested but the web-process extension was not built at install '
                  . '(needs cc + glib/gobject); see EV::WebKit::fingerprint_available')
            unless EV::WebKit::Fingerprint::available();
        Carp::croak('EV::WebKit: fingerprint sets the User-Agent -- pass it via fingerprint => { ..., user_agent => ... } '
                  . 'instead of a separate user_agent option')
            if defined $o{user_agent};
        $fp = EV::WebKit::Fingerprint::resolve($o{fingerprint});
    }
```

- [ ] **Step 5: Store the profile and wire the context**

In the `bless {...}` hash add `fingerprint => $fp,` (so `$b->fingerprint` works). Then immediately AFTER `my $context = $self->{context} = WebKit::WebContext->new;` (~line 288) add:

```perl
    if ($fp) {
        $context->set_web_process_extensions_directory(EV::WebKit::Fingerprint::_so_dir());
        $context->set_web_process_extensions_initialization_user_data(EV::WebKit::Fingerprint::gvariant($fp));
    }
```

- [ ] **Step 6: Route the profile UA through set_user_agent**

Find the existing UA line (~292): `$self->set_user_agent($o{user_agent}) if defined $o{user_agent};` and change it to also apply the profile UA:

```perl
    my $ua = $fp ? $fp->{user_agent} : $o{user_agent};
    $self->set_user_agent($ua) if defined $ua;   # native: sets the header AND navigator.userAgent
```

- [ ] **Step 7: Add the accessors**

After `sub set_user_agent { ... }` (or near the other simple accessors), add:

```perl
sub fingerprint          { $_[0]->{fingerprint} }
sub fingerprint_profiles { shift; require EV::WebKit::Fingerprint; EV::WebKit::Fingerprint::profiles() }
sub fingerprint_available { require EV::WebKit::Fingerprint; EV::WebKit::Fingerprint::available() }
```

(`fingerprint_available` is called both as `EV::WebKit::fingerprint_available()` and would work as a method; the test uses the function form.)

- [ ] **Step 8: Run it (GREEN)**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t`
Expected: PASS -- `navigator.platform` is `Win32`, the UA matches, the getter is `[native code]`, and the conflict croaks.

- [ ] **Step 9: Commit**

```bash
git add lib/EV/WebKit.pm t/99-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: constructor wiring (option, context, UA coherence, accessors)"
```

---

## Task 5: Expand the .so -- all navigator/screen/devicePixelRatio getters + languages

Grow `wext/evwk_fp.c` from the two-field seed to the full core set. Strings and numbers use the proven pattern; `languages` (a JS array) and `screen`/`devicePixelRatio` (on different objects) are the new shapes.

**Files:**
- Modify: `wext/evwk_fp.c`
- Test: `t/99-fingerprint.t` (add the full-coverage block)

**Interfaces:**
- Consumes: the GVariant schema (Global Constraints).
- Produces: native getters for `navigator.{platform,vendor,languages,hardwareConcurrency,deviceMemory,maxTouchPoints}`, `screen.{width,height,availWidth,availHeight,colorDepth,pixelDepth}`, `window.devicePixelRatio`.

- [ ] **Step 1: Write the failing coverage test**

Add to `t/99-fingerprint.t` (before `done_testing`):

```perl
# --- full core coverage + the sparse rule ---
{
    my $b = EV::WebKit->new(window => [200,150], fingerprint => 'macos-safari');  # omits deviceMemory
    $b->mock_scheme('fp2', sub { ('<html><body>fp2</body></html>','text/html') });
    my %g;
    my $read = sub {
        my ($key, $js, $next) = @_;
        $b->script($js, sub { $g{$key} = $_[0]; $next->() });
    };
    $b->go('fp2://host/p', sub {
        $read->('vendor', 'return navigator.vendor', sub {
        $read->('langs',  'return JSON.stringify(navigator.languages)', sub {
        $read->('cores',  'return navigator.hardwareConcurrency', sub {
        $read->('touch',  'return navigator.maxTouchPoints', sub {
        $read->('devmem', 'return navigator.deviceMemory === undefined ? "UNDEF" : navigator.deviceMemory', sub {
        $read->('sw',     'return screen.width', sub {
        $read->('dpr',    'return window.devicePixelRatio', sub {
        $read->('lnative','return Object.getOwnPropertyDescriptor(Navigator.prototype,"languages") ? "?" : Object.getOwnPropertyDescriptor(navigator,"languages").get.toString()', sub {
            EV::break;
        }); }); }); }); }); }); }); });
    });
    TWK::run_with_timeout(25);
    is($g{vendor}, 'Apple Computer, Inc.',         'navigator.vendor spoofed');
    is($g{langs},  '["en-US","en"]',               'navigator.languages spoofed (array)');
    is($g{cores},  10,                             'navigator.hardwareConcurrency spoofed');
    is($g{touch},  0,                              'navigator.maxTouchPoints spoofed');
    is($g{devmem}, 'UNDEF',                        'deviceMemory absent (sparse rule: macos-safari omits it)');
    is($g{sw},     1512,                           'screen.width spoofed');
    is($g{dpr},    2,                              'window.devicePixelRatio spoofed');
    like($g{lnative}, qr/\[native code\]/,         'the languages getter is native too');
    $b->quit;
}
```

- [ ] **Step 2: Run it (RED)**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t`
Expected: FAIL -- `vendor`/`languages`/`screen.width`/etc. are the REAL values (only `platform`/`hardwareConcurrency` are wired so far).

- [ ] **Step 3: Expand the C -- Profile struct + parsing**

In `wext/evwk_fp.c`, replace the `Profile P;` struct and the two getters with the full set. Add these hand-declared prototypes near the others:

```c
extern JSCValue *jsc_value_new_array_from_strv (JSCContext *, const char * const *);
```

Replace the `typedef struct { ... } Profile; static Profile P;` block with:

```c
typedef struct {
    char *platform, *vendor, *webgl_vendor, *webgl_renderer;
    char **languages;                                  /* NULL-terminated, or NULL */
    gboolean has_hwc, has_devmem, has_touch, has_dpr;
    double hwc, devmem, touch, dpr;
    gboolean has_sw, has_sh, has_aw, has_ah, has_cd, has_pd;
    double sw, sh, aw, ah, cd, pd;
} Profile;
static Profile P;
```

- [ ] **Step 4: Expand the C -- getters**

Replace `get_platform`/`get_hwc` with the full set (strings return `char*`, numbers return `gdouble`, `languages` returns a JS array built in the frame's context -- so it needs the context, captured per-callback via a small holder):

```c
static char *g_platform (void*a,void*b){(void)a;(void)b; return g_strdup(P.platform);}
static char *g_vendor   (void*a,void*b){(void)a;(void)b; return g_strdup(P.vendor);}
static gdouble g_hwc    (void*a,void*b){(void)a;(void)b; return P.hwc;}
static gdouble g_devmem (void*a,void*b){(void)a;(void)b; return P.devmem;}
static gdouble g_touch  (void*a,void*b){(void)a;(void)b; return P.touch;}
static gdouble g_dpr    (void*a,void*b){(void)a;(void)b; return P.dpr;}
static gdouble g_sw(void*a,void*b){(void)a;(void)b; return P.sw;}
static gdouble g_sh(void*a,void*b){(void)a;(void)b; return P.sh;}
static gdouble g_aw(void*a,void*b){(void)a;(void)b; return P.aw;}
static gdouble g_ah(void*a,void*b){(void)a;(void)b; return P.ah;}
static gdouble g_cd(void*a,void*b){(void)a;(void)b; return P.cd;}
static gdouble g_pd(void*a,void*b){(void)a;(void)b; return P.pd;}
/* languages: build a fresh JS array in the current context. user_data carries
 * the JSCContext captured when the accessor was installed. */
static JSCValue *g_langs (void *instance, gpointer ctx){(void)instance;
    return jsc_value_new_array_from_strv ((JSCContext*)ctx, (const char* const*)P.languages);}

/* helpers */
static void def_str (JSCValue *o, const char *n, GCallback g) {
    jsc_value_object_define_property_accessor (o, n, JSC_VALUE_PROPERTY_CONFIGURABLE, G_TYPE_STRING, g, NULL, NULL, NULL);
}
static void def_num (JSCValue *o, const char *n, GCallback g) {
    jsc_value_object_define_property_accessor (o, n, JSC_VALUE_PROPERTY_CONFIGURABLE, G_TYPE_DOUBLE, g, NULL, NULL, NULL);
}
```

- [ ] **Step 5: Expand the C -- install callback**

Replace `on_window_object_cleared` with:

```c
extern GType jsc_value_get_type (void);   /* for the languages accessor return type */

static void on_window_object_cleared (WebKitScriptWorld *world, WebKitWebPage *page,
                                      WebKitFrame *frame, gpointer ud)
{
    (void)page;(void)ud;
    JSCContext *ctx = webkit_frame_get_js_context_for_script_world (frame, world);
    if (!ctx) return;
    JSCValue *global = jsc_context_get_global_object (ctx);
    if (!global) return;
    JSCValue *nav = jsc_value_object_get_property (global, "navigator");
    if (nav) {
        if (P.platform) def_str (nav, "platform", G_CALLBACK (g_platform));
        if (P.vendor)   def_str (nav, "vendor",   G_CALLBACK (g_vendor));
        if (P.has_hwc)    def_num (nav, "hardwareConcurrency", G_CALLBACK (g_hwc));
        if (P.has_devmem) def_num (nav, "deviceMemory",        G_CALLBACK (g_devmem));
        if (P.has_touch)  def_num (nav, "maxTouchPoints",      G_CALLBACK (g_touch));
        if (P.languages)
            jsc_value_object_define_property_accessor (nav, "languages",
                JSC_VALUE_PROPERTY_CONFIGURABLE, jsc_value_get_type (),
                G_CALLBACK (g_langs), NULL, ctx, NULL);
    }
    JSCValue *screen = jsc_value_object_get_property (global, "screen");
    if (screen) {
        if (P.has_sw) def_num (screen, "width",       G_CALLBACK (g_sw));
        if (P.has_sh) def_num (screen, "height",      G_CALLBACK (g_sh));
        if (P.has_aw) def_num (screen, "availWidth",  G_CALLBACK (g_aw));
        if (P.has_ah) def_num (screen, "availHeight", G_CALLBACK (g_ah));
        if (P.has_cd) def_num (screen, "colorDepth",  G_CALLBACK (g_cd));
        if (P.has_pd) def_num (screen, "pixelDepth",  G_CALLBACK (g_pd));
    }
    if (P.has_dpr) def_num (global, "devicePixelRatio", G_CALLBACK (g_dpr));
}
```

- [ ] **Step 6: Expand the C -- parse all fields**

Replace the body of `webkit_web_process_extension_initialize_with_user_data` with:

```c
void webkit_web_process_extension_initialize_with_user_data (WebKitWebProcessExtension *ext,
                                                             GVariant *ud)
{
    (void)ext;
    if (ud) {
        const char *s;
        if (g_variant_lookup (ud, "platform",       "&s", &s) && s) P.platform       = g_strdup (s);
        if (g_variant_lookup (ud, "vendor",         "&s", &s) && s) P.vendor         = g_strdup (s);
        if (g_variant_lookup (ud, "webgl_vendor",   "&s", &s) && s) P.webgl_vendor   = g_strdup (s);
        if (g_variant_lookup (ud, "webgl_renderer", "&s", &s) && s) P.webgl_renderer = g_strdup (s);
        GVariant *langs = g_variant_lookup_value (ud, "languages", G_VARIANT_TYPE ("as"));
        if (langs) { P.languages = g_variant_dup_strv (langs, NULL); g_variant_unref (langs); }
        double d;
        if (g_variant_lookup (ud, "hardwareConcurrency", "d", &d)) { P.has_hwc=TRUE;    P.hwc=d; }
        if (g_variant_lookup (ud, "deviceMemory",        "d", &d)) { P.has_devmem=TRUE; P.devmem=d; }
        if (g_variant_lookup (ud, "maxTouchPoints",      "d", &d)) { P.has_touch=TRUE;  P.touch=d; }
        if (g_variant_lookup (ud, "devicePixelRatio",    "d", &d)) { P.has_dpr=TRUE;    P.dpr=d; }
        if (g_variant_lookup (ud, "screen_width",        "d", &d)) { P.has_sw=TRUE; P.sw=d; }
        if (g_variant_lookup (ud, "screen_height",       "d", &d)) { P.has_sh=TRUE; P.sh=d; }
        if (g_variant_lookup (ud, "screen_availWidth",   "d", &d)) { P.has_aw=TRUE; P.aw=d; }
        if (g_variant_lookup (ud, "screen_availHeight",  "d", &d)) { P.has_ah=TRUE; P.ah=d; }
        if (g_variant_lookup (ud, "screen_colorDepth",   "d", &d)) { P.has_cd=TRUE; P.cd=d; }
        if (g_variant_lookup (ud, "screen_pixelDepth",   "d", &d)) { P.has_pd=TRUE; P.pd=d; }
    }
    g_signal_connect (webkit_script_world_get_default (), "window-object-cleared",
                      G_CALLBACK (on_window_object_cleared), NULL);
}
```

- [ ] **Step 7: Rebuild and run (GREEN)**

Run:
```bash
cd /home/yk/dev/perl-modules/EV-WebKit
make 2>&1 | tail -3   # recompiles wext -> share/wext/evwk_fp.so
TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t
```
Expected: PASS -- vendor/languages/cores/touch/screen/dpr all spoofed; `deviceMemory` UNDEF (sparse rule); languages getter native. If `languages` fails to marshal, check `jsc_value_new_array_from_strv` and that the accessor return type is `jsc_value_get_type()`.

- [ ] **Step 8: Commit**

```bash
git add wext/evwk_fp.c t/99-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: full navigator/screen/devicePixelRatio + languages native getters"
```

---

## Task 6: WebGL getParameter -- replace the method, spoof the GPU strings

The one method (not property) case: replace `WebGL{,2}RenderingContext.prototype.getParameter` with a native function that returns the profile's GPU strings for the two UNMASKED pnames and delegates to the original otherwise.

**Files:**
- Modify: `wext/evwk_fp.c`
- Test: `t/99-fingerprint.t` (add the WebGL block)

**Interfaces:**
- Consumes: `P.webgl_vendor`, `P.webgl_renderer`.
- Produces: spoofed `getParameter(0x9245)` / `getParameter(0x9246)` with delegation for every other pname.

- [ ] **Step 1: Write the failing WebGL test**

Add to `t/99-fingerprint.t` (before `done_testing`):

```perl
{
    my $b = EV::WebKit->new(window => [200,150], fingerprint => 'windows-chrome');
    $b->mock_scheme('fp3', sub { ('<html><body><canvas id=c></canvas></body></html>','text/html') });
    my %g;
    my $js = <<'JS';
      const gl = document.getElementById('c').getContext('webgl');
      const ext = gl.getExtension('WEBGL_debug_renderer_info');
      return JSON.stringify({
        renderer: gl.getParameter(ext.UNMASKED_RENDERER_WEBGL),
        vendor:   gl.getParameter(ext.UNMASKED_VENDOR_WEBGL),
        real_ver: typeof gl.getParameter(gl.VERSION),           // delegation still works
        native:   gl.getParameter.toString().includes('[native code]'),
      });
JS
    $b->go('fp3://host/p', sub { $b->script($js, sub { $g{r} = $_[0]; EV::break }) });
    TWK::run_with_timeout(20);
    my $r = eval { require Cpanel::JSON::XS; Cpanel::JSON::XS::decode_json($g{r}) } || {};
    like($r->{renderer}, qr/RTX 3060/,   'WebGL UNMASKED_RENDERER spoofed');
    like($r->{vendor},   qr/NVIDIA/,      'WebGL UNMASKED_VENDOR spoofed');
    is($r->{real_ver},   'string',        'a non-spoofed getParameter still delegates (returns the real VERSION string)');
    ok($r->{native},                      'the replaced getParameter reports [native code]');
    $b->quit;
}
```

- [ ] **Step 2: Run it (RED)**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t`
Expected: FAIL -- renderer/vendor are the real (llvmpipe/Mesa) strings.

- [ ] **Step 3: Add the JSC prototypes for the method swap**

In `wext/evwk_fp.c`, add these hand-declared prototypes near the others:

```c
extern JSCValue *jsc_context_evaluate (JSCContext *, const char *, gssize);
extern JSCValue *jsc_value_new_function (JSCContext *, const char *name, GCallback, gpointer, GDestroyNotify, GType return_type, guint n_params, ...);
extern JSCValue *jsc_value_function_callv (JSCValue *, guint n, JSCValue **);
extern JSCValue *jsc_value_new_string (JSCContext *, const char *);
extern gboolean  jsc_value_is_number (JSCValue *);
extern double    jsc_value_to_double (JSCValue *);
extern JSCValue *jsc_value_object_get_property (JSCValue *, const char *);
extern void      jsc_value_object_set_property (JSCValue *, const char *, JSCValue *);
```

- [ ] **Step 4: Add the getParameter replacement**

Add before `on_window_object_cleared`:

```c
#define GL_UNMASKED_VENDOR_WEBGL   0x9245
#define GL_UNMASKED_RENDERER_WEBGL 0x9246

/* per-context holder for the original getParameter, keyed nowhere fancy: we
 * stash it as an own property on the replacement's context via a closure arg. */
typedef struct { JSCContext *ctx; JSCValue *orig; } GPHolder;

static JSCValue *gp_replacement (JSCValue *pname, gpointer user_data)
{
    GPHolder *h = user_data;
    if (jsc_value_is_number (pname)) {
        int p = (int) jsc_value_to_double (pname);
        if (p == GL_UNMASKED_RENDERER_WEBGL && P.webgl_renderer)
            return jsc_value_new_string (h->ctx, P.webgl_renderer);
        if (p == GL_UNMASKED_VENDOR_WEBGL && P.webgl_vendor)
            return jsc_value_new_string (h->ctx, P.webgl_vendor);
    }
    JSCValue *args[1] = { pname };
    return jsc_value_function_callv (h->orig, 1, args);   /* delegate */
}

/* Replace proto.getParameter (proto named by JS expr `expr`) if it exists. */
static void swap_getparameter (JSCContext *ctx, const char *proto_expr)
{
    JSCValue *proto = jsc_context_evaluate (ctx, proto_expr, -1);
    if (!proto) return;
    JSCValue *orig = jsc_value_object_get_property (proto, "getParameter");
    if (!orig) return;
    GPHolder *h = g_new0 (GPHolder, 1);
    h->ctx = ctx; h->orig = orig;
    JSCValue *fn = jsc_value_new_function (ctx, "getParameter",
        G_CALLBACK (gp_replacement), h, (GDestroyNotify) g_free,
        jsc_value_get_type (), 1, jsc_value_get_type ());
    jsc_value_object_set_property (proto, "getParameter", fn);
}
```

- [ ] **Step 5: Call the swap from the install callback**

At the end of `on_window_object_cleared` (after the `devicePixelRatio` line), add:

```c
    if (P.webgl_vendor || P.webgl_renderer) {
        swap_getparameter (ctx, "WebGLRenderingContext.prototype");
        swap_getparameter (ctx, "WebGL2RenderingContext.prototype");
    }
```

- [ ] **Step 6: Rebuild and run (GREEN)**

Run:
```bash
cd /home/yk/dev/perl-modules/EV-WebKit
make 2>&1 | tail -3
TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t
```
Expected: PASS -- renderer/vendor spoofed, `VERSION` still a real string (delegation), getParameter native. If the swap crashes or does not spoof, check `jsc_value_new_function`'s varargs (return type + one number param) and that `jsc_context_evaluate("WebGLRenderingContext.prototype")` resolves in the frame world.

- [ ] **Step 7: Commit**

```bash
git add wext/evwk_fp.c t/99-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: native WebGL getParameter override (GPU vendor/renderer) with delegation"
```

---

## Task 7: Presets smoke, POD, Changes, MANIFEST

Finalize: a per-preset smoke test, the honest ceiling in POD, and packaging.

**Files:**
- Modify: `lib/EV/WebKit.pm` (POD), `Changes`, `MANIFEST`
- Test: `t/99-fingerprint.t` (per-preset smoke)

**Interfaces:** none new.

- [ ] **Step 1: Add a per-preset smoke test**

Add to `t/99-fingerprint.t` (before `done_testing`):

```perl
# every preset loads and reports its own platform natively (coherence smoke).
for my $name (EV::WebKit::Fingerprint::profiles()) {
    my $want = EV::WebKit::Fingerprint::resolve($name)->{platform};
    my $b = EV::WebKit->new(window => [200,150], fingerprint => $name);
    $b->mock_scheme('sm', sub { ('<html><body>x</body></html>','text/html') });
    my $got;
    $b->go('sm://host/p', sub { $b->script('return navigator.platform', sub { $got = $_[0]; EV::break }) });
    TWK::run_with_timeout(20);
    is($got, $want, "preset '$name' applies its platform ($want)");
    $b->quit;
}
```

- [ ] **Step 2: Run it (GREEN)**

Run: `TMPDIR="$PWD/.tmp" xvfb-run -a prove -lv t/99-fingerprint.t`
Expected: PASS -- one assertion per preset.

- [ ] **Step 3: Add POD**

In `lib/EV/WebKit.pm`, in the CONSTRUCTOR `=over` (near the other options), add:

```pod
=item C<< fingerprint => 'windows-chrome' >> or C<< fingerprint => { profile => 'windows-chrome', ... } >>

Present this instance as a coherent real device at the JavaScript layer, using
NATIVE property getters (installed by a bundled web-process extension) that
report C<[native code]> and so defeat the C<toString> detection a pure-JS
override cannot. A preset name selects a shipped profile; a hashref takes a
preset as its C<profile> base and overrides individual fields. Construct-time
only (the device cannot change mid-session). Passing both C<fingerprint> and
C<user_agent> croaks -- the profile sets the UA; override it via
C<< fingerprint => { ..., user_agent => ... } >>.

Requires the web-process extension, compiled at install if C<cc> + glib/gobject
are present; check L</fingerprint_available>. B<Ceiling:> this spoofs the
JS-property layer (C<navigator>, C<screen>, WebGL vendor/renderer) only. It does
NOT touch canvas/WebGL-pixel or AudioContext hashes, or network-layer
fingerprints (TLS JA3, HTTP/2) -- a determined fingerprinter still sees those,
and a self-consistent B<custom> profile is your responsibility.

=back

=head2 fingerprint

    my $profile = $b->fingerprint;   # resolved hashref, or undef

The resolved fingerprint profile for this instance (read-only), or C<undef>.

=head2 fingerprint_profiles

    my @names = EV::WebKit->fingerprint_profiles;

The names of the shipped presets.

=head2 fingerprint_available

    EV::WebKit::fingerprint_available() or warn "no fingerprint support";

Whether the web-process extension was built at install.
```

(Place `fingerprint`/`fingerprint_profiles`/`fingerprint_available` as `=head2` entries under METHODS; the `=item`/`=back` above closes the CONSTRUCTOR list -- match the surrounding structure so `t/90-pod.t` stays green.)

- [ ] **Step 4: Changes + MANIFEST**

Add to `Changes` under `0.01`:

```
        - fingerprint => : present as a coherent real device (navigator/screen/WebGL) via native [native code] getters installed by a bundled C web-process extension (compiled at install against glib/gobject; degrades gracefully). Presets windows-chrome/macos-safari/iphone-safari/pixel-chrome, overridable; construct-time; JS-property + toString layer only (canvas/audio/TLS untouched)
```

Add to `MANIFEST` (keep ordering):
```
wext/evwk_fp.c
lib/EV/WebKit/Fingerprint.pm
t/99-fingerprint.t
xt/fingerprint-spike.pl
```

- [ ] **Step 5: Full suite + POD check**

Run:
```bash
cd /home/yk/dev/perl-modules/EV-WebKit
TMPDIR="$PWD/.tmp" xvfb-run -a prove -l t/90-pod.t t/99-fingerprint.t
TMPDIR="$PWD/.tmp" xvfb-run -a prove -l t/
```
Expected: POD clean; `t/99` all green; the whole suite green (58 files) with no regression.

- [ ] **Step 6: Commit**

```bash
git add lib/EV/WebKit.pm Changes MANIFEST t/99-fingerprint.t
git -c user.name=vividsnow -c user.email=vividsnow@pm.me commit -m "fingerprint: per-preset smoke, POD (with the honest ceiling), Changes, MANIFEST"
```

---

## Self-review notes

- **Spec coverage:** API + presets + override (Tasks 3-4), sparse rule (Tasks 3+5, tested via macos-safari deviceMemory), coverage navigator/screen/WebGL (Tasks 5-6), UA coherence (Task 4), build + degrade + availability (Task 2), the flagged Perl->GVariant->C spike is Task 1, errors (Tasks 3-4), ceiling in POD (Task 7). All spec sections map to a task.
- **Type consistency:** `Fingerprint::{profiles,resolve,gvariant,available,_so_dir}` used identically across tasks; the GVariant keys/types in Task 3's `gvariant()` match Task 5's `g_variant_lookup` parsing exactly (all numbers `d`; `languages` `as`; `screen_*` flattened); `%KNOWN_NEW` gains `fingerprint` (Task 4) so the option is accepted; the `.so` basename `evwk_fp.so` and its dir are consistent between Makefile.PL, `_so_dir`, and the wiring.
- **Known JSC-API risks (surfaced, not hidden):** `jsc_value_new_array_from_strv` (languages, Task 5) and `jsc_value_new_function` + `jsc_value_function_callv` (getParameter, Task 6) are the two mechanisms the original spike did not exercise; each task's RED/GREEN asserts the spoofed value, so a wrong signature fails loudly there. Task 1 de-risks the handoff (the higher-level risk) before any of this.
