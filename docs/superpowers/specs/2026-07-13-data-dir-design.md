# EV::WebKit data_dir option -- design

Date: 2026-07-13
Status: approved, ready for an implementation plan

## Problem

`EV::WebKit` can persist COOKIES (via `cookie_jar`, or `save_cookies`/`load_cookies`
snapshots), but nothing else. A login that lives in `localStorage`, an app's
`IndexedDB` data, the HTTP cache -- all of it is lost when the instance goes
away, because the module constructs every non-ephemeral session as
`WebKit::NetworkSession->new(undef, undef)`, i.e. WebKit's DEFAULT, shared data
directory, which the caller cannot point anywhere.

So "save and restore the full session of a particular instance" is not possible
today for anything but cookies.

## What WebKit gives us (spike-verified)

`WebKit::NetworkSession->new($data_dir, $cache_dir)` with real paths produces a
persistent, non-ephemeral session that writes cookies, `localStorage`,
`IndexedDB`, the cache, mediakeys, and service-worker state under those
directories, and restores them when a session is next constructed with the same
paths. Two sessions with different directories share nothing.

Spike (temporary wiring, reverted): instance A with `data_dir => $d` set
`localStorage.k = "V42"` on a `mock_scheme` origin; the dir gained
`cache/ storage/ mediakeys/` on disk; instance B with the same `$d` read `k`
back as `"V42"`. Confirmed additionally that a `mock_scheme` (custom-scheme)
origin gets working, persistent `localStorage` -- it is NOT treated as an opaque
origin -- so the tests can use `mock_scheme` pages.

`sessionStorage` is the one exception: WebKit treats it as inherently
per-session and never persists it, `data_dir` or not.

## The option

`data_dir => $path` makes the instance's `NetworkSession` persistent and
isolated: everything above is written under `$path` and restored on the next
instance constructed with the same `$path`. Instances with different `data_dir`s
share nothing.

`cache_dir => $path` (optional) overrides where the disposable cache goes;
without it, the cache is a `cache` subdirectory inside `data_dir`. The point of
the override is that cache is regenerable -- a caller may want it on tmpfs, or
kept out of a backed-up/synced `data_dir`.

### Mechanism

The only wiring change is the `NetworkSession` construction in `new()`:

```perl
my $session = $ephemeral
    ? WebKit::NetworkSession->new_ephemeral
    : defined $o{data_dir}
        ? WebKit::NetworkSession->new(rel2abs($o{data_dir}),
                                      rel2abs($o{cache_dir} // "$o{data_dir}/cache"))
        : WebKit::NetworkSession->new(undef, undef);
```

Both paths go through `rel2abs` (as `pdf` paths already do): a path relative to
WebKit's cwd is a footgun, since cwd drifts. WebKit creates the leaf directories
itself; the parent must exist and be writable.

### Interactions

- `data_dir` forces the session non-ephemeral, exactly as `cookie_jar` already
  does -- both feed the one `$ephemeral` decision:
  `my $ephemeral = ($o{cookie_jar} || $o{data_dir}) ? 0 : (defined $o{ephemeral} ? $o{ephemeral} : 1);`
- `data_dir` + `cookie_jar` COMPOSE. `data_dir` persists everything to its own
  locations; if `cookie_jar` is also given, the existing `set_persistent_storage`
  call still runs and points COOKIES at that specific (queryable sqlite) path
  instead of the dir's default. `cookie_jar` alone is unchanged.

### Errors (croak at construction, matching the display-conflict style)

- `data_dir` + `ephemeral => 1` -- a persistent ephemeral session is a
  contradiction.
- `cache_dir` without `data_dir` -- an isolated cache with a shared data
  location defeats the isolation; almost certainly a misconfiguration.

### Documented limitation (not enforced)

Two LIVE instances pointed at the same `data_dir` in one process can corrupt
WebKit's `localStorage`/IndexedDB databases -- they are not built for concurrent
writers. Documented as "one live instance per data_dir at a time", the same way
`cookie_jar` documents not sharing a file with `save_cookies`. Detecting or
locking it is out of scope.

## Testing

All under `xvfb-run`, using `mock_scheme` pages (spike-confirmed to have
persistent storage).

- **Round-trip (the core test):** instance A (`data_dir => $d`) loads a page,
  sets `localStorage`; quit; instance B with the same `$d` reads it back.
- **Isolation:** two instances with different `data_dir`s do not see each other's
  `localStorage`.
- **Cookies via data_dir alone:** a cookie set under `data_dir` (no `cookie_jar`)
  survives a restart.
- **Cache location:** the derived `$data_dir/cache` is created; a `cache_dir`
  override lands the cache there instead, and `data_dir/cache` is not created.
- **Composability:** `data_dir` + `cookie_jar` -- `localStorage` persists AND
  cookies land in the `cookie_jar` sqlite file (queryable), both in one instance.
- **Croaks:** `data_dir` + `ephemeral => 1`; `cache_dir` without `data_dir`.
- **Relative path:** a relative `data_dir` persists correctly (rel2abs), i.e. is
  not silently interpreted against a drifting cwd.
- **Collectability unaffected:** a `data_dir` instance is still collectable by a
  bare drop and after quit (the existing collectability bar).

## Not in scope

No migration/import of an existing `save_cookies` snapshot into a `data_dir`. No
API to enumerate or selectively clear website data (WebKit's
`WebsiteDataManager` could, but that is a separate feature). No concurrent-writer
locking. No change to `cookie_jar` or the snapshot API.
