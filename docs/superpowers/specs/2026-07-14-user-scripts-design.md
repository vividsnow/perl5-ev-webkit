# EV::WebKit user-script injection -- design

Date: 2026-07-14
Status: approved, ready for an implementation plan

## Problem

`EV::WebKit` injects JS into pages internally (the isolated-world `$BOOT` that
powers the element registry, the `on_console` proxy), but a caller has no public
way to inject their own JS or CSS. This is the injection primitive that two
planned features -- fingerprint spoofing and uBlock cosmetic filtering -- build
on, and it is useful on its own (Greasemonkey-style page scripts, injected
styling).

## API

Per-instance methods; each `add_*` returns a handle with `->remove`.

```perl
# scripts
my $h = $b->add_user_script($source, %opts);
#   at     => 'end'  (default) | 'start'     when it runs relative to page JS
#   world  => 'main' (default) | 'isolated'  main sees page globals; isolated
#                                            shares only the DOM (its own globals)
#   frames => 'all'  (default) | 'top'       all frames vs the top document only
#   allow  => [ '*://*.example.com/*', ... ] optional URL allow-list (globs)
#   deny   => [ ... ]                         optional URL deny-list (globs)
$h->remove;                    # remove just this script; idempotent
$b->remove_all_user_scripts;   # remove every script YOU added

# styles (CSS)
my $s = $b->add_user_style($css, %opts);
#   frames, allow, deny   as above
#   level  => 'author' (default) | 'user'    user level beats page CSS (for hiding)
$s->remove;
$b->remove_all_user_styles;
```

Scripts and styles are per-instance and take effect from the **next
navigation** -- WebKit injects user content at load time, so adding one does not
retroactively affect the page already showing (the same behaviour the console
proxy has today). This is documented on each method.

### Defaults (settled)

- `at` = `end` (the Greasemonkey/Tampermonkey convention: the DOM exists, so the
  common DOM-touching script just works; override with `start` to beat the
  page's own code).
- `world` = `main`.
- `frames` = `all`.
- `level` (styles) = `author`.

### Value mapping (friendly option -> WebKit GI nick)

The public options are friendly short strings; the native constructors want
WebKit's GObject-Introspection enum nicks. The map:

- `at`: `start` -> `'start'`, `end` -> `'end'` (pass-through; `WebKitUserScriptInjectionTime`).
- `frames`: `all` -> `'all-frames'`, `top` -> `'top-frame'` (`WebKitUserContentInjectedFrames`).
- `level` (styles): `author` -> `'author'`, `user` -> `'user'` (pass-through; `WebKitUserStyleLevel`).
- `world`: `main` -> `new(...)`, `isolated` -> `new_for_world(..., $USER_WORLD, ...)` (dispatch, not a nick).

Only `frames` actually renames; the others pass through but are still validated
against the known set so a typo croaks rather than reaching WebKit as a bad nick.

### World handling

- `main` -> `WebKit::UserScript->new($src, $frames_nick, $at_nick, $allow, $deny)`.
- `isolated` -> `WebKit::UserScript->new_for_world($src, $frames_nick, $at_nick,
  $USER_WORLD, $allow, $deny)`, where `$USER_WORLD` is a dedicated name
  (`EVWebKitUser`) DISTINCT from the module's private `$EVWK_WORLD`
  (`EVWebKit`). A user script must never be able to see or corrupt the element
  registry. Styles have no world (WebKit's `UserStyleSheet` takes none):
  `WebKit::UserStyleSheet->new($css, $frames_nick, $level_nick, $allow, $deny)`.

## Internals

- `add_user_script` builds the native `WebKit::UserScript`, calls
  `$ucm->add_script`, records it in `$self->{_user_scripts}` (an id-keyed
  registry), and returns a handle.
- The handle is a small blessed object holding a WEAK ref to the browser, the
  native script, and a `removed` flag. `$h->remove`: if not already removed and
  the browser is alive, `$ucm->remove_script($native)`, drop it from the
  registry, mark removed. Idempotent -- a second call, or a call after `quit`,
  is a clean no-op.
- No reference cycle: the browser strongly holds the native scripts (so
  `remove_all_user_*` can find them); native scripts do not point back at the
  browser; the handle's browser ref is weak, so a dangling handle does not keep
  the instance alive (the module's collectability bar).
- Styles are fully symmetric: their own `{_user_styles}` registry, `add_style_sheet`
  / `remove_style_sheet` on the UCM, the same handle shape (only `->remove` calls
  `remove_style_sheet` instead of `remove_script`).
- `quit`/teardown clears `{_user_scripts}` and `{_user_styles}`.

### The one subtle safety property

The module injects its OWN scripts through the same UCM: the isolated-world
`$BOOT` that `find`/`find_all`/`html`/`wait_for`/element accessors depend on, and
the console proxy. WebKit's `remove_all_scripts` wipes ALL scripts, the module's
included -- verified live: after `remove_all_scripts`, `find()` breaks with
`window.__evwk is undefined`.

Therefore `remove_all_user_scripts` must NOT call `remove_all_scripts`. It loops
`remove_script` over only the registry of scripts the caller added. The module's
own injections are never in that registry, so they are untouchable. (Per-script
`remove_script` and `remove_style_sheet` exist in this WebKitGTK and were
verified to remove one script without affecting the others or the module's BOOT.)

## Errors

Croak at the call site (the module's convention):

- `undef` source.
- an unknown `at` / `world` / `frames` / `level` value -- so a typo cannot
  silently map to the wrong WebKit enum (the same reason `settings` validates).
- `allow` / `deny` that is not an arrayref of strings.

An empty-string source is allowed (harmless no-op).

## Testing

All under `xvfb-run`, `mock_scheme` pages.

- **start vs end:** a `start` script sets a global that the page's own inline
  `<script>` reads (proving it ran first); an `end` script reads the DOM (proving
  the DOM exists).
- **main vs isolated:** a main-world global is visible via `script()`; an
  isolated-world global is NOT visible to the page, yet the isolated script can
  still read/modify the DOM.
- **remove:** after `$h->remove`, the next navigation does not inject it.
- **remove_all_user_scripts + the clobber test:** it removes the user scripts,
  and `find()` (which needs the module's own BOOT) still works afterwards -- the
  regression guard for never calling `remove_all_scripts`.
- **CSS:** `add_user_style('h1 { display:none !important }', level => 'user')`
  hides the element (checked via `is_visible`); `->remove` restores it next nav.
- **allow/deny:** a script with `allow => [one origin]` runs there and not on a
  different origin.
- **validation:** undef source, a bad enum value, and a non-arrayref allow each
  croak.
- **collectability:** a handle outliving a dropped browser does not keep it
  alive (weaken check); `->remove` after `quit` is a no-op.

## Not in scope

No constructor option (`user_scripts => [...]`) -- the method is the primitive,
and the consumers (fingerprint, uBO) add programmatically. No file-based scripts
(the caller reads the file). No `@match`/userscript-metadata parsing (the caller
passes `allow`/`deny` directly). No per-script enable/disable toggle (remove +
re-add). The injected-bundle native-override path (fingerprint) is a separate
feature; this is the pure-JS/CSS injection primitive.
