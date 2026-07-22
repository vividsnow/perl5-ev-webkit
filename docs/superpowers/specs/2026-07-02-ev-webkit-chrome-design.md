# EV::WebKit chrome mode -- Design Spec

Date: 2026-07-02
Status: Draft for review
Author: vividsnow

## Overview

Add a built-in minimalistic browser chrome to EV::WebKit via a `chrome => 1`
constructor option: a GNOME `Gtk4::HeaderBar` (back / forward / reload buttons +
an address bar) around the existing WebView. Also add the small navigation API
the chrome drives (`back`/`forward`/`reload`/`stop`/`can_go_back`/`can_go_forward`),
which is generally useful for automation independent of the chrome.

Chrome mode is orthogonal to automation: the same `WebKitWebView` stays fully
scriptable (`find`/`click`/`script`/`screenshot`/...).

## Motivation

EV::WebKit already renders a real GTK4 `WebKitWebView`; under a real `$DISPLAY`
it is a visible interactive window. This adds navigation chrome so it is usable
as a minimal interactive browser, not just a bare web view. This is the deferred
follow-on from the v1 UI decision (devtools toggle + window title shipped; full
chrome was deferred).

## Navigation API (prerequisite, public)

- `back($cb?)`  -> `$view->go_back`; optional callback resolves on load-finish
  (reuses the existing `_start_nav` machinery, so it behaves like `go`).
- `forward($cb?)` -> `$view->go_forward`.
- `reload($cb?)`  -> `$view->reload`.
- `stop`          -> `$view->stop_loading` (fire-and-forget; returns `$self`).
- `can_go_back` / `can_go_forward` -> synchronous booleans
  (`$view->can_go_back` / `$view->can_go_forward`).

These are useful on their own (automation back/forward/reload), not only for the
chrome. `back`/`forward`/`reload` are teardown-guarded like the other async ops
(return `browser closed` after `quit`).

## Chrome construction (`chrome => 1`)

In `new`, when `$o{chrome}` is true, call a `_build_chrome($self)` helper AFTER
the window + view are built and BEFORE `$win->present`:

- `my $hb = Gtk4::HeaderBar->new; $win->set_titlebar($hb);`
- Back / forward / reload buttons via `Gtk4::Button->new_from_icon_name(...)`
  (icons: `go-previous-symbolic`, `go-next-symbolic`, `view-refresh-symbolic`;
  stop uses `process-stop-symbolic`). `$hb->pack_start($btn)` for each in order.
  If the icon theme is unavailable the buttons still construct (blank icon) --
  acceptable; a text label fallback may be set.
- Address entry: `my $entry = Gtk4::Entry->new; $entry->set_hexpand(1);
  $hb->set_title_widget($entry);` (centered address bar).
- Store handles on `$self->{chrome} = { hb, entry, back, forward, reload,
  loading => 0 }` so signal handlers and the load-changed updater can reach them.

## Wiring / behavior

- Address entry `activate` (Enter): read text; if it lacks a `scheme://`, prepend
  `https://`; then `$self->go($url)`.
- Button `clicked` signals: back -> `$self->back`, forward -> `$self->forward`,
  reload button -> `$self->reload` when idle or `$self->stop` when loading.
- The reload button doubles as a stop button: while a navigation is in flight it
  shows `process-stop-symbolic` and stops; otherwise it shows
  `view-refresh-symbolic` and reloads.
- A chrome-only load-changed updater (installed only when `chrome` is on, in
  addition to the core nav handler) runs on each `load-changed`:
  - on `started`/`committed`: set loading state (reload -> stop icon);
  - on `finished` (and on `load-failed`): clear loading (stop -> reload icon);
  - update the address entry to `$self->uri` -- but ONLY when the entry does not
    have keyboard focus, so it never clobbers what the user is typing;
  - update the window title to `$self->title`;
  - set back/forward button `sensitive` from `can_go_back`/`can_go_forward`.
- Everything is additive: the user's `on_load`/`on_error` callbacks still fire.

## Orthogonality to automation

The WebView is unchanged; every automation method keeps working. Chrome mode is
intended for a real display (visible window); under `xvfb-run` it renders
offscreen (harmless). No display enforcement.

## Files

- `lib/EV/WebKit.pm`: add the navigation API subs; add `_build_chrome`; call it
  from `new` when `chrome` is set; add the chrome load-changed updater (either a
  second `load-changed` connection guarded by `$self->{chrome}`, or extend the
  existing handler to also update the chrome when present).
- `t/64-nav.t`: navigation-API tests.
- `t/80-chrome.t`: chrome-mode widget-state tests.

## Testing (headless, under `xvfb-run`)

- **Navigation API** (single instance): `go A` (wait), `go B` (wait), then
  `back` -> `uri` == A; `forward` -> `uri` == B; `reload` -> still B;
  `can_go_back`/`can_go_forward` correct at each step.
- **Chrome**: `new(chrome => 1)` constructs; `$self->{chrome}{entry}` and the
  buttons exist. After `go`, the address entry `get_text` == `uri` and the window
  `get_title` == page title; after two navigations the back button
  `get_sensitive` is true. Navigation is driven via the methods and widget STATE
  is asserted (GTK button *clicks* are not simulated headlessly).

## Non-goals (v1 chrome)

- No tabs, bookmarks, history UI, progress bar, or menus (minimalistic).
- Not a general-purpose browser -- a minimal chrome demonstrating visible /
  interactive use.

## Risks / to-verify during planning

- `Gtk4::HeaderBar` + `set_titlebar` + `set_title_widget` GI names/signatures
  (standard GTK4 -- verify via introspection).
- `Gtk4::Button->new_from_icon_name` availability + symbolic-icon theme under the
  test display (label fallback if the icon is missing).
- `$view->go_back`/`go_forward`/`reload`/`stop_loading`/`can_go_back`/
  `can_go_forward` GI names.
- Reading the address entry's focus state to avoid clobbering user typing
  (`$entry->has_focus` or equivalent).
