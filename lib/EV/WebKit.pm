package EV::WebKit;
use v5.10; use strict; use warnings;
our $VERSION = '0.03';

use Glib::Object::Introspection;
use Glib::IO;   # Gio bindings: Cancellable, MemoryInputStream
use EV::WebKit::Element;
use File::Spec::Functions 'rel2abs';
use File::Path ();
use Scalar::Util 'weaken';
use Carp ();   # Carp::croak -- core, no prereq change

use constant NAV_SETTLE_DELAY => 0.01;   # WebKitGTK is multi-process: let web-process props (title/uri) propagate past load-changed:finished

# id-keyed registry counter for settle timers ({_settle} in _finish_nav and
# {chrome}{settle} in _update_chrome), same idea as $_defer_seq below -- but
# declared here (rather than beside $_defer_seq, textually below both of
# those subs) since both subs reference it directly (not via a method call),
# so it must be lexically in scope before their first use.
my $_settle_seq = 0;

# generation counter for {pending} (the in-flight nav slot): every
# _start_nav mints a new one. Lets _finish_nav tell "the timeout timer that
# belongs to THIS pending nav" apart from "a newer nav that has since
# superseded it" -- see _start_nav/_finish_nav below.
my $_nav_seq = 0;

# Identifies each queued pdf() job, so its watchdog (armed at enqueue, keyed in
# {_pdf_timers}) can be disarmed on completion, and so _pdf_pump can tell that a
# job's caller has already given up -- all without any closure capturing the job
# or its PrintOperation. See pdf/_pdf_pump/_pdf_run.
my $_pdf_seq = 0;

# True while a WebKit/GLib signal handler that calls USER code is on the stack:
# on_dialog (script-dialog), on_policy (decide-policy), on_console
# (script-message-received), and a mock_scheme producer. Code running there is
# nested inside WebKit's own dispatch frame, NOT on a clean EV tick -- which is
# why quit() must not do its work in place when called from one (see quit).
# Every other user callback in this module is delivered by _defer/_defer_final,
# i.e. already on a clean tick, so it leaves this false.
our $IN_DISPATCH = 0;

# Pending _defer_final deliveries, keyed by a monotonic id. File-scoped, NOT
# per-instance, so a final callback still fires after its browser is dropped
# (see _defer_final). Entries are transient: each timer deletes its own.
my %FINAL;

my @TYPELIBS = (
    [qw/Gtk 4.0 Gtk4/], [qw/Gdk 4.0 Gdk4/], [qw/JavaScriptCore 6.0 JSC/],
    [qw/Soup 3.0 Soup/], [qw/WebKit 6.0 WebKit/],
);

my $SETUP;   # 1 = ok, 0 = failed, undef = not tried
sub _setup {
    return $SETUP if defined $SETUP;
    $SETUP = eval {
        Glib::Object::Introspection->setup(basename=>$_->[0], version=>$_->[1], package=>$_->[2])
            for @TYPELIBS;
        1;                       # GI namespace setup only -- display-independent
    } ? 1 : 0;
    return $SETUP;
}

my $GTK_INIT;
my $GTK_DISPLAY;   # the display GTK actually connected to, process-wide
# Gtk4::init() aborts without a display, so call it ONLY after a display exists.
# It also runs at most ONCE per process: GTK connects to one X display and every
# later instance shares it, whatever it asked for. Remember which, so new() can
# say so instead of silently ignoring a display => option (a window that quietly
# appears on the wrong display, or a bogus display that "works", is worse than
# an error).
sub _init_gtk { return if $GTK_INIT; Gtk4::init(); $GTK_INIT = 1; $GTK_DISPLAY = $ENV{DISPLAY} }

sub available { _setup() ? 1 : 0 }

use EV;
use EV::Glib;                # integrates the GLib main loop into EV

# JSON codec (XS preferred). CHARACTER mode (utf8(0)), not byte mode:
# Glib::Object::Introspection marshals `utf8`-typed params/returns as Perl
# CHARACTER strings (it upgrades an unflagged scalar as Latin-1 on the way
# in, and always returns a utf8-flagged character string on the way out --
# see call_async_javascript_function/JSC::Value::to_string below). _enc's
# output feeds straight into such a param, and _dec's input comes straight
# from such a return, so the codec must speak characters, not bytes -- byte
# mode here silently double-encodes non-ASCII args and fails to decode
# non-ASCII results ("malformed UTF-8"/"Wide character" errors).
my $JSON = do {
    my $j = eval { require Cpanel::JSON::XS; Cpanel::JSON::XS->new } || do { require JSON::PP; JSON::PP->new };
    $j->canonical(1)->allow_nonref(1)->utf8(0);
};
sub _enc { $JSON->encode($_[0]) }
sub _dec { $JSON->decode($_[0]) }

# The element registry and every internal DOM call run in a dedicated,
# named JavaScript *isolated world* (its own global object and its own
# built-in prototypes, sharing only the DOM with the page). Page script
# cannot see or tamper with window.__evwk there, and -- crucially -- the
# JSON.stringify / Object.prototype the result-marshalling in _call_js
# relies on are the world's own natives, immune to a hostile page
# redefining JSON.stringify or polluting Object.prototype.toJSON. Only the
# user-facing script()/script_async() run in the page's main world (they
# exist to run the page's own JS), and the console proxy stays in the main
# world too (it must override the console the page's own code calls).
my $EVWK_WORLD = 'EVWebKit';

# A dedicated world for user scripts requested with world => 'isolated'. It is
# DELIBERATELY distinct from $EVWK_WORLD: a caller's isolated script must not be
# able to read or corrupt the module's own element registry.
my $USER_WORLD = 'EVWebKitUser';

# Friendly option value -> WebKit GObject-Introspection enum nick. Only `frames`
# actually renames; the rest pass through but are still validated so a typo
# croaks here instead of reaching WebKit as a bad nick.
my %USER_FRAMES   = (all => 'all-frames', top => 'top-frame');
my %USER_AT       = (start => 'start', end => 'end');
my %USER_LEVEL    = (author => 'author', user => 'user');
my %USER_WORLD_OK = (main => 1, isolated => 1);

# Re-injected (a fresh window.__evwk) at document-start on every navigation,
# so the id-space always restarts at 0 -- a handle from a previous page can
# therefore land on the SAME numeric id as a new page's element. `epoch` is
# a fresh per-document stamp so get() can tell the two apart: it throws
# 'stale element' both for that cross-navigation case (epoch mismatch) and
# for the original same-page "node removed" case (isConnected false). `e`
# is optional (get(i) alone still works) so this stays backward-tolerant.
#
# The registry must not grow without bound. It is keyed by id in a Map (NOT an
# array index), so entries can be dropped without renumbering a live handle:
#   - put() DEDUPES via a WeakMap (node -> id), because the same node is
#     registered over and over -- every wait_for poll re-runs find(), 20 times a
#     second by default. Pushing each time meant a minute of polling appended
#     1200 entries for ONE node.
#   - put() also sweeps detached nodes periodically. get() already refuses any
#     node that is not isConnected, so a detached entry can never be used again
#     -- it only pins the node in the renderer's JS heap, keeping the whole
#     removed subtree alive for as long as the page lives. (A page that never
#     navigates is exactly the long-lived single-page-app case this module is
#     used for, and the id-space reset on navigation does not help there.)
# Neither map holds a node strongly beyond what get() would still accept.
my $BOOT = <<'JS';
window.__evwk = window.__evwk || {
  h: new Map(),          // id -> node (live handles)
  r: new WeakMap(),      // node -> id (dedup; weak, so it never pins a node)
  n: 0,                  // next id
  epoch: Date.now().toString(36) + Math.random().toString(36).slice(2),
  put(node){
    const seen = this.r.get(node);
    if (seen !== undefined && this.h.get(seen) === node) return seen;
    const id = this.n++;
    this.h.set(id, node);
    this.r.set(node, id);
    if (this.h.size > 64 && (id & 63) === 0) {
      for (const [k, v] of this.h) { if (!v || !v.isConnected) this.h.delete(k); }
    }
    return id;
  },
  get(i, e){
    if (e !== undefined && e !== this.epoch) throw new Error('stale element');
    const n = this.h.get(i);
    if (!n || !n.isConnected) throw new Error('stale element');
    return n;
  }
};
JS


# Every option new() honours. A typo'd key must not be silently ignored: a
# mistyped proxy => would route DIRECT (deanonymization), and a mistyped
# data_dir => would silently fall back to an ephemeral session (no persistence).
# Keep in sync with the options read below and the CONSTRUCTOR POD.
my %KNOWN_NEW = map { $_ => 1 } qw(
    timeout window display
    on_load on_error on_close on_navigate on_console on_dialog on_policy
    data_dir cache_dir ephemeral cookie_jar jar_format
    proxy user_agent devtools title chrome
    fingerprint network_fingerprint seed
);

sub new {
    my ($class, %o) = @_;
    _setup() or die "EV::WebKit: required typelibs unavailable\n";
    if (my @bad = sort grep { !$KNOWN_NEW{$_} } keys %o) {
        Carp::croak("EV::WebKit: unknown option(s): @bad");
    }
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
    if (defined $o{seed}) {
        Carp::croak('EV::WebKit: seed must be a non-negative integer')
            unless !ref $o{seed} && $o{seed} =~ /\A\d+\z/;
        Carp::croak('EV::WebKit: seed requires fingerprint => <profile>') unless $fp;
        # Reduce to 32 bits HERE: the extension casts the GVariant double to
        # guint32, and converting an out-of-range double is undefined in C -- x86
        # wraps while ARM saturates, so an unreduced seed (a millisecond epoch, or
        # hex(substr($digest,0,16))) would silently produce DIFFERENT noise per
        # architecture. Reducing in Perl keeps that deterministic everywhere.
        $o{seed} %= 2**32;
    }
    if ($o{network_fingerprint}) {
        Carp::croak('EV::WebKit: network_fingerprint must be 1 or a curl-target string')
            if ref $o{network_fingerprint};
        Carp::croak('EV::WebKit: network_fingerprint requires fingerprint => <profile>')
            unless $fp;
        Carp::croak('EV::WebKit: network_fingerprint and an explicit proxy => are mutually exclusive')
            if exists $o{proxy};
    }
    my $self = bless {
        timeout   => $o{timeout} // 30,
        on_error  => $o{on_error},
        on_load   => $o{on_load},
        on_close  => $o{on_close},
        on_navigate => $o{on_navigate},
        fingerprint => $fp,       # resolved device profile (or undef); see the fingerprint => option
        pending   => undef,       # pending nav [cb, timer, gen, target_uri, started_seen, committed_uri, doc_scheme_seen]
        _superseded => {},        # uri => 1 -- identities of navs torn down mid-flight by _start_nav; see there and the load-changed/load-failed handlers
        _ops      => {},          # id => wrapped cb for every in-flight one-shot async op (_call_js/screenshot/pdf/cookie); quit() flushes these with 'browser closed' so none is silently dropped -- see _op_track
        _pdf_queue  => [],        # serialized pdf() jobs [id, path, \%opt, cb] -- one PrintOperation runs at a time (see pdf/_pdf_pump)
        _pdf_timers => {},        # id => watchdog for each pdf() job, armed at ENQUEUE so a job waiting behind a slow/stuck print is bounded too
    }, $class;

    # Keep the viewport geometrically possible: window.innerWidth/Height must not
    # exceed the spoofed screen (no real device has that). A mobile fingerprint
    # sizes the window TO its screen; any other fingerprint with a screen CAPS the
    # window to it (a windowed desktop can be smaller, never larger).
    my ($w, $h);
    if ($fp && $fp->{mobile} && $fp->{screen}) {
        ($w, $h) = @{ $fp->{screen} }[0,1];
    }
    else {
        ($w, $h) = @{ $o{window} || [1280, 1024] };
        if ($fp && $fp->{screen}) {
            my ($sw, $sh) = @{ $fp->{screen} }[0,1];
            $w = $sw if $w > $sw;
            $h = $sh if $h > $sh;
        }
    }
    # bring-your-own-display: the caller provides an X display (e.g. run under
    # `xvfb-run -a <script>`); this module never spawns or kills an X server.
    # GTK is already connected to a display and cannot be moved to another, so a
    # display => that disagrees with it can only be a mistake -- and silently
    # honouring the request while using the old display is the worst outcome
    # (the instance works, on the wrong screen, and even a nonexistent display
    # "succeeds"). Say so rather than mutating $ENV{DISPLAY} process-wide for
    # nothing.
    Carp::croak("EV::WebKit: display => '$o{display}' but this process already "
        . "connected GTK to '$GTK_DISPLAY' -- one display per process, and it "
        . "cannot be changed once a browser exists")
        if defined $o{display} && $GTK_INIT && defined $GTK_DISPLAY && $o{display} ne $GTK_DISPLAY;
    $ENV{DISPLAY} = $o{display} if defined $o{display};
    die "EV::WebKit: no X display. Run under one (e.g. `xvfb-run -a <script>`) "
      . "or pass display => ':N'.\n" unless defined $ENV{DISPLAY} && length $ENV{DISPLAY};
    $ENV{GDK_BACKEND} //= 'x11';
    _init_gtk();

    # cookie_jar forces a non-ephemeral session: WebKit's own
    # set_persistent_storage bails out immediately for an ephemeral session,
    # so native cookie persistence requires a real (even if undef/default-dir)
    # NetworkSession -- see .superpowers/sdd/cookie-investigation-report.md.
    Carp::croak('EV::WebKit: data_dir => ... with ephemeral => 1 -- a persistent '
              . 'session cannot be ephemeral. Drop one of them.')
        if defined $o{data_dir} && ($o{ephemeral} // 0);
    Carp::croak('EV::WebKit: cache_dir => ... needs data_dir => ... too -- a cache '
              . 'directory with no data directory would leak cache to WebKit\'s '
              . 'shared location and defeat the isolation.')
        if defined $o{cache_dir} && !defined $o{data_dir};
    # An empty-string path is never what the caller meant: rel2abs('') is the
    # cwd, so the session would silently dump into whatever directory the process
    # happens to be in, and the interpolated "$data_dir/cache" would become the
    # filesystem-root '/cache'. Reject it, loudly, next to the other croaks.
    for my $k (qw/data_dir cache_dir cookie_jar/) {
        Carp::croak("EV::WebKit: $k => '' -- an empty path is not valid. Omit it, or give a real path.")
            if defined $o{$k} && !length $o{$k};
    }

    # cookie_jar OR data_dir forces a non-ephemeral session: WebKit's
    # set_persistent_storage (cookie_jar) and its on-disk storage (data_dir)
    # both bail out for an ephemeral session.
    my $ephemeral = ($o{cookie_jar} || defined $o{data_dir})
        ? 0 : (defined $o{ephemeral} ? $o{ephemeral} : 1);

    # data_dir points the whole session -- cookies, localStorage, IndexedDB,
    # cache -- at $data_dir, isolated from every other instance, and restored on
    # the next construction with the same path. cache (regenerable) defaults to a
    # subdirectory; cache_dir overrides it. rel2abs because a path relative to
    # WebKit's cwd is a footgun (cwd drifts) -- same reason pdf() uses it.
    #
    # Resolve, VALIDATE, and CREATE the directories here rather than leaving it to
    # WebKit. WebKit defers directory setup to the first navigation, inside its
    # bubblewrap sandbox, where a bad path is not a catchable error but a process
    # ABORT (a file where a directory should be) or a completely silent
    # non-persistence (an unwritable parent -- set_cookie and localStorage still
    # report success, and you only discover the loss when a "restored" session is
    # empty). Doing it up front turns both into a clean croak out of new().
    my ($data_abs, $cache_abs);
    if (defined $o{data_dir}) {
        $data_abs  = rel2abs($o{data_dir});
        $cache_abs = rel2abs($o{cache_dir} // "$data_abs/cache");
        for my $d ([data_dir => $data_abs], [$o{cache_dir} ? 'cache_dir' : 'data_dir/cache' => $cache_abs]) {
            my ($what, $path) = @$d;
            Carp::croak("EV::WebKit: $what '$path' exists but is not a directory")
                if -e $path && !-d _;
            next if -d $path;
            eval { File::Path::make_path($path); 1 }
                or Carp::croak("EV::WebKit: cannot create $what '$path' "
                             . '(is a parent directory writable?): ' . _clean($@));
        }
    }
    my $session = $self->{session} =
        $ephemeral            ? WebKit::NetworkSession->new_ephemeral
      : defined $o{data_dir}  ? WebKit::NetworkSession->new($data_abs, $cache_abs)
      :                         WebKit::NetworkSession->new(undef, undef);

    # Cookie persistence is NOT automatic even for a non-ephemeral session --
    # WebKit keeps cookies in memory until set_persistent_storage names a file.
    # So a plain data_dir session persists localStorage/IndexedDB (those follow
    # the session's data directory) but NOT cookies, unless we point the cookie
    # store at a file too. Give data_dir its own default cookie file inside
    # itself, so "data_dir persists the whole session" is actually true;
    # cookie_jar, when given, overrides that location with the caller's specific
    # (queryable) path -- that is how the two compose.
    #
    # Called immediately after session construction, before context/ucm/view
    # exist and before any load -- confirmed sufficient. Only cookies with a
    # real max_age/expiry are written; session cookies are excluded by design
    # (RFC 6265) -- use save_cookies/load_cookies to snapshot those.
    my $fmt = $o{jar_format} // 'sqlite';    # 'sqlite' or 'text'
    # the derived cookie file's extension follows the format, so a text jar is
    # not misleadingly named cookies.sqlite.
    my $jar = defined $o{cookie_jar} ? rel2abs($o{cookie_jar})
            : defined $data_abs      ? "$data_abs/cookies." . ($fmt eq 'text' ? 'txt' : 'sqlite')
            :                          undef;
    if (defined $jar) {
        $session->get_cookie_manager->set_persistent_storage($jar, $fmt);
    }
    $self->set_proxy($o{proxy}) if exists $o{proxy};
    if ($o{network_fingerprint}) {
        eval { require Proxy::Impersonate; 1 }
            or Carp::croak("EV::WebKit: network_fingerprint requested but Proxy::Impersonate is unavailable: $@");
        my $target = ($o{network_fingerprint} =~ /\D/)
            ? $o{network_fingerprint}                                  # explicit target override
            : EV::WebKit::Fingerprint::curl_target($o{fingerprint});   # derive from the profile name
        Carp::croak("EV::WebKit: no curl target for fingerprint '"
                  . (ref $o{fingerprint} ? '(custom)' : $o{fingerprint})
                  . "' -- pass network_fingerprint => '<curl-target>'")
            unless $target;
        my $proxy = Proxy::Impersonate->new(
            impersonate           => $target,
            listen                => '127.0.0.1:0',
            override_headers      => EV::WebKit::Fingerprint::identity_headers($fp),
            high_entropy_headers  => EV::WebKit::Fingerprint::high_entropy_headers($fp),
        );
        $self->{proxy} = $proxy;
        $self->{network_fingerprint} = $target;
        $session->set_tls_errors_policy('ignore');     # accept the proxy self-signed cert
        $self->set_proxy('http://127.0.0.1:' . $proxy->port);
    }
    my $ucm = $self->{ucm} = WebKit::UserContentManager->new;
    # a per-instance (not the default/shared) WebContext -- construct-only,
    # and confirmed (live, WebKitGTK 2.52.4) to coexist fine alongside
    # network-session/user-content-manager as construct props on WebView --
    # so mock_scheme() below has a controllable context to register schemes on.
    my $context = $self->{context} = WebKit::WebContext->new;
    if ($fp) {
        # Must be set on the context BEFORE the web process spawns (before the
        # first navigation): the extension directory + the profile it reads.
        $context->set_web_process_extensions_directory(EV::WebKit::Fingerprint::_so_dir());
        $context->set_web_process_extensions_initialization_user_data(EV::WebKit::Fingerprint::gvariant($fp, $o{seed}));
        # align the Accept-Language header (and the Intl/ICU default locale) with
        # the profile's navigator.languages, so the network layer does not
        # contradict the spoofed JS languages.
        $context->set_preferred_languages($fp->{languages}) if $fp->{languages};
    }
    my $view = $self->{view} = Glib::Object::new('WebKit::WebView',
        'web-context' => $context, 'network-session' => $session, 'user-content-manager' => $ucm);

    my $ua = $fp ? $fp->{user_agent} : $o{user_agent};
    $self->set_user_agent($ua) if defined $ua;   # native: sets the header AND navigator.userAgent; validated setter (croaks on a UA WebKit would silently drop)
    $view->get_settings->set('enable-developer-extras', 1) if $o{devtools};

    my $win = $self->{win} = Gtk4::Window->new;
    $win->set_default_size($w, $h);
    $win->set_child($view);
    $win->set_title($o{title}) if defined $o{title};
    $self->_build_chrome if $o{chrome};   # titlebar must precede present (realized-window warning)
    $win->present;

    # The user closed the window (the titlebar X, alt-F4, the window manager).
    # Without this the instance just kept running with no window: every in-flight
    # callback dangled, the natives leaked, and the caller's EV::run went on
    # spinning over nothing. It only bites the VISIBLE mode (chrome => 1 on a
    # real display), which is why the whole headless test suite never saw it.
    #
    # Everything is done on a CLEAN TICK, not here: this fires inside GTK's
    # dispatch frame, and the caller's on_close will want to EV::break (or
    # quit()), neither of which is safe nested in a dispatch frame. Deferring
    # also makes on_close the one handler EV::break IS safe from -- see the POD.
    #
    # Returning TRUE stops GTK destroying the window itself. It must not: an
    # in-flight op still holds the view, and having the window ripped out from
    # under it is the whole reason quit() tears down in a defined order. quit()
    # destroys the window a tick later, after resolving everything.
    weaken(my $wclose = $self);
    $win->signal_connect('close-request' => sub {
        local $IN_DISPATCH = 1;
        my $self = $wclose or return 0;   # gone already: let GTK close it
        # Guard on a flag set SYNCHRONOUSLY, right here -- not on {_dead}, which
        # quit() only sets a tick later when the deferred teardown runs. Two
        # close-requests before that tick (a double-click on the X, a window
        # manager re-sending the delete, fast Alt-F4) would otherwise each defer
        # their own closure and fire on_close twice, even though the window is
        # correctly destroyed only once. on_close promises exactly once.
        return 0 if $self->{_dead} || $self->{_closing};
        $self->{_closing} = 1;
        my $on_close = $self->{on_close};
        $self->_defer_final(sub {
            $self->quit;                  # resolve every in-flight callback, then destroy the window
            # Guarded, like every other handler dispatch: a throwing on_close must
            # not escape into EV's generic $EV::DIED with no context.
            if ($on_close) {
                unless (eval { $on_close->(); 1 }) {
                    warn "EV::WebKit: on_close callback died: $@";
                }
            }
        });
        return 1;
    });

    # The signal handlers registered below are the only closures in new() that
    # would otherwise capture $self STRONGLY, forming a $self -> {view} ->
    # signal-connection -> closure -> $self cycle that plain refcounting can
    # never break -- so a bare `undef $b` (no quit()) would leak the native
    # window/view/session for the life of the process (quit() breaks it by
    # deleting {view}, but DESTROY only runs once the cycle is already broken).
    # Capture only a WEAK ref and guard on it first, exactly like the async
    # completions and the chrome handlers do; while the instance is alive the
    # caller's own reference keeps it valid, and once they drop it these
    # handlers stop firing (the view is torn down in DESTROY -> quit).
    weaken(my $wself = $self);
    $view->signal_connect('load-changed' => sub {
        my ($ev_view, $ev) = @_;
        my $self = $wself or return;
        # $ev_view (this call's own first arg, NOT the outer $view lexical)
        # -- closing over $view here would make this permanently-retained
        # signal-handler closure hold its own strong reference to the view
        # it is itself attached to (view -> closure -> view), a cycle plain
        # refcounting can never break; confirmed live via t/46-collectability.t.
        # A bare per-call arg carries no such risk: it isn't part of the
        # closure's captured environment, only of this one invocation.
        if ($ev eq 'redirected') {
            # a server-side redirect changes which uri is actually in
            # flight for the CURRENT pending nav -- keep the tracked target
            # in step (WebKit's own load-failed, below, reports the
            # redirected-to uri as its failing_uri, not the originally
            # requested one) so a subsequent real failure isn't mistaken
            # for a stray signal belonging to some other nav.
            my $p = $self->{pending};
            $p->[3] = $ev_view->get_uri if $p && defined $p->[3];
        }
        elsif ($ev eq 'started' || $ev eq 'committed') {
            # Mark the CURRENT pending nav as having seen its own
            # load-changed lifecycle begin. This lets the load-failed
            # handler (below) recognize a failure that arrives while the
            # current pending has NOT yet started as necessarily belonging
            # to some other, already-superseded nav -- see the started-since
            # gate there, and _start_nav where this flag is initialized.
            my $p = $self->{pending};
            if ($p) {
                $p->[4] = 1;
                # Capture the pending's OWN committed uri (R11) -- see
                # _finished_is_stray below for why this is only trustworthy
                # from 'committed' (a real commit), not 'started' (merely
                # optimistic/provisional, and exactly the kind of
                # easily-superseded value that caused the finished-path bug
                # in the first place). Harmless to also (re)write it here on
                # a later 'committed' after a redirect -- get_uri() at that
                # point is the post-redirect destination, which is what a
                # subsequent 'finished' should be compared against anyway.
                $p->[5] = $ev_view->get_uri if $ev eq 'committed';
            }
            # 'committed' is the moment WebKit switches to the new document, so
            # the view's uri is now definitively the new page's. Report it
            # however the navigation began -- note this sits OUTSIDE the
            # if ($p) above, deliberately. on_load cannot do this job: it fires
            # only for a navigation THIS API started (_finish_nav returns early
            # when there is no {pending}), so a page that navigates itself --
            # which is exactly what a human clicking a link in a visible window
            # looks like -- changed the page and told nobody at all. Deferred
            # like every other callback, and dead-gated: a navigate event after
            # quit() is meaningless.
            if ($ev eq 'committed' && $self->{on_navigate}) {
                # Guarded like on_load: a throwing on_navigate must not escape
                # into EV's generic handler with no context.
                my $uri = $ev_view->get_uri;
                $self->_defer(sub {
                    my $s = $wself or return;
                    return if $s->{_dead};
                    my $cb = $s->{on_navigate} or return;
                    unless (eval { $cb->($uri); 1 }) {
                        warn "EV::WebKit: on_navigate callback died: $@";
                    }
                });
            }
        }
        elsif ($ev eq 'finished') {
            # R11: the success path used to resolve _finish_nav
            # unconditionally, with NO identity check at all -- unlike
            # load-failed's gates above. A SUPERSEDED nav's own belated
            # 'finished' (WebKit still completes a request handed a response
            # even after being superseded/cancelled -- confirmed live, see
            # .superpowers/sdd/review-loop-r11-fix-report.md) would then
            # resolve the CURRENT pending with a FALSE SUCCESS, and the real
            # nav's own outcome would arrive to find {pending} already
            # consumed. _finished_is_stray (shared with _update_chrome, so
            # chrome's icon doesn't flip on a stray event either) implements
            # the two gates documented there. Not gated on started-since
            # (unlike load-failed): a bfcache-restored back()/forward() can
            # legitimately jump straight to 'finished' with no preceding
            # started/committed at all -- gating on that would hang a real,
            # successful navigation, which is worse than the bug.
            if ($self->_finished_is_stray($ev_view->get_uri)) {
                # Consumed: some tail signal for whatever this pending
                # superseded has now been accounted for. Left in place, a
                # stale entry could wrongly suppress a LATER, unrelated
                # legitimate no-commit (bfcache-style) finished for a
                # future pending -- _start_nav also resets this set on every
                # new nav, as a second, independent backstop against that.
                $self->{_superseded} = {};
            }
            else {
                $self->_finish_nav(undef);
            }
        }
    });
    $view->signal_connect('load-failed' => sub {
        my (undef, undef, $failing_uri, $gerr) = @_;
        my $self = $wself or return;
        my $p = $self->{pending};
        # A load-failed is a STRAY signal for an already-superseded nav
        # (not the current pending) -- and must be ignored rather than
        # consume/mis-resolve the current pending (see _finish_nav) -- when
        # ANY of three independent gates says so:
        #
        #  - target-uri gate: the current pending tracks a target (go()
        #    only -- see _start_nav callers) and failing_uri differs from
        #    it. When a new go()/load_html()/etc. supersedes an in-flight
        #    one, WebKit cancels the old load rather than silently dropping
        #    it, and that cancellation surfaces here -- for the OLD uri --
        #    sometime after {pending} has already moved on to the new nav.
        #    Unconditional on started state: a mismatch is always stray.
        #
        #  - started-since gate: the current pending has NOT yet seen its
        #    own load-changed started/committed (see above). WebKit always
        #    starts a load (emits 'started') before it can fail it, so a
        #    failure arriving for a not-yet-started pending cannot be that
        #    pending's own -- it must be the tail cancellation of whatever
        #    nav this one just superseded. This is what protects
        #    back()/forward()/reload()/load_html(), which have no
        #    predictable target uri to compare (a history entry's
        #    destination isn't known ahead of time, and load_html has none
        #    at all: $p->[3] stays undef for these, so the target-uri gate
        #    above is inert for them). Confirmed live: the stray
        #    cancellation for a just-superseded nav consistently arrives
        #    before the new pending's own first load-changed event.
        #
        #  - superseded-uri gate (R11): failing_uri is the identity of a nav
        #    this pending itself superseded (see _start_nav/{_superseded}).
        #    This closes a gap the other two can miss once the current
        #    pending has ALREADY started (started-since gate now inert) but
        #    a stray tail for an EARLIER superseded nav still arrives late --
        #    e.g. a real network cancellation that takes longer to surface
        #    than the new pending's own near-instant start. Skipped when it
        #    would agree with the target-uri gate's own "known and matching"
        #    exemption (below), so it never re-flags a genuine same-uri
        #    failure as stray. A MATCH here is a pure read, never a write:
        #    WebKit fires load-changed:finished as the terminal event of
        #    EVERY load's lifecycle even after a load-failed for the same
        #    load (confirmed live -- a superseded nav's cancellation reliably
        #    produces BOTH) -- if this branch consumed/deleted the
        #    {_superseded} entry, the finished handler's OWN check
        #    (_finished_is_stray, which cannot identify a specific uri to
        #    delete and so clears the whole set) would arrive moments later
        #    to find nothing left to compare against, and wrongly resolve
        #    the still-uncommitted current pending. Only _finished_is_stray
        #    ever clears {_superseded} -- see there.
        #
        # A pending with a KNOWN target whose failing_uri actually MATCHES
        # it is never stray via any gate, regardless of started state --
        # that is a genuine failure of the current pending's own nav.
        if ($p && defined $failing_uri) {
            my $known_and_matching = defined $p->[3] && $failing_uri eq $p->[3];
            my $stray = !$known_and_matching && (
                defined $p->[3] ? 1                                  # target known, didn't match -- always stray
                                : ( !$p->[4]                          # not started yet, or...
                                    || $self->{_superseded}{$failing_uri} ) );  # ...a known superseded identity
            return 1 if $stray;
        }
        $self->_finish_nav("load failed: $failing_uri: ".(ref $gerr ? $gerr->message : $gerr));
        return 1; # handled
    });

    # The renderer died (crashed, hit the memory limit, or was terminated).
    # WebKit says so at once -- but it sends no load-failed for the page that
    # was loading, so without this a navigation in flight simply waits out the
    # WHOLE timeout (30s by default) and then reports a misleading 'timeout',
    # for something that became impossible the instant this fired. Route it
    # through the same path as any other nav failure: _finish_nav resolves the
    # pending navigation if there is one, and otherwise reports it to on_error,
    # so a crash is never silent. (WebKit relaunches the web process on the next
    # load, so the instance stays usable.)
    $view->signal_connect('web-process-terminated' => sub {
        my (undef, $reason) = @_;   # nick: crashed / exceeded-memory-limit / terminated-by-api
        my $self = $wself or return;
        return if $self->{_dead};
        $self->_finish_nav('web process terminated: ' . ($reason // 'unknown'));
    });

    $self->_install_boot;

    $self->{on_console} = $o{on_console};
    $self->_install_console if $self->{on_console};

    $self->{on_dialog} = $o{on_dialog};
    $view->signal_connect('script-dialog' => sub {
        my (undef, $d) = @_;
        local $IN_DISPATCH = 1;          # on_dialog runs nested in WebKit's dispatch frame -- see quit
        my $self = $wself or return 1;   # $self gone (teardown): suppress the native dialog, nothing to deliver to
        return 1 if $self->{_dead};      # torn down: suppress the native dialog, nothing to deliver to
        my $dlg = EV::WebKit::Dialog->_new($d);
        # A die in on_dialog MUST NOT abort this handler before its `return 1`:
        # that return is what suppresses WebKit's own blocking native dialog, so
        # skipping it leaves the page's alert/confirm/prompt unresolved and
        # wedges the WebView (and, since GI shares one dispatch, can starve
        # dialog delivery to sibling instances too). Catch it, still resolve the
        # dialog (dismiss) so the page can proceed, and always return handled.
        if ($self->{on_dialog}) {
            unless (eval { $self->{on_dialog}->($dlg); 1 }) {
                my $err = $@;
                eval { $dlg->dismiss };   # best-effort: give the page a definite answer
                warn "EV::WebKit: on_dialog callback died: $err";
            }
        }
        else { $dlg->dismiss }
        return 1;  # handled -- suppress WebKit's own blocking native dialog
    });

    $self->{on_policy} = $o{on_policy};
    $view->signal_connect('decide-policy' => sub {
        my (undef, $decision, $type_nick) = @_;   # type_nick: navigation-action/new-window-action/response
        local $IN_DISPATCH = 1;          # on_policy runs nested in WebKit's dispatch frame -- see quit
        my $self = $wself or return 0;   # $self gone: WebKit applies its own default (allow)
        return 0 if $self->{_dead};      # torn down: let WebKit apply its own default
        return 0 unless $self->{on_policy};   # not handled -- WebKit applies its own default (allow)
        # WebKitNavigationPolicyDecision (navigation-action/new-window-action) only
        # exposes get_navigation_action; WebKitResponsePolicyDecision (response) only
        # exposes get_request directly -- try the navigation path first, fall back
        # to the response path (each ->can/eval-guarded since the two are siblings,
        # not a subtype chain, so the "wrong" accessor is simply absent).
        my $uri = eval { $decision->get_navigation_action->get_request->get_uri }
               // eval { $decision->get_request->get_uri };
        my $info = EV::WebKit::Policy->_new($decision, $type_nick, $uri);
        # A throw here would escape into GI's dispatch, which merely prints it
        # and ignores it -- so neither allow nor block would run and WebKit
        # would apply its OWN default, which is allow. on_policy is a gate: a
        # page that can make the handler die (a uri that breaks its parsing)
        # would then walk straight through it. Fail CLOSED, loudly. A handler
        # that decided BEFORE it died keeps its decision.
        unless (eval { $self->{on_policy}->($info); 1 }) {
            warn "EV::WebKit: on_policy callback died (blocking the navigation): $@";
            $info->block unless $info->{done};
            return 1;
        }
        $info->allow unless $info->{done};   # default allow if handler didn't decide
        return 1;   # handled
    });

    return $self;
}

# call from new(): inject boot script once the ucm exists.
sub _install_boot {
    my ($self) = @_;
    # Inject the registry into the dedicated isolated world (NOT the page's
    # main world) so page script can neither read nor overwrite it, and its
    # marshalling natives are beyond the page's reach. See $EVWK_WORLD.
    my $us = WebKit::UserScript->new_for_world($BOOT, 'all-frames', 'start', $EVWK_WORLD, undef, undef);
    $self->{ucm}->add_script($us);
}

# Install the console proxy: a user script that wraps console.log/warn/error/info
# in the page's MAIN world (it has to override the console the page's own code
# calls) and posts each line to a script-message handler.
#
# Installed ON DEMAND -- from new() when on_console was given, and from the
# on_console accessor otherwise. Until something actually wants console output
# there is no reason to touch the page at all. Idempotent.
#
# NOTE: user scripts are injected at document-start, so enabling on_console after
# a page has loaded takes effect from the NEXT navigation.
sub _install_console {
    my $self = shift;
    return if $self->{_console_installed}++;
    my $ucm = $self->{ucm} or return;
    weaken(my $wself = $self);
    $ucm->register_script_message_handler('evwk', undef);
    $ucm->signal_connect('script-message-received' => sub {
        my (undef, $val) = @_;
        local $IN_DISPATCH = 1;      # on_console runs nested in WebKit's dispatch frame -- see quit
        my $self = $wself or return;
        return if $self->{_dead};    # torn down: the page is gone, do not call back into user code
        my $text = eval { $val->to_string };
        return unless defined $text && $self->{on_console};
        # A throw here would escape into GI's dispatch (which merely prints and
        # ignores it), so guard it as on_dialog/on_policy do: a console line is
        # never worth destabilising the page over.
        unless (eval { $self->{on_console}->($text); 1 }) {
            warn "EV::WebKit: on_console callback died: $@";
        }
    });
    my $proxy = <<'JS';
(function(){ try {
  const post = (t)=>window.webkit.messageHandlers.evwk.postMessage(String(t));
  ['log','warn','error','info'].forEach(k=>{ const o=console[k];
    console[k]=function(){ try{post(k+': '+Array.from(arguments).join(' '))}catch(e){}; return o.apply(console,arguments); }; });
} catch(e){} })();
JS
    $ucm->add_script(WebKit::UserScript->new($proxy, 'all-frames', 'start', undef, undef));
    return;
}

# Inject caller-supplied JavaScript. Returns an EV::WebKit::UserContent handle
# whose ->remove takes just this script out. Options: at 'start'|'end' (default
# end -- the DOM exists), world 'main'|'isolated' (default main), frames
# 'all'|'top' (default all), allow/deny arrayrefs of URL-pattern globs. Takes
# effect from the NEXT navigation (WebKit injects user content at load time).
sub add_user_script { my ($self, $source, %opt) = @_; $self->_add_user_content('script', $source, %opt) }

# Inject caller-supplied CSS. Like add_user_script but for stylesheets: no world
# option (a world does not change a stylesheet's effect on the document, so it is
# not surfaced -- we use UserStyleSheet->new, not ->new_for_world); adds a level
# 'author'|'user' (default author; 'user' beats page CSS -- use it to hide elements).
sub add_user_style  { my ($self, $source, %opt) = @_; $self->_add_user_content('style',  $source, %opt) }

sub _add_user_content {
    my ($self, $kind, $source, %opt) = @_;
    Carp::croak("add_user_$kind: source is required") unless defined $source;
    Carp::croak("add_user_$kind: source must be a string, not a " . ref($source) . " ref") if ref $source;
    # WebKit stores the source as a NUL-terminated C string, so an embedded NUL
    # silently truncates the injected content -- the same silent-truncation class
    # guarded for allow/deny below. A NUL in JS/CSS is never intentional.
    Carp::croak("add_user_$kind: source contains a NUL byte (it would silently truncate the injected content)")
        if index($source, "\0") >= 0;
    # Reject unknown option keys: a typo (wrld => / dney =>) would otherwise be
    # silently dropped, falling back to a MORE PERMISSIVE default (main world, no
    # allow/deny) -- a silent, security-relevant misfire for an injection API.
    # Valid keys are kind-specific.
    my %known = (frames => 1, allow => 1, deny => 1,
                 $kind eq 'script' ? (at => 1, world => 1) : (level => 1));
    if (my @bad = sort grep { !$known{$_} } keys %opt) {
        Carp::croak("add_user_$kind: unknown option(s): @bad");
    }
    Carp::croak("add_user_$kind: browser closed") if $self->{_dead} || !$self->{ucm};

    my $frames = $USER_FRAMES{ $opt{frames} // 'all' }
        // Carp::croak("add_user_$kind: frames => '$opt{frames}' is invalid (use 'all' or 'top')");

    # allow/deny pass straight to WebKit as URL-pattern globs. Validate strictly:
    # an undef entry becomes a NULL that truncates the GStrv WebKit receives
    # (silently dropping later patterns -- a deny-list bypass), and an EMPTY list
    # is read by WebKit as no-constraint (match EVERY url), the opposite of the
    # likely intent. So require an arrayref, non-empty, of defined plain strings.
    # Omit the key entirely for "every url".
    for my $k (qw/allow deny/) {
        next unless defined $opt{$k};
        Carp::croak("add_user_$kind: $k => ... must be an arrayref of URL-pattern strings")
            unless ref $opt{$k} eq 'ARRAY';
        @{ $opt{$k} } or Carp::croak("add_user_$kind: $k => [] is empty; omit $k to match every url");
        # A zero-length string is never a valid WebKit URL pattern (it just never
        # matches -- silently), so reject it alongside undef/refs. (We cannot
        # validate the full pattern grammar; an otherwise-malformed pattern is
        # WebKit's to reject and simply will not match -- see the POD.)
        defined && !ref && length or Carp::croak("add_user_$kind: $k entries must be non-empty strings")
            for @{ $opt{$k} };
    }
    my ($allow, $deny) = @opt{qw/allow deny/};

    my $native;
    if ($kind eq 'script') {
        my $at = $USER_AT{ $opt{at} // 'end' }
            // Carp::croak("add_user_script: at => '$opt{at}' is invalid (use 'start' or 'end')");
        my $world = $opt{world} // 'main';
        Carp::croak("add_user_script: world => '$world' is invalid (use 'main' or 'isolated')")
            unless $USER_WORLD_OK{$world};
        $native = $world eq 'isolated'
            ? WebKit::UserScript->new_for_world($source, $frames, $at, $USER_WORLD, $allow, $deny)
            : WebKit::UserScript->new($source, $frames, $at, $allow, $deny);
        $self->{ucm}->add_script($native);
    }
    else {   # style
        my $level = $USER_LEVEL{ $opt{level} // 'author' }
            // Carp::croak("add_user_style: level => '$opt{level}' is invalid (use 'author' or 'user')");
        $native = WebKit::UserStyleSheet->new($source, $frames, $level, $allow, $deny);
        $self->{ucm}->add_style_sheet($native);
    }

    my $id = ++$self->{_user_seq};
    $self->{"_user_${kind}s"}{$id} = $native;
    return EV::WebKit::UserContent->_new($self, $id, $kind);
}

# Remove every user script / stylesheet THIS caller added, and only those. Must
# NOT use WebKit's remove_all_scripts/remove_all_style_sheets: those also remove
# the module's own injected BOOT (the $EVWK_WORLD registry find()/html() need)
# and console proxy. Loop per-item removal over our registry instead.
sub remove_all_user_scripts { my $self = shift; $self->_remove_all_user('script'); return $self }
sub remove_all_user_styles  { my $self = shift; $self->_remove_all_user('style');  return $self }

sub _remove_all_user {
    my ($self, $kind) = @_;
    return if $self->{_dead} || !$self->{ucm};
    my $reg = $self->{"_user_${kind}s"} or return;
    my $m = $kind eq 'style' ? 'remove_style_sheet' : 'remove_script';
    $self->{ucm}->$m($_) for values %$reg;
    %$reg = ();
    return;
}

# Get/set accessors for the event handlers. Without these the constructor is the
# only way to set one, so anything that wants to observe a browser has to BE the
# code that created it -- which is exactly what a layer built on top (see
# EV::WebKit::Control) must not require. With them, such a layer can CHAIN:
#
#     my $prev = $b->on_console;
#     $b->on_console(sub { $prev->(@_) if $prev; ...also mine... });
#
# through the public API, instead of reaching into the object.
for my $h (qw/on_load on_error on_close on_navigate on_console on_dialog on_policy/) {
    no strict 'refs';
    *{__PACKAGE__ . "::$h"} = sub {
        my $self = shift;
        return $self->{$h} unless @_;
        my $cb = shift;
        Carp::croak("$h: expected a code reference") if defined $cb && ref $cb ne 'CODE';
        $self->{$h} = $cb;
        # The console proxy touches the page, so it is only injected once
        # something actually wants console output. Enabling it late is legal --
        # from the next navigation (user scripts run at document start).
        $self->_install_console if $h eq 'on_console' && $cb && !$self->{_dead};
        return $self;
    };
}

# chrome => 1: minimal browser chrome -- a GNOME HeaderBar titlebar with
# back/forward/reload buttons and an address entry. Orthogonal to automation:
# the WebView is unchanged and stays fully scriptable.
sub _build_chrome {
    my ($self) = @_;
    my $hb = Gtk4::HeaderBar->new;
    my %btn;
    for (['back',    'go-previous-symbolic',  'Back'],
         ['forward', 'go-next-symbolic',      'Forward'],
         ['reload',  'view-refresh-symbolic', 'Reload']) {
        my ($k, $icon, $tip) = @$_;
        $btn{$k} = Gtk4::Button->new_from_icon_name($icon);
        $btn{$k}->set_tooltip_text($tip);
        $hb->pack_start($btn{$k});
    }
    my $entry = Gtk4::Entry->new;
    $entry->set_hexpand(1);
    $hb->set_title_widget($entry);
    $self->{win}->set_titlebar($hb);
    my $c = $self->{chrome} = { hb => $hb, entry => $entry, %btn, loading => 0, settle => {} };
    $btn{back}->set_sensitive(0);
    $btn{forward}->set_sensitive(0);

    # These closures capture $self and/or $c -- and $c itself cross-references
    # these very widgets (e.g. $c->{reload} == $btn{reload}), so the reload
    # handler alone forms a self-contained Perl reference cycle (button ->
    # its own clicked-closure -> $c -> same button) that quit()'s `delete
    # $self->{chrome}` cannot touch (a closure's captured lexical is its own
    # independent reference, invisible from outside the closure) and that
    # ordinary refcounting can never collect. Weaken every such captured
    # reference (classic gperl `my $x = $wx or return;` pattern) so these
    # closures can neither hold $self alive forever nor sustain a cycle among
    # themselves.
    weaken(my $wself  = $self);
    weaken(my $wc     = $c);
    weaken(my $wentry = $entry);

    $entry->signal_connect(activate => sub {
        my $self  = $wself  or return;
        my $entry = $wentry or return;
        my $url = $entry->get_text;
        return unless defined $url && length $url;
        $url = "https://$url" unless $url =~ m{^[a-z][a-z0-9+.-]*://}i;
        $self->go($url);
    });
    $btn{back}->signal_connect(clicked    => sub { my $self = $wself or return; $self->back });
    $btn{forward}->signal_connect(clicked => sub { my $self = $wself or return; $self->forward });
    $btn{reload}->signal_connect(clicked  => sub {
        my $self = $wself or return;
        my $c    = $wc    or return;
        $c->{loading} ? $self->stop : $self->reload;
    });

    # chrome-only updater; the core nav handler is connected separately in new()
    $self->{view}->signal_connect('load-changed' => sub {
        my (undef, $ev) = @_;
        my $self = $wself or return;
        $self->_update_chrome($ev);
    });
    # The address bar must also follow a SINGLE-PAGE-APP navigation. A
    # history.pushState (how Reddit, GitHub, most modern sites change the URL on
    # a click) fires NO load-changed cycle -- so the load-changed handler above
    # never runs, and the bar (plus back/forward sensitivity and the window
    # title) would show the old URL while the page has moved on. The view's uri
    # property DOES change on pushState, so refresh from notify::uri too.
    # Harmless on a normal load (it just calls _refresh_chrome, which is
    # idempotent). Weakened like every other chrome handler -- the view holds
    # this closure, and a strong $self would be an uncollectable cycle.
    $self->{view}->signal_connect('notify::uri' => sub {
        my $self = $wself or return;
        $self->_refresh_chrome unless $self->{_dead};
    });
    return;
}

sub _update_chrome {
    my ($self, $ev) = @_;
    my $c = $self->{chrome} or return;
    # R11 (cosmetic): a stray 'finished' for an already-superseded nav must
    # not flip the reload/stop icon to not-loading either -- the real nav is
    # still genuinely in flight. Shares the exact same verdict as the core
    # load-changed handler in new() via _finished_is_stray (a pure read, safe
    # to call from here too even though this handler fires FIRST -- see
    # _build_chrome, where this is connected before the core handler).
    return if $ev eq 'finished' && $self->_finished_is_stray($self->{view}->get_uri);
    if ($ev eq 'started') {
        $c->{loading} = 1;
        $c->{reload}->set_icon_name('process-stop-symbolic');
    }
    elsif ($ev eq 'finished') {
        $c->{loading} = 0;
        $c->{reload}->set_icon_name('view-refresh-symbolic');
        # title/uri propagate from the web process shortly after 'finished'
        # (the NAV_SETTLE_DELAY race) -- refresh once more after that window.
        # id-keyed (like _finish_nav's {_settle}) so two 'finished' events
        # within NAV_SETTLE_DELAY of each other don't GC each other's
        # still-pending refresh timer via a single-slot overwrite.
        my $id = ++$_settle_seq;
        weaken(my $wself = $self);   # weak: same self-stored-timer cycle -- keep a bare drop during the settle window collectible
        $c->{settle}{$id} = EV::timer(NAV_SETTLE_DELAY, 0, sub {
            my $self = $wself or return;
            delete $self->{chrome}{settle}{$id} if $self->{chrome};
            $self->_refresh_chrome;
        });
    }
    $self->_refresh_chrome;
}

sub _refresh_chrome {
    my ($self) = @_;
    return if $self->{_dead} || !$self->{view};
    my $c = $self->{chrome} or return;
    my $uri = $self->uri;
    $c->{entry}->set_text($uri // '') unless $c->{entry}->has_focus;  # never clobber typing
    my $title = $self->title;
    $self->{win}->set_title($title) if defined $title && length $title;
    $c->{back}->set_sensitive($self->can_go_back);
    $c->{forward}->set_sensitive($self->can_go_forward);
    return;
}

sub _clean { my $e = shift // ''; $e =~ s/ at \S+ line \d+\.?\s*$//; $e }

sub _call_js {
    my ($self, $code, $args, $cb, $main_world) = @_;
    # Default (falsy/omitted) -> the isolated $EVWK_WORLD: find/find_all,
    # html, every Element atom and wait_for's polling all reach the registry
    # and marshal via the world's own natives. Only script()/script_async()
    # pass a true $main_world to run in the page's own world. This defaults
    # to the SECURE world, so a caller that forgets the flag fails safe (and
    # loudly -- a script test that needs page globals would break at once).
    my $world = $main_world ? undef : $EVWK_WORLD;
    if ($self->{_dead} || !$self->{view}) { $self->_defer_final($cb, undef, 'browser closed'); return }
    $cb = $self->_op_track($cb);   # so quit() mid-flight resolves this callback with 'browser closed' instead of dropping it
    # The replacer repairs lone UTF-16 surrogates. JavaScript strings are not
    # required to be well-formed unicode, and JSON.stringify faithfully emits an
    # unpaired \uD800-\uDFFF -- which a strict JSON decoder (rightly) refuses. So
    # ONE stray half-character anywhere in the document made html() fail
    # outright, and any element whose text contained one was unreadable, while
    # WebKit's own native title() handled the same data by substituting U+FFFD.
    # Do what WebKit does. (toWellFormed is ES2024 and present in this engine;
    # the manual fallback keeps an older one working.)
    my $body = eval {
        'const A = ' . _enc($args // {}) . ";\n"
      . 'const __wf = (s) => s.toWellFormed ? s.toWellFormed()'
      . ' : s.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "\uFFFD");' . "\n"
      . 'const __r = await (async () => { ' . $code . " })();\n"
      . 'return JSON.stringify(__r === undefined ? null : __r,'
      . ' (k, v) => typeof v === "string" ? __wf(v) : v);';
    };
    if ($@) { $self->_defer_final($cb, undef, 'encode error: ' . _clean($@)); return }
    my $cancel = Glib::IO::Cancellable->new;
    # kept alive only by the completion closure below capturing it -- otherwise GC'd once this sub returns (EV timer-lifetime gotcha).
    my $timer  = EV::timer($self->{timeout}, 0, sub { $cancel->cancel });
    my $done   = 0;
    # Glib::Object::Introspection's GAsyncReadyCallback marshalling does not
    # release its hold on this closure after it fires (confirmed in isolation
    # with a bare WebKit::WebView, independent of EV::WebKit's own object
    # graph) -- this closure's captured $self (a private copy made by the
    # `my ($self,...) = @_;` above, independent of the CALLER's own variable)
    # is therefore an unreachable, unbreakable-from-outside strong reference
    # that neither dropping the caller's reference nor quit() can ever touch.
    # Capture only a WEAK reference so this closure can't keep the browser
    # alive by itself; $cb (the user's own callback) is intentionally left
    # strong since nothing else owns it.
    weaken(my $wself = $self);
    $self->{view}->call_async_javascript_function(
        $body, -1, undef, $world, undef, $cancel, sub {
            # DO NOT REMOVE THE $done GUARD. This completion can be invoked more
            # than once (a cancellation racing a real completion), and the
            # _finish below must be called AT MOST ONCE per GAsyncResult --
            # calling it twice corrupts the heap ("free(): corrupted unsorted
            # chunks"). Nothing in the test suite can catch its removal: $cb is
            # _op_track'd, so a second delivery is deduped there and every
            # assertion still passes -- the only symptom is the corruption, and
            # only in some runs. Verified by mutation testing, which is the only
            # reason this is known.
            return if $done; $done = 1; $timer->stop;
            my $self = $wself or return;   # browser already torn down -- nothing to deliver to
            my $jsc = eval { $self->{view}->call_async_javascript_function_finish($_[1]) };
            if (my $e = $@) {
                $self->_defer($cb, undef, $cancel->is_cancelled ? 'timeout' : _clean($e));
                return;
            }
            my $val = eval { _dec($jsc->to_string) };
            return $self->_defer($cb, undef, "marshal error: "._clean($@)) if $@;
            $self->_defer($cb, $val, undef);
        });
    return;
}

# script/script_async run the user's own JS in the page's MAIN world (final
# arg true) so it sees the page's globals/libraries; find/atoms stay isolated.
sub script       { my ($s,$js,$cb)      = @_; Carp::croak('script: callback must be a code reference')       if defined $cb && ref $cb ne 'CODE'; $s->_call_js($js, {}, $cb, 1); return $s }
sub script_async { my ($s,$body,$a,$cb) = @_; Carp::croak('script_async: callback must be a code reference') if defined $cb && ref $cb ne 'CODE'; $s->_call_js($body, $a, $cb, 1); return $s }

sub find {
    my ($self, $sel, $cb) = @_;
    Carp::croak('find: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    $cb ||= sub {};   # an omitted callback is allowed -- the completion below calls $cb unconditionally, so give it a no-op rather than dying on undef
    # This wrapper closure (passed as _call_js's $cb) is itself captured
    # STRONGLY by _call_js's own (permanently GI-retained) completion
    # closure -- so even with _call_js's *own* $self weakened, THIS
    # closure's independent capture of $self is a second, equally-permanent
    # retaining path unless it too is weakened.
    weaken(my $wself = $self);
    $self->_call_js(
        'const el = document.querySelector(A.sel); return el ? { evwk_id: window.__evwk.put(el), evwk_epoch: window.__evwk.epoch } : null;',
        { sel => $sel },
        sub {
            my ($r, $err) = @_;
            return $cb->(undef, $err) if $err;
            return $cb->(undef, undef) unless defined $r;    # not found: undef, no error
            # A hostile/buggy page can make ANY JS value come back here (e.g.
            # Object.prototype.toJSON polluted to return something else
            # entirely) -- never trust the decoded shape before dereferencing
            # it: an unvalidated $r->{evwk_id} below would die inside
            # _defer's bare EV::timer(0,0,...), which EV's default $EV::DIED
            # swallows to stderr, permanently dropping this callback (a
            # silent hang, not an error) instead of ever reaching the caller.
            return $cb->(undef, 'find: unexpected result from page (registry tampered?)')
                unless ref $r eq 'HASH' && defined $r->{evwk_id};
            my $self = $wself or return $cb->(undef, 'browser closed');
            $cb->(EV::WebKit::Element->_new($self, $r->{evwk_id}, $r->{evwk_epoch}), undef);
        });
}

sub find_all {
    my ($self, $sel, $cb) = @_;
    Carp::croak('find_all: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    $cb ||= sub {};   # omitted callback allowed -- see find()
    # same reasoning as find() above -- weaken.
    weaken(my $wself = $self);
    $self->_call_js(
        'return [...document.querySelectorAll(A.sel)].map(e => ({ evwk_id: window.__evwk.put(e), evwk_epoch: window.__evwk.epoch }));',
        { sel => $sel },
        sub {
            my ($r, $err) = @_;
            return $cb->(undef, $err) if $err;
            # same shape distrust as find() above -- a tampered result (e.g.
            # the whole array replaced, or containing non-descriptor
            # elements) must degrade to a clean error, never dereference
            # blind and die inside _defer's unguarded timer.
            return $cb->(undef, 'find_all: unexpected result from page (registry tampered?)')
                unless ref $r eq 'ARRAY' && !grep { ref $_ ne 'HASH' || !defined $_->{evwk_id} } @$r;
            my $self = $wself or return $cb->(undef, 'browser closed');
            $cb->([ map { EV::WebKit::Element->_new($self, $_->{evwk_id}, $_->{evwk_epoch}) } @$r ], undef);
        });
}

# Shared by the core load-changed handler (in new(), above) and
# _update_chrome (below) -- both are independently-connected 'load-changed'
# listeners on the same view (chrome's fires FIRST -- see _build_chrome --
# so this must be a pure, side-effect-free read: it must return the SAME
# verdict for both call sites on the SAME event, before either one acts on
# it). True if a 'finished' event, arriving right now with the view
# currently (optimistically) showing $cur_uri, cannot be the current
# pending's own:
#
#  - mechanism 1 (committed-uri gate, primary): the pending has its OWN
#    captured committed uri ($p->[5], set on 'committed' -- see the
#    load-changed handler) and $cur_uri differs from it. Comparing
#    actual-committed to actual-committed (never to a user-passed target)
#    makes this immune to WebKit's own uri normalization/redirects. Inert
#    (falls through to mechanism 2) when the pending has NOT captured a
#    committed uri -- notably a bfcache-restored back()/forward(), which
#    jumps straight to 'finished' with no preceding started/committed at
#    all; gating on absence-of-commit here would hang a real, successful
#    navigation, so this mechanism deliberately does NOT do that.
#
#  - mechanism 2 (superseded-uri filter, covers what mechanism 1 can't): the
#    pending has NOT captured a committed uri, but _start_nav recorded the
#    identity of a nav it tore down mid-flight to create this pending (see
#    there). Unless $cur_uri happens to coincide with that identity -- an
#    irreducible, indistinguishable-but-harmless case (same uri either way;
#    see POD LIMITATIONS) -- a finished arriving before this pending's own
#    commit can only be that torn-down nav's belated tail, not a legitimate
#    bfcache-style finished of this pending's own (nothing was superseded to
#    create a genuine bfcache restore in the first place, so {_superseded}
#    is empty for one and this whole branch is skipped).
sub _finished_is_stray {
    my ($self, $cur_uri) = @_;
    my $p = $self->{pending} or return 0;
    if (defined $p->[5]) {
        return (!defined $cur_uri || $cur_uri ne $p->[5]) ? 1 : 0;
    }
    my $sup = $self->{_superseded};
    return 0 unless $sup && %$sup;
    return (defined $cur_uri && $sup->{$cur_uri}) ? 0 : 1;
}

sub _finish_nav {
    my ($self, $err, $gen) = @_;
    if (defined $gen) {
        # a generation-tagged caller (currently: only the per-nav timeout
        # timer, below) may only resolve the pending nav that minted it --
        # a timer belonging to an already-superseded/resolved nav must not
        # fire against whatever nav happens to be pending now. Compare
        # against the LIVE {pending} tuple (not a separately cached "current
        # gen" field): unlike such a field, this is automatically undef the
        # instant the matching nav resolves, with nothing to go stale.
        my $cur_gen = $self->{pending} ? $self->{pending}[2] : undef;
        return unless defined $cur_gen && $gen == $cur_gen;
    }
    my $p = delete $self->{pending};
    unless ($p) {
        # error with no pending nav (e.g. a stray load-failed): route to on_error.
        # This fires from the load-failed signal's glib dispatch frame, so defer it.
        # _defer_final, not _defer: on_error belongs to no registry (nothing
        # flushes it at quit), and the failure has ALREADY happened -- delivering
        # it needs nothing from $self. Through _defer it was hostage to the
        # instance outliving the tick, so a browser quit or dropped in the gap
        # swallowed the only notification a callback-less navigation ever gets.
        $self->_defer_final($self->{on_error}, $err) if $err && $self->{on_error};
        return;
    }
    $p->[1]->stop if $p->[1];
    my $cb = $p->[0];
    # {pending} is gone now, but the callback has NOT been delivered yet -- both
    # branches below hand it to a timer (a _defer tick, or the settle timer).
    # Between here and that tick it belongs to no registry, so a quit() (or a
    # bare drop, whose DESTROY runs quit) landing in the gap would silently drop
    # it. Track it: quit()'s flush then resolves it with 'browser closed', and
    # the wrapper dedupes, so whichever lands first wins and the other is a
    # no-op -- exactly once, either way.
    $cb = $self->_op_track($cb) if $cb;
    if ($err) {
        # signal-dispatch frame (load-failed) or quit()/_start_nav-supersede -- defer.
        # A nav started without a per-call callback still owes on_error a genuine
        # FAILURE (POD: on_error fires for a nav failure with no callback
        # waiting) -- otherwise it would vanish silently, since {pending} is
        # always populated so the "no pending" on_error branch above never runs
        # for an API-initiated nav. But 'superseded' is NOT a failure: it is
        # this instance's own intentional navigate-away (a later go()/back()/
        # reload() replacing an in-flight one), so a callback-less supersession
        # must NOT reach on_error. A caller that DID pass a callback still gets
        # 'superseded' delivered to it (the if-branch), unchanged.
        if    ($cb)                                       { $self->_defer($cb, undef, $err) }
        elsif ($self->{on_error} && $err ne 'superseded') { $self->_defer_final($self->{on_error}, $err) }   # _defer_final: see above
    }
    else {
        # defer so web-process props (title/uri) reach the UI process; keep the
        # timer reachable on $self (id-keyed, like _defer, so a second nav that
        # settles within NAV_SETTLE_DELAY of this one doesn't GC this still-
        # pending timer out from under it via a single-slot overwrite) so
        # quit() can cancel it, and guard on _dead.
        my $id = ++$_settle_seq;
        weaken(my $wself = $self);   # weak: same self-stored-timer cycle as the pending timer -- keep a bare drop during the brief settle window collectible
        $self->{_settle}{$id} = EV::timer(NAV_SETTLE_DELAY, 0, sub {
            my $self = $wself or return;
            delete $self->{_settle}{$id};
            return if $self->{_dead};
            # A throwing per-call callback must not rob on_load of its turn
            # (POD promises on_load fires for every successful instance-initiated
            # nav). Run the cb guarded, fire on_load, then re-surface the cb's
            # own exception so EV's $EV::DIED still logs it.
            my $cberr;
            if ($cb) { eval { $cb->(1, undef); 1 } or $cberr = $@ }
            # on_load guarded too: if it ALSO throws, its exception must not
            # replace the per-call callback's on the way out (that one would be
            # lost entirely, and it is the one the caller is likelier to be
            # debugging). Report on_load's, re-raise the callback's.
            if ($self->{on_load}) {
                unless (eval { $self->{on_load}->(); 1 }) {
                    warn "EV::WebKit: on_load callback died: $@";
                }
            }
            die $cberr if defined $cberr;
        });
    }
}

sub _start_nav {
    my ($self, $cb, $target) = @_;
    my $old = $self->{pending};
    # replace any in-flight nav with a superseded error -- always acts on
    # whatever is CURRENTLY pending (no gen check passed here: this is a
    # synchronous, direct resolution of the immediately-preceding nav, not a
    # stray external signal, so there is nothing to disambiguate against).
    $self->_finish_nav('superseded') if $old;
    # R11: {_superseded} only ever matters for disambiguating a stray tail
    # signal (load-changed:finished, or load-failed) belonging to whatever
    # THIS call just tore down mid-flight -- see _finished_is_stray and the
    # load-failed handler in new(). Reset it here, unconditionally, on
    # EVERY new nav (not just when one was actually superseded): its
    # relevance is scoped to exactly the window between this _start_nav call
    # and the next one, so a leftover, never-consumed entry (e.g. because
    # WebKit happened to never deliver the tail signal it seemed to owe)
    # can never persist to wrongly poison a later, unrelated pending's own
    # legitimate no-commit (bfcache-style) finished.
    $self->{_superseded} = {};
    if ($old && $old->[4]) {   # started_seen -- nothing was actually in flight otherwise, so no tail signal is owed
        # $old's own identity: its captured committed uri if it reached that
        # far, else whatever the view is optimistically showing for it right
        # now -- get_uri() here still reflects $old, since the caller (go/
        # reload/back/forward, below) hasn't yet issued the new
        # load/reload/go_back/go_forward call that would move it on.
        my $old_uri = defined $old->[5] ? $old->[5] : $self->{view}->get_uri;
        $self->{_superseded}{$old_uri} = 1 if defined $old_uri && length $old_uri;
    }
    my $gen = ++$_nav_seq;
    # WEAK: this timer lives inside $self->{pending}, so a strong $self here
    # would form a $self -> {pending} -> timer -> closure -> $self cycle that
    # a bare drop (no quit()) can't break until the nav resolves -- deferring
    # the instance's collection for up to {timeout}s (30s by default) while a
    # nav is in flight. Same class as the six handlers weakened for
    # collectability; quit() still stops this timer explicitly.
    weaken(my $wself = $self);
    my $timer = EV::timer($self->{timeout}, 0, sub { my $self = $wself or return; $self->_finish_nav('timeout', $gen) });
    $self->{pending} = [$cb, $timer, $gen, $target, 0, undef, 0];   # started_seen false, committed_uri undef, doc_scheme_seen false -- see load-changed/load-failed/mock_scheme
    # informational only (last-issued generation) -- unlike {pending}, this
    # is NOT cleared when the nav resolves, so it must never be used to test
    # "is a nav in flight" or as a gating comparison; _finish_nav's gen
    # check (above) reads the live {pending} tuple instead, precisely to
    # avoid that staleness.
    $self->{nav_gen} = $gen;
    return $gen;
}

sub go {
    my ($self, $uri, $cb) = @_;
    Carp::croak('go: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    if ($self->{_dead} || !$self->{view}) { $self->_defer_final($cb, undef, 'browser closed') if $cb; return $self }
    unless (defined $uri && length $uri) {    # a bare load_uri(undef) dies in the GI layer AND leaves {pending} dangling -- degrade cleanly instead
        $self->_defer_final($cb, undef, 'go: uri required') if $cb;
        return $self;
    }
    $self->{_seen_uris}{$uri} = 1;    # feeds save_cookies' default URI list
    my $gen = $self->_start_nav($cb, $uri);
    $self->{view}->load_uri($uri);
    # WebKit may normalize the requested uri (add a trailing slash,
    # lower-case the host, strip a default port, ...) -- get_uri() reflects
    # that normalized form synchronously, immediately after load_uri()
    # returns, so resync the tracked target to it for an apples-to-apples
    # compare against a later load-failed's failing_uri (which WebKit
    # reports already normalized) -- see the load-failed handler in new().
    # Gen-guarded: load_uri() can reenter (e.g. a mock_scheme producer
    # calling go() again) and supersede this very pending before this line
    # runs -- only touch {pending} if it is still the nav we just started.
    if ($self->{pending} && $self->{pending}[2] == $gen) {
        $self->{pending}[3] = $self->{view}->get_uri;
    }
    return $self;
}

sub load_html {
    my ($self, $html, $cb) = @_;
    Carp::croak('load_html: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    if ($self->{_dead} || !$self->{view}) { $self->_defer_final($cb, undef, 'browser closed') if $cb; return $self }
    $self->_start_nav($cb);   # no predictable target uri -- the load-failed uri-gate stays inert (undef) for this nav
    $self->{view}->load_html($html, undef);
    return $self;
}

sub _history_nav {
    my ($self, $can_method, $go_method, $errmsg, $cb) = @_;
    Carp::croak('callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    if ($self->{_dead} || !$self->{view}) { $self->_defer_final($cb, undef, 'browser closed') if $cb; return $self }
    unless ($self->{view}->$can_method) {
        # normal runtime condition (empty history side) -- deliver async, on a clean tick
        $self->_defer_final($cb, undef, $errmsg) if $cb;
        return $self;
    }
    $self->_start_nav($cb);   # target uri not predictable ahead of the actual history entry -- uri-gate stays inert; cb may be undef, resolves on load finish like go()
    $self->{view}->$go_method;
    return $self;
}

sub back    { my ($s,$cb)=@_; $s->_history_nav('can_go_back',    'go_back',    'cannot go back',    $cb) }
sub forward { my ($s,$cb)=@_; $s->_history_nav('can_go_forward', 'go_forward', 'cannot go forward', $cb) }

sub reload {
    my ($self, $cb) = @_;
    Carp::croak('reload: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    if ($self->{_dead} || !$self->{view}) { $self->_defer_final($cb, undef, 'browser closed') if $cb; return $self }
    unless (defined $self->{view}->get_uri && length $self->{view}->get_uri) {
        # nothing has ever been loaded -- WebKit emits no load-changed for a
        # reload() here, so the pending would resolve only via the full
        # timeout with a misleading 'timeout'. This is locally knowable, so
        # deliver a clean error at once, mirroring back()/forward().
        $self->_defer_final($cb, undef, 'nothing to reload') if $cb;
        return $self;
    }
    $self->_start_nav($cb);   # no target passed -- a mid-reload redirect could otherwise defeat a same-uri gate; uri-gate stays inert
    $self->{view}->reload;
    return $self;
}

sub stop {
    my ($self) = @_;
    return $self if $self->{_dead} || !$self->{view};
    $self->{view}->stop_loading;
    return $self;
}

sub can_go_back    { my $s=$_[0]; ($s->{_dead} || !$s->{view}) ? 0 : ($s->{view}->can_go_back    ? 1 : 0) }
sub can_go_forward { my $s=$_[0]; ($s->{_dead} || !$s->{view}) ? 0 : ($s->{view}->can_go_forward ? 1 : 0) }

sub uri        { my $s=$_[0]; ($s->{_dead} || !$s->{view}) ? undef : $s->{view}->get_uri }
sub title      { my $s=$_[0]; ($s->{_dead} || !$s->{view}) ? undef : $s->{view}->get_title }
sub is_loading { my $s=$_[0]; ($s->{_dead} || !$s->{view}) ? 0     : ($s->{view}->is_loading ? 1 : 0) }

sub html { my ($s, $cb) = @_; Carp::croak('html: callback must be a code reference') if defined $cb && ref $cb ne 'CODE'; $s->_call_js('return document.documentElement ? document.documentElement.outerHTML : null;', {}, $cb); return $s }

sub set_user_agent {
    my ($s, $ua) = @_;
    return $s if $s->{_dead} || !$s->{view};
    Carp::croak('set_user_agent: expected a string') if ref $ua;
    # WebKit's setter (isValidUserAgentHeaderValue) silently rejects a header
    # value it dislikes -- control chars, any byte >= 0x80, leading/trailing
    # whitespace, an embedded quote or backslash, ... -- by printing a C-level
    # CRITICAL, KEEPING THE OLD VALUE, and raising no Perl exception. The exact
    # accepted set varies by build and is broader than any charset guess we
    # tried, so don't guess: apply it, then read it back and croak if it did
    # not stick. (A bad UA still logs one WebKit CRITICAL before we croak --
    # unavoidable, since only set() knows the real rule.)
    my $settings = $s->{view}->get_settings;
    $settings->set('user-agent', $ua);
    if (defined $ua) {
        my $got = $settings->get('user-agent');
        Carp::croak('set_user_agent: WebKit rejected this user agent (unsupported characters -- e.g. a control char, a byte >= 0x80, leading/trailing whitespace, or an embedded quote/backslash)')
            unless defined $got && $got eq $ua;
    }
    $s;
}
sub user_agent     { my $s=$_[0]; ($s->{_dead} || !$s->{view}) ? undef : $s->{view}->get_settings->get('user-agent') }

# The resolved device profile for this instance (read-only), or undef. See the
# fingerprint => constructor option.
sub fingerprint          { $_[0]->{fingerprint} }
sub network_fingerprint  { $_[0]->{network_fingerprint} }              # active curl target, or undef
sub proxy_port           { my $s = shift; $s->{proxy} ? $s->{proxy}->port : undef }
sub fingerprint_profiles { shift; require EV::WebKit::Fingerprint; EV::WebKit::Fingerprint::profiles() }
sub fingerprint_available { require EV::WebKit::Fingerprint; EV::WebKit::Fingerprint::available() }

sub settings {
    my ($self, $kv) = @_;
    return $self if $self->{_dead} || !$self->{view};
    Carp::croak('settings: argument must be a hash reference') unless ref $kv eq 'HASH';
    my $s = $self->{view}->get_settings;
    # Validate all values BEFORE applying any: a reference value is never valid
    # for a WebKitSettings property (all are bool/int/string/enum scalars), and
    # GI's set() does not reject it -- it numifies the ref's ADDRESS into e.g.
    # an integer property, silently storing ASLR garbage that looks like
    # success. Checking up front also makes the common typed-value mistake
    # atomic (no partial application). NOTE: an invalid property NAME can still
    # only be detected by set() itself, mid-apply, so a croak from that path is
    # not transactional -- keys applied before it stay applied (see POD).
    for my $k (keys %$kv) {
        Carp::croak("settings: value for '$k' must be a scalar, not a " . ref($kv->{$k}) . ' reference')
            if ref $kv->{$k};
    }
    for my $k (keys %$kv) {
        (my $prop = $k) =~ tr/_/-/;
        # user-agent is just another WebKitSettings property, so it is reachable
        # through here -- but WebKit SILENTLY rejects a header value it dislikes
        # (keeps the old one, no exception, only a C-level CRITICAL). Without
        # this, settings({user_agent => $bad}) reported success while the value
        # never applied, quietly bypassing the very check set_user_agent exists
        # for. Route it through the validated path.
        if ($prop eq 'user-agent') { $self->set_user_agent($kv->{$k}); next }
        eval { $s->set($prop, $kv->{$k}); 1 } or Carp::croak("settings: cannot set '$k': " . _clean($@));
    }
    return $self;
}

sub set_proxy {
    my ($self, $proxy) = @_;
    return $self if $self->{_dead} || !$self->{session};
    my $s = $self->{session};
    # only undef and the literal string 'no-proxy' mean "clear the proxy" --
    # notably NOT '' (empty string), which is far more likely a caller
    # mistake than an intentional clear, and must not be swallowed silently
    # (see the URI validation below).
    if (!defined($proxy) || (!ref $proxy && $proxy eq 'no-proxy')) {
        $s->set_proxy_settings('no-proxy', undef);
        return $self;
    }
    my ($default, $ignore) = ref $proxy eq 'HASH'
        ? ($proxy->{default}, $proxy->{ignore} // [])
        : ($proxy, []);
    if (ref $proxy eq 'HASH') {
        Carp::croak('set_proxy: proxy hash requires a non-empty "default" URI')
            unless defined($default) && length($default);
        # A typo'd key (ignoer =>) must not be silently dropped -- the hosts the
        # caller meant to exempt would then be routed through the proxy.
        if (my @bad = sort grep { $_ ne 'default' && $_ ne 'ignore' } keys %$proxy) {
            Carp::croak("set_proxy: unknown proxy-hash key(s): @bad (expected 'default'/'ignore')");
        }
    }
    # A malformed default proxy URI is a privacy footgun: WebKit's own
    # webkit_network_proxy_settings_new/set_proxy_settings just print a
    # C-level CRITICAL and leave the proxy unset (routing direct) -- that is
    # NOT a Perl exception, so eval around set_proxy can never catch it.
    # Validate the shape (scheme://authority) proactively instead of trusting
    # WebKit to reject it.
    unless (defined($default) && !ref($default) && $default =~ m{^[a-z][a-z0-9+.-]*://[^/\s]+}i) {
        my $shown = !defined($default) ? '(undef)' : (ref($default) ? ref($default) : $default);
        Carp::croak("set_proxy: invalid proxy URI '$shown'");
    }
    # ignore_hosts is a GStrv: an undef entry marshals to a NULL that truncates
    # the list WebKit receives, silently routing the hosts AFTER it through the
    # proxy (a privacy leak -- the proxy analogue of a truncated deny-list). A
    # non-arrayref is a type error. Validate it. (An empty list is fine here: it
    # legitimately means "proxy every host".)
    Carp::croak('set_proxy: "ignore" must be an arrayref of host-pattern strings')
        unless ref $ignore eq 'ARRAY';
    defined && !ref && length or Carp::croak('set_proxy: "ignore" entries must be non-empty strings')
        for @$ignore;
    my $settings = WebKit::NetworkProxySettings->new($default, $ignore);
    $s->set_proxy_settings('custom', $settings);
    return $self;
}

# register a custom URI-scheme handler on this instance's WebContext, e.g.
# $b->mock_scheme('mock', sub { my ($uri)=@_; return ($body, $content_type) }).
# Must be called before the first navigation to that scheme.
sub mock_scheme {
    my ($self, $scheme, $producer) = @_;
    return $self if $self->{_dead} || !$self->{context};
    # WEAK: this persistent scheme-handler closure is held by $self->{context},
    # so capturing $self strongly would form a $self -> {context} -> handler ->
    # $self cycle that a bare drop (no quit()) can never break -- the same
    # leak class as the signal handlers in new(). It only needs $self on the
    # error path (to resolve the pending nav); the request itself is finished
    # regardless.
    weaken(my $wself = $self);
    $self->{context}->register_uri_scheme($scheme, sub {
        # WebKitURISchemeRequestCallback is (request, user_data) -- request is
        # $_[0], NOT $_[1] (verified live against WebKitGTK 2.52.4; passing an
        # undef user_data through unchanged, it is not hidden by the binding).
        my ($req, undef) = @_;
        local $IN_DISPATCH = 1;   # the producer runs nested in WebKit's dispatch frame -- see quit
        my $self = $wself;   # may be gone if the browser was dropped mid-request; we still finish the request below
        my $uri = $req->get_uri;

        # Claim the navigation's document slot HERE, before the producer runs, so
        # success and failure agree on which request was the document. The first
        # request of this navigation whose uri matches the view's is the main
        # document (subresources are only discovered after it is parsed); a later
        # request for the same uri -- a self-referencing <img>/fetch -- is a
        # subresource, and its outcome is the page's business, not the nav's. See
        # the error branch below, which only fails the nav when this request WAS
        # the document.
        my $is_doc;
        if (my $p = $self && $self->{pending}) {
            my $doc = $self->{view} ? $self->{view}->get_uri : undef;
            $is_doc = (defined $doc && $uri eq $doc && !$p->[6]) ? do { $p->[6] = 1; 1 } : 0;
        }

        my ($resp_body, $ctype) = eval { $producer->($uri) };
        if (my $e = $@) {
            # This callback is invoked directly by WebKit's C code via a GI
            # callback-argument (webkit_uri_scheme_request's callback, not a
            # glib signal) -- nothing upstream wraps it in an eval, so an
            # uncaught die here previously unwound straight through WebKit's
            # C stack and out past EV::run, killing the WHOLE PROCESS
            # (confirmed live: uncaught die -> Perl top-level -> exit 255).
            # Must never let that reach the caller.
            #
            # finish_error() looks like the obvious clean way to tell WebKit
            # "this request failed" (which would fail the load like a real
            # network error, via the load-failed signal), but it is NOT
            # usable with the installed binding: WebKitURISchemeRequest's
            # finish_error() takes its GError argument transfer-ownership=
            # "none" per the WebKit-6.0 .gir, and the installed
            # Glib::Object::Introspection 0.052's boxed-argument marshaling
            # (gperl-i11n-marshal-arg.c:sv_to_arg) unconditionally asserts
            # transfer==GI_TRANSFER_EVERYTHING for a boxed "in" argument.
            # Calling finish_error with any Glib::Error -- even wrapped in
            # eval -- aborts the whole process (SIGABRT; confirmed live:
            # "Bail out! ERROR:gperl-i11n-marshal-arg.c:118:sv_to_arg:
            # assertion failed") *before* eval can catch anything, because
            # it is a C-level abort(), not a Perl exception. So finish_error
            # must not be called here at all.
            #
            # Instead: resolve the pending navigation with a synthetic error,
            # exactly like the 'timeout'/'superseded' synthetic errors
            # _start_nav already funnels through _finish_nav from non-signal
            # contexts. Then finish the request itself with an inert
            # placeholder body so WebKit's own request bookkeeping is
            # satisfied (a request must be finished exactly once) -- its
            # content is never meant to be seen; the real signal already went
            # to the nav callback above.
            #
            # ONLY if this request IS the navigation's own document. The scheme
            # handler serves every request for the scheme, not just navigations:
            # an <img>/<script>/<iframe> subresource comes through here too.
            # Firing unconditionally meant a producer that threw on a subresource
            # failed the top-level navigation whose page had in fact loaded
            # perfectly -- and if the nav had already resolved, the throw was
            # routed to on_error instead, whose contract is a navigation failure
            # with no callback waiting, not an arbitrary later resource fetch.
            #
            # The test is the VIEW'S CURRENT URI, not {pending}[3]: that target
            # is undef by design for reload/back/forward (the uri is not
            # predictable ahead of the history entry), so gating on it ignored a
            # producer that threw on THEIR OWN document -- reload() then reported
            # a false SUCCESS while the page showed the error placeholder.
            # WebKit sets the view's uri to the new document when the provisional
            # load starts, BEFORE fetching it, so right now it equals the
            # main-document request's uri and differs from every subresource's.
            # Verified for go/reload/back/forward (including A->B, where the view
            # already reads as B) and for load_html, whose subresources never
            # match -- its document does not come through a uri scheme at all.
            # ...and only if this request WAS the navigation's document (claimed
            # at the top of this handler, the same way for success and failure).
            # A self-referencing subresource that throws must not fail a
            # navigation whose document already loaded.
            $self->_finish_nav('scheme handler error: ' . _clean($e)) if $self && $is_doc;
            my $msg   = 'scheme handler error';
            my $bytes = Glib::Bytes->new($msg);
            $req->finish(Glib::IO::MemoryInputStream->new_from_bytes($bytes), length($msg), 'text/plain');
            return;
        }
        $resp_body //= ''; $ctype //= 'text/html';
        # Glib::Bytes wants raw octets, not a Perl character string -- unlike
        # the JSON-bridge params above, this is not a GI `utf8`-typed
        # argument that expects/upgrades characters, so the producer's body
        # (documented as character data) must be byte-encoded here.
        # Unconditional, and on a COPY: a Latin-1-range scalar with the utf8
        # flag OFF (e.g. a bare "\x{e9}" literal, which Perl never flags) is
        # still, semantically, character data -- utf8::encode() correctly
        # turns either flag state into the right UTF-8 octets. Gating on
        # is_utf8() (as before) skipped that flag-off case and served its
        # raw Latin-1 byte instead of the 2-byte UTF-8 sequence, corrupting
        # any non-ASCII body that happened to stay unflagged. Encoding a
        # copy (not $resp_body itself) means the producer's own return value
        # is never mutated, however it is held.
        my $octets = $resp_body;
        utf8::encode($octets);
        my $bytes  = Glib::Bytes->new($octets);
        my $stream = Glib::IO::MemoryInputStream->new_from_bytes($bytes);
        $req->finish($stream, $bytes->get_size, $ctype);
    });
    return $self;
}

sub show_devtools {
    my $self = shift;
    return $self if $self->{_dead} || !$self->{view};
    $self->{view}->get_settings->set('enable-developer-extras', 1);
    $self->{view}->get_inspector->show;   # WebKitWebInspector
    return $self;
}

my $_waiter_seq = 0;

sub wait_for {
    my ($self, $sel, %o) = (shift, shift);
    my $cb = pop;
    Carp::croak('wait_for: last argument must be a callback') unless ref $cb eq 'CODE';
    %o = @_;
    if ($self->{_dead} || !$self->{view}) { $self->_defer_final($cb, undef, 'browser closed'); return $self }
    my $deadline = $o{timeout}  // $self->{timeout};
    my $interval = $o{interval} // 0.05;
    $interval = 0.05 unless defined $interval && $interval > 0;   # non-positive interval is meaningless for a poll -- snap to the default (else $elapsed never advances and the zero-delay re-poll busy-loops, starving the whole EV loop)
    my $visible  = $o{visible};
    my $elapsed  = 0;
    my $w;                       # current poll timer
    my $tick;
    my $wid;                     # registry id -- declared before $finish so its closure can capture it
    my $done = 0;                # idempotency guard: quit() and the normal tick path can each try to resolve
    # $finish, like $tick just below, is transitively captured (via $decide's
    # static reference to $tick, for its reschedule branch) into find()'s
    # wrapper closure, which -- via _call_js -- ends up strongly held by the
    # permanently GI-retained call_async_javascript_function completion
    # closure. So $finish's own capture of $self (needed below to
    # self-deregister from the waiter registry) must be weakened too, exactly
    # like $tick's -- one shared weak alias for the whole wait_for closure
    # family, established before either closure is built.
    weaken(my $wself = $self);
    my $finish = sub {           # single resolution point: break the $tick self-cycle + release the timer
        my ($el, $err) = @_;
        return if $done++;       # already resolved (e.g. quit() got there first) -- no-op
        delete $wself->{_waiters}{$wid} if $wself;
        undef $w;
        undef $tick;
        $cb->($el, $err);
    };
    # register so quit() can resolve this deterministically even if it lands
    # while a poll's find() is in flight (see quit(), below): _call_js's
    # completion is dead-gated via _defer, so a find() in flight at quit()
    # time would otherwise never reach $finish on its own. This is the ONE
    # place that needs $self (not $wself) strongly: at registration time the
    # caller is guaranteed to be holding a live reference (it just called a
    # method on it), and the registry entry is exactly what self-deregisters
    # (via $finish, above) on every resolution path -- so it is never the
    # sole thing keeping $self alive.
    $wid = ++$_waiter_seq;
    $self->{_waiters}{$wid} = $finish;
    $tick = sub {
        my $self = $wself or return;
        # belt-and-braces: quit()'s waiter registry (above) is what makes
        # resolution deterministic now, so this may fire before OR after
        # that resolution already ran -- $finish's own dedupe makes either
        # order safe.
        return $finish->(undef, 'browser closed') if $self->{_dead};
        $self->find($sel, sub {
            my ($el, $err) = @_;
            return $finish->(undef, $err) if $err;
            my $decide = sub {
                my ($ok) = @_;
                return $finish->($el, undef) if $ok;
                if ($elapsed >= $deadline) { return $finish->(undef, 'timeout') }
                $elapsed += $interval;
                $w = EV::timer($interval, 0, sub { $tick->() });
            };
            if ($el && $visible) {
                return $el->is_visible(sub {
                    my ($vis, $verr) = @_;
                    # 'stale element' here is NOT a failure -- it means the node
                    # find() matched was replaced between that round-trip and
                    # this one (a spinner swapped for content, a framework
                    # re-rendering). That is precisely the "not settled yet"
                    # state wait_for exists to poll through, so keep polling
                    # instead of finishing on it: a live page that churns the
                    # selector's node used to make wait_for(visible => 1) fail
                    # early with an error its own POD never mentions (only
                    # 'timeout'), rather than waiting for the element to hold
                    # still. Any OTHER error is real and terminal.
                    return $decide->(0) if defined $verr && $verr =~ /stale element/;
                    return $finish->(undef, $verr) if $verr;
                    $decide->($vis ? 1 : 0);
                });
            }
            $decide->($el ? 1 : 0);
        });
    };
    $tick->();
    return $self;
}

sub screenshot {
    my $self = shift;
    my $cb   = pop;
    Carp::croak('screenshot: last argument must be a callback') unless ref $cb eq 'CODE';
    if ($self->{_dead} || !$self->{view}) { $self->_defer_final($cb, undef, 'browser closed'); return $self }
    my ($path, %o);
    if (ref $_[0] eq 'HASH') { %o = %{ $_[0] } } else { $path = shift; %o = @_ }
    unless (defined $path || $o{bytes}) {
        $self->_defer_final($cb, undef, 'screenshot path required (or bytes => 1)');
        return $self;
    }
    my $region  = $o{full} ? 'full-document' : 'visible';
    my $options = $o{transparent} ? 'transparent-background' : 'none';
    $cb = $self->_op_track($cb);   # quit() mid-flight resolves this instead of dropping it
    my $cancel  = Glib::IO::Cancellable->new;
    my $timer   = EV::timer($self->{timeout}, 0, sub { $cancel->cancel });
    my $done    = 0;
    # same GI async-ready-callback retention as _call_js (see there) -- weaken.
    weaken(my $wself = $self);
    $self->{view}->get_snapshot($region, $options, $cancel, sub {
        return if $done; $done = 1; $timer->stop;
        my $self = $wself or return;
        my $tex = eval { $self->{view}->get_snapshot_finish($_[1]) };
        return $self->_defer($cb, undef, $cancel->is_cancelled ? 'timeout' : _clean($@)) if $@;
        my $data = eval { $tex->save_to_png_bytes->get_data };
        return $self->_defer($cb, undef, 'png encode: ' . _clean($@)) if $@;
        return $self->_defer($cb, $data, undef) if $o{bytes};
        open my $fh, '>:raw', $path or return $self->_defer($cb, undef, "open $path: $!");
        # print alone can look like it succeeded even when the underlying
        # write(2) is doomed (e.g. disk full): a short write is usually just
        # buffered by perlio, with the real failure only surfacing at close
        # (flush) time -- so capture errno right after print (in case it DID
        # fail synchronously) but let a subsequent close failure win, since
        # that's the common/authoritative case. Silently reporting success
        # here (as before) would tell the caller a screenshot exists when
        # nothing (or a truncated file) was actually written.
        my $ok  = print $fh $data;
        my $err = $!;
        unless (close $fh) { $ok = 0; $err = $! }
        return $self->_defer($cb, undef, "write $path: $err") unless $ok;
        $self->_defer($cb, $path, undef);
    });
    return $self;
}

sub pdf {
    my $self = shift;
    my $path = shift;
    my $cb   = pop;            # signature: pdf($path, %opt, $cb) -- callback is always last
    Carp::croak('pdf: last argument must be a callback') unless ref $cb eq 'CODE';
    if ($self->{_dead} || !$self->{view}) { $self->_defer_final($cb, undef, 'browser closed'); return $self }
    unless (defined $self->{view}->get_uri && length $self->{view}->get_uri) {
        # Printing a view that has NEVER loaded a document SIGSEGVs deep in
        # WebKit's C print path (a native crash no eval can catch) -- refuse
        # cleanly, mirroring reload()'s "nothing to reload" pre-check. Any
        # prior navigation (even load_html, even a not-yet-committed go())
        # gives the view a uri and makes printing safe.
        $self->_defer_final($cb, undef, 'pdf: no page loaded');
        return $self;
    }
    $cb = $self->_op_track($cb);   # quit() mid-flight resolves this (queued OR active) instead of dropping it
    my %o    = @_;
    # SERIALIZE: two WebKit::PrintOperations running on one view at the same
    # time race at the engine level -- the failing one can fire 'finished' (a
    # false success), or disrupt the other, making concurrent pdf() outcomes
    # non-deterministic (the R12 magic-check catches a false success but not a
    # good op that got clobbered). Queue each request and run exactly one
    # PrintOperation at a time.
    my $id = ++$_pdf_seq;
    push @{ $self->{_pdf_queue} }, [$id, $path, \%o, $cb];

    # Watchdog, armed HERE (at enqueue) rather than when the job reaches the
    # head of the queue: the caller asked for a deadline from the moment they
    # called, and a job waiting behind a slow -- or genuinely stuck -- print
    # must be bounded too, or it would never resolve at all. Keyed by job id in
    # {_pdf_timers} (never captured by _pdf_run's closures): the callback closes
    # over the id (a number), the tracked $cb and a weak $self only, so nothing
    # here can form a refcount cycle with the PrintOperation.
    weaken(my $wself = $self);
    $self->{_pdf_timers}{$id} = EV::timer($o{timeout} // $self->{timeout}, 0, sub {
        my $self = $wself or return;
        return if $self->{_dead};             # quit() already resolved this callback
        delete $self->{_pdf_timers}{$id};     # gone == "this caller has given up" (see _pdf_pump)
        # plain 'timeout' -- the SAME error every other timed op in this module
        # resolves with (navigation, wait_for, the cookie ops), so a caller can
        # test $err eq 'timeout' uniformly. pdf's other errors are prefixed
        # because they are pdf-specific; a timeout is a cross-cutting contract.
        $self->_defer($cb, undef, 'timeout');
    });
    $self->_pdf_pump;
    return $self;
}

# Start the next queued pdf job, if any and none is already running.
sub _pdf_pump {
    my $self = shift;
    return if $self->{_pdf_active} || $self->{_dead} || !$self->{view};
    my $q = $self->{_pdf_queue} || [];
    while (my $job = shift @$q) {
        # Its watchdog already fired (entry deleted), so this caller has been
        # told 'timeout' and is no longer waiting -- don't spend a print on a
        # document nobody wants. (An ALREADY-RUNNING op that times out is
        # different: it is still live and must keep the view -- see _pdf_run.)
        next unless exists $self->{_pdf_timers}{ $job->[0] };
        $self->{_pdf_active} = 1;
        $self->_pdf_run(@$job);
        return;
    }
    return;
}

# Run ONE PrintOperation to completion, then free the queue and pump the next.
sub _pdf_run {
    my ($self, $id, $path, $o, $cb) = @_;
    my $done     = 0;   # caller's callback resolved?
    my $released = 0;   # queue slot released?
    # weaken (as elsewhere): the $op and its signal closures are local/transient,
    # but never let a stray retention keep $self alive.
    weaken(my $wself = $self);

    # RESOLVING THE CALLER and RELEASING THE QUEUE are deliberately separate.
    # WebKit offers NO way to stop an in-flight print (WebKit-6.0's
    # PrintOperation has no cancel at all), so a print that has blown its
    # deadline is still running. Two PrintOperations alive on one view crash the
    # engine -- that race is the entire reason this queue exists -- so the
    # watchdog (armed in pdf(), at enqueue) only ever resolves the CALLER; it
    # must never hand the view to the next job. The view is released here, and
    # only when the engine itself says it is done with this operation.

    # resolve the caller exactly once. Does NOT touch the queue. (The watchdog
    # may already have answered them -- $cb is _op_track'd, so this is a no-op.)
    my $resolve = sub {
        my ($val, $err) = @_;
        return if $done; $done = 1;
        my $self = $wself or return;
        $self->_defer($cb, $val, $err);
    };
    # release the view for the next job, exactly once. ONLY safe when the engine
    # is really finished with this PrintOperation (its finished/failed arrived),
    # or when the op never started at all (setup/print threw). Also disarms this
    # job's watchdog: reached by id through $self, never captured here, so the
    # closures below cannot form a cycle with the PrintOperation.
    my $release = sub {
        return if $released; $released = 1;
        my $self = $wself or return;
        delete $self->{_pdf_timers}{$id};
        $self->{_pdf_active} = 0;
        # Kept on $self (weak closure, like every other timer here) so quit()
        # owns it: an untracked timer surviving teardown is exactly the kind of
        # loose end this module has been bitten by. Single slot is enough --
        # only one job is ever active, so only one pump can be in flight.
        $self->{_pdf_pump_timer} = EV::timer(0, 0, sub {
            my $s = $wself or return;
            delete $s->{_pdf_pump_timer};
            $s->_pdf_pump;
        });
    };
    # Wrap the WHOLE operation -- constructing the PrintOperation/settings/page
    # setup (which stringifies $path and the %opt values), connecting the
    # signals, and print() -- in one eval. A throw anywhere here (e.g. a hostile
    # $path/opt whose stringification dies, or a future stricter GI binding
    # rejecting a value) must reach the caller's callback and reset _pdf_active,
    # exactly as the print() throw already did: otherwise _pdf_active stays 1
    # and every later queued pdf() is starved forever (and a first job's throw
    # would escape synchronously out of pdf(), breaking its callback-only
    # contract). $op is declared in this scope (not the eval block) so its
    # lifetime is unchanged.
    my $op;
    my $dispatched = 0;   # has print() been entered? (see the failure branch below)
    my $ok = eval {
        my $paper = $o->{paper} // 'iso_a4';
        my $mm    = $o->{margin} // 0;
        my $dpi   = $o->{resolution} // 300;
        $op = WebKit::PrintOperation->new($self->{view});
        my $ps = Gtk4::PrintSettings->new;
        $ps->set('output-uri', 'file://' . rel2abs($path));
        $ps->set('output-file-format', 'pdf');
        $ps->set_resolution($dpi);
        $ps->set_printer('Print to File');
        $op->set_print_settings($ps);
        my $pgs = Gtk4::PageSetup->new;
        $pgs->set_paper_size(Gtk4::PaperSize->new($paper));
        $pgs->set_top_margin($mm,'mm');    $pgs->set_bottom_margin($mm,'mm');
        $pgs->set_left_margin($mm,'mm');   $pgs->set_right_margin($mm,'mm');
        $op->set_page_setup($pgs);
        $op->signal_connect(finished => sub {
            unless ($done) {
                # R12: 'finished' alone isn't trustworthy (moot now that we serialize,
                # kept as belt-and-braces) -- verify a real PDF was written before
                # reporting success, mirroring screenshot()'s post-write verification.
                my $valid = defined($path) && -s $path && do {
                    my $magic = '';
                    if (open my $fh, '<:raw', $path) { read($fh, $magic, 5); close $fh }
                    $magic eq '%PDF-';
                };
                $valid ? $resolve->($path, undef)
                       : $resolve->(undef, "pdf: print reported success but no valid PDF written to "
                           . (defined $path ? $path : '(undef path)'));
            }
            # The engine is done with this operation (even if the caller was
            # already given a 'timeout' answer above) -- only NOW is it safe to
            # hand the view to the next queued job.
            $release->();
        });
        $op->signal_connect(failed   => sub {
            $resolve->(undef, "pdf failed: ".(ref $_[1] ? $_[1]->message : ($_[1]//'')));
            $release->();
        });
        # NB: no watchdog is armed here -- this job's deadline has been running
        # since pdf() enqueued it (see there). And there is nothing to cancel:
        # WebKit-6.0's PrintOperation exposes no cancel method at all, so once
        # print() is under way the only thing that ends it is the engine.
        $dispatched = 1;
        $op->print;
        1;
    };
    # Setup or print threw. Always answer the caller. Whether we may hand the
    # view to the NEXT job depends on whether the engine could already be
    # printing:
    #   - the throw came from the setup statements above (paper/margin/path
    #     stringification, PrintSettings/PageSetup construction): nothing was
    #     dispatched, so release the slot -- otherwise _pdf_active stays 1 and
    #     every later pdf() starves forever.
    #   - the throw came from print() itself: we cannot know whether it got far
    #     enough to start the engine. Releasing on that guess would be betting
    #     the process on it -- a second PrintOperation alongside a live one
    #     SEGFAULTS WebKit (the race this whole queue exists to prevent). So
    #     hold the slot and let finished/failed release it, as on any normal
    #     print. If the engine truly never started, those never come and this
    #     instance's pdf() is done for -- but callers still get answers, not a
    #     hang: every queued job's watchdog was armed at enqueue and fires on
    #     its own deadline, and quit() clears the queue. A bounded, visible
    #     stall beats a crash we cannot rule out.
    # (print() takes no arguments and is void, so a throw from it would almost
    # certainly be a pre-dispatch marshalling failure -- but "almost certainly"
    # is not a basis for risking a SIGSEGV.)
    unless ($ok) {
        my $e = _clean($@);
        $resolve->(undef, $e);
        $release->() unless $dispatched;
    }
    return;
}

sub _cookie_mgr { $_[0]{session}->get_cookie_manager }

# GIO async completions for cookie-manager/website-data-manager ops arrive from
# inside the glib main-context dispatch that EV::Glib bridges into EV. Calling
# EV::break synchronously from that frame (as a user callback naturally would,
# matching every other callback in this module) unwinds out of ev_run while
# still nested inside the glib dispatch, which corrupts EV::Glib's
# prepare/check bookkeeping and wedges any *subsequent* EV::run into a
# permanent busy spin -- confirmed with gdb: the main thread parks at a single
# PC inside ev_run's pending-invoke loop, 99%+ CPU, no watcher (not even an
# unrelated native EV::timer) ever fires again. Invisible to single-EV::run
# tests (nothing runs afterward); fatal to the sequential-instance pattern
# this task's persistence test needs (instance A's cookie op must be followed
# by a second, independent EV::run for instance B). A zero-delay EV::timer
# defers the user callback to a clean top-level tick, fully unwound from the
# glib dispatch frame, which avoids the wedge.
my $_defer_seq = 0;
sub _defer {
    my ($self, $cb, @a) = @_;
    return unless $cb;   # matches _defer_final's guard -- a cb-less call is a clean no-op,
                         # not a deferred `undef->(@a)` (which EV would catch and route to
                         # $EV::DIED, but that's still noise a cb-optional call shouldn't cause)
    return if $self->{_dead};
    my $id = ++$_defer_seq;
    # weak, like every other closure this module hangs off $self: a strong $self
    # here is self -> {_defer}{id} -> timer -> closure -> self, a real cycle.
    # It happens to be self-healing (the one-shot fires, deletes itself, drops
    # the last ref), which is exactly why it hid from every collectability test
    # -- they all spin a tick before checking. But an instance dropped with a
    # deferral pending then stayed alive until the loop ticked again, and if it
    # never did, until process exit. Dropping the timer with $self is safe: quit
    # (which DESTROY runs) flushes {_ops}/{_waiters}/{pending} itself, so the
    # callback this timer was about to deliver is resolved there instead.
    weaken(my $wself = $self);
    $self->{_defer}{$id} = EV::timer(0, 0, sub {
        my $s = $wself or return;   # instance gone: quit() already flushed this callback
        delete $s->{_defer}{$id};
        $cb->(@a);
    });
    return;
}

# deliver an immediate-failure callback on the next clean EV tick, regardless
# of _dead (unlike _defer, which suppresses post-quit delivery of in-flight
# ops): calls made AFTER quit still owe their caller a 'browser closed'.
my $_final_seq = 0;
sub _defer_final {
    my ($self, $cb, @a) = @_;
    return unless $cb;
    my $id = 'f' . ++$_final_seq;
    # Deliberately NOT hung off $self: the answer is already decided, $self is
    # not needed to deliver it, and these callbacks (the early-error guards --
    # 'browser closed', 'uri required', ...) are in no registry, so quit() has
    # nothing to flush for them. Keeping the timer on $self would both create a
    # self -> hash -> timer -> closure -> self cycle AND make delivery hostage
    # to the instance outliving the tick -- drop the browser right after the
    # call and the callback would simply never fire. A file-scoped registry has
    # neither problem: the instance is collectable immediately, and the callback
    # still fires exactly once on the next tick.
    $FINAL{$id} = EV::timer(0, 0, sub {
        delete $FINAL{$id};
        $cb->(@a);
    });
    return;
}

# Register a one-shot async op's callback so quit() can resolve it with
# 'browser closed' even if the op is still in flight (its GAsyncReadyCallback
# completion is dead-gated via _defer and would otherwise be silently
# swallowed on quit -- the same dropped-callback class the loop treats as a
# defect). Returns a wrapper to use IN PLACE of $cb everywhere downstream: it
# fires the real $cb at most once (dedupe guard) and deregisters itself the
# instant it fires, whether that is a normal _defer delivery or quit()'s
# synchronous flush. The wrapper weakens $self so an in-flight op cannot keep
# a dropped browser alive (preserving the collectability guarantee, t/46) --
# it is only ever invoked while $self is live (a normal completion guards on
# $wself before delivering; quit()'s flush runs from within $self), so the
# weak alias is always valid at call time. wait_for/nav keep their own
# dedicated flush (see quit) and are NOT tracked here.
my $_op_seq = 0;
sub _op_track {
    my ($self, $cb) = @_;
    return $cb unless ref $cb eq 'CODE';
    my $id = ++$_op_seq;
    weaken(my $wself = $self);
    my $fired = 0;
    my $wrap = sub {
        return if $fired; $fired = 1;
        if (my $s = $wself) { delete $s->{_ops}{$id} }
        $cb->(@_);
    };
    ($self->{_ops} ||= {})->{$id} = $wrap;
    return $wrap;
}

# The set of native objects a cookie-manager async op must keep alive until
# its NATIVE side completes. quit()/DESTROY drop $self's references to these
# synchronously; if WebKit finalizes them (network session / web context)
# while a get_cookies/add_cookie is still in flight, it use-after-frees deep
# in its C code (segfault, reproducible). A cookie op captures this list
# strongly for the duration of the underlying GIO call and empties it (on a
# clean tick) the instant the call finishes -- so the objects outlive the op
# regardless of a concurrent teardown, yet never leak. $hold[0] is the session
# (callers use it to reach the cookie manager after $self->{session} is gone).
sub _native_hold { my $self = shift; return @{$self}{qw/session context ucm view/} }

# Release a captured native keep-alive (see _native_hold) on the next CLEAN EV
# tick. A cookie-manager completion must NOT drop these refs synchronously:
# doing so finalizes the network session/context from *inside* WebKit's own
# dispatch of that very completion, which re-enters and use-after-frees
# (segfault). Deferring the finalization out of the dispatch frame -- exactly
# why _defer exists -- makes it safe. Not dead-gated: it must run after quit()
# too, or the natives would leak. $ref is a reference to the op's @hold array.
sub _release_natives_later {
    my $ref = shift;
    my $rt; $rt = EV::timer(0, 0, sub { @$ref = (); undef $rt });
    return;
}

sub set_cookie {
    my ($self, $spec, $cb) = @_;
    Carp::croak('set_cookie: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    if ($self->{_dead} || !$self->{session}) { $self->_defer_final($cb, undef, 'browser closed'); return $self }
    unless (ref $spec eq 'HASH') {   # a plain-string arg would else die raw "Can't use string as a HASH ref" inside the loop below
        $self->_defer_final($cb, undef, 'set_cookie: spec must be a hash reference');
        return $self;
    }
    for my $k (qw/name value domain/) {
        unless (defined $spec->{$k}) {
            $self->_defer_final($cb, undef, "set_cookie: missing '$k'");
            return $self;
        }
    }
    # A typo'd security flag (secur => / http_ony =>) must not be silently
    # dropped: the cookie would then be created WITHOUT Secure/HttpOnly and sent
    # over plaintext / exposed to JS. Reject unknown spec keys.
    {
        my %known = map { $_ => 1 } qw/name value domain path max_age secure http_only/;
        if (my @bad = sort grep { !$known{$_} } keys %$spec) {
            $self->_defer_final($cb, undef, "set_cookie: unknown key(s): @bad");
            return $self;
        }
    }
    my $c = eval {
        Soup::Cookie->new(
            $spec->{name}, $spec->{value},
            $spec->{domain}, $spec->{path} // '/',
            $spec->{max_age} // -1,
        );
    };
    unless ($c) {
        $self->_defer_final($cb, undef, 'set_cookie: ' . _clean($@));
        return $self;
    }
    $c->set_secure(1)    if $spec->{secure};
    $c->set_http_only(1) if $spec->{http_only};
    $cb = $self->_op_track($cb);   # quit() mid-flight resolves this instead of dropping it
    my $cancel = Glib::IO::Cancellable->new;
    my $timer  = EV::timer($self->{timeout}, 0, sub { $cancel->cancel });   # watchdog: bound a stuck op (cancel -> completion resolves 'timeout')
    my @hold = $self->_native_hold;   # keep natives alive until this add_cookie's native side finishes (UAF on teardown otherwise -- see _native_hold)
    # same GI async-ready-callback retention as _call_js (see there) -- weaken.
    weaken(my $wself = $self);
    $hold[0]->get_cookie_manager->add_cookie($c, $cancel, sub {
        $timer->stop;
        my $ok = eval { $hold[0]->get_cookie_manager->add_cookie_finish($_[1]); 1 };   # captured session, NOT $self->{session} (deleted by quit)
        _release_natives_later(\@hold);   # drop the keep-alive on a clean tick (never synchronously here -- see _release_natives_later)
        my $self = $wself or return;
        $self->_defer($cb, $ok ? 1 : undef, $ok ? undef : ($cancel->is_cancelled ? 'timeout' : _clean($@)));
    });
    return $self;
}

sub cookies {
    my ($self, $uri, $cb) = @_;
    Carp::croak('cookies: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    if ($self->{_dead} || !$self->{session}) { $self->_defer_final($cb, undef, 'browser closed'); return $self }
    unless (defined $uri && length $uri) {
        $self->_defer_final($cb, undef, 'cookies: uri required');
        return $self;
    }
    $cb = $self->_op_track($cb);   # quit() mid-flight resolves this instead of dropping it
    my $cancel = Glib::IO::Cancellable->new;
    my $timer  = EV::timer($self->{timeout}, 0, sub { $cancel->cancel });   # watchdog: bound a stuck op (cancel -> completion resolves 'timeout')
    my @hold = $self->_native_hold;   # keep natives alive until this get_cookies' native side finishes (UAF on teardown otherwise -- see _native_hold)
    weaken(my $wself = $self);
    $hold[0]->get_cookie_manager->get_cookies($uri, $cancel, sub {
        $timer->stop;
        # get_cookies_finish returns a single arrayref of Soup::Cookie objects,
        # NOT a flattened list -- must deref, not `my @c = ...finish(...)`. Use
        # the captured session (NOT $self->{session}, which quit deletes).
        my $list = eval { $hold[0]->get_cookie_manager->get_cookies_finish($_[1]) };
        _release_natives_later(\@hold);   # drop the keep-alive on a clean tick (never synchronously here -- see _release_natives_later)
        my $self = $wself or return;
        return $self->_defer($cb, undef, $cancel->is_cancelled ? 'timeout' : _clean($@)) if $@;
        $self->_defer($cb, [ map { {
            name   => $_->get_name,   value  => $_->get_value,
            domain => $_->get_domain, path   => $_->get_path,
            secure => $_->get_secure ? 1 : 0, http_only => $_->get_http_only ? 1 : 0,
        } } @$list ], undef);
    });
    return $self;
}

sub clear_cookies {
    my ($self, $cb) = @_;
    Carp::croak('clear_cookies: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    if ($self->{_dead} || !$self->{session}) { $self->_defer_final($cb, undef, 'browser closed'); return $self }
    # Deliberately NO _native_hold here, unlike its three cookie-manager
    # siblings above. Those crash if the session is finalised under an in-flight
    # op; this one goes through the website-data-manager, whose native lifetime
    # does not depend on {session}/{view} surviving teardown, so it is safe
    # without one (originally established when the teardown UAF was fixed, and
    # re-confirmed since under ~900 quit/DESTROY-mid-flight iterations and
    # valgrind). Keep it that way -- do not "restore uniformity" by adding a
    # hold, and do not copy this op's shape onto a cookie-manager one.
    my $wdm = $self->{session}->get_website_data_manager;
    $cb = $self->_op_track($cb);   # quit() mid-flight resolves this instead of dropping it
    my $cancel = Glib::IO::Cancellable->new;
    my $timer  = EV::timer($self->{timeout}, 0, sub { $cancel->cancel });   # watchdog: bound a stuck op (cancel -> completion resolves 'timeout')
    weaken(my $wself = $self);
    # WebKit::WebsiteDataTypes is a GFlags type: Glib::Object::Introspection
    # marshals flags as an arrayref of nick strings, not a bare string.
    # 0 timespan = clear everything (not just data since some cutoff).
    $wdm->clear(['cookies'], 0, $cancel, sub {
        $timer->stop;
        my $self = $wself or return;
        my $ok = eval { $wdm->clear_finish($_[1]); 1 };
        $self->_defer($cb, $ok ? 1 : undef, $ok ? undef : ($cancel->is_cancelled ? 'timeout' : _clean($@)));
    });
    return $self;
}

sub save_cookies {
    my $self = shift;
    my $cb   = pop;
    Carp::croak('save_cookies: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    if ($self->{_dead} || !$self->{session}) { $self->_defer_final($cb, undef, 'browser closed'); return $self }
    my $file = shift;
    unless (defined $file && length $file) {
        $self->_defer_final($cb, undef, 'snapshot file required');
        return $self;
    }
    my $uris = (ref $_[0] eq 'ARRAY') ? shift : [ keys %{ $self->{_seen_uris} || {} } ];
    unless (@$uris) {
        $self->_defer_final($cb, undef, 'no URIs to save (navigate first or pass a URI list)');
        return $self;
    }

    # Per-URI get_cookies (NOT get_all_cookies): get_all_cookies/get_all_cookies_finish
    # are a latent memory-safety hazard (valgrind-confirmed invalid read when a call is
    # left in-flight at teardown -- see .superpowers/sdd/cookie-investigation-report.md).
    # get_cookies($uri) is the proven-clean enumeration path already used by cookies()
    # above, so save_cookies fans it out across every URI this instance has navigated
    # to (or an explicit list) and merges the results. This is an explicit, opt-in JSON
    # snapshot -- distinct from cookie_jar's native persistence (see new()) -- and the
    # only way to capture SESSION cookies, which native persistence excludes by design.
    # Expiry stays session-only here: get_expires dies (GDateTime not registered with
    # gperl in this GI binding), so it is deliberately never called.
    $cb = $self->_op_track($cb);   # quit() mid-flight resolves this instead of dropping it
    my (%dedup, @rows, $err);
    my $pending = scalar @$uris;
    my @hold = $self->_native_hold;   # keep natives alive until ALL per-URI get_cookies native sides finish (UAF on teardown otherwise -- see _native_hold); released once on the last completion
    # one shared weak $self, captured by every per-URI closure below (same GI
    # async-ready-callback retention as _call_js -- see there).
    weaken(my $wself = $self);
    my @cancels;
    my $timer = EV::timer($self->{timeout}, 0, sub { $_->cancel for @cancels });   # one watchdog for the whole fan-out -- cancel every in-flight per-URI op
    for my $uri (@$uris) {
        my $cancel = Glib::IO::Cancellable->new;
        push @cancels, $cancel;
        $hold[0]->get_cookie_manager->get_cookies($uri, $cancel, sub {
            my $list = eval { $hold[0]->get_cookie_manager->get_cookies_finish($_[1]) };   # captured session, NOT $self->{session} (deleted by quit)
            # A snapshot is all-or-nothing on purpose: writing a file that is
            # silently missing one URI's cookies is worse than not writing one.
            # But name the URI that failed -- with a bare message the caller
            # cannot tell WHICH of the fan-out went wrong.
            if ($@) { $err = $cancel->is_cancelled ? 'timeout' : "$uri: " . _clean($@) }
            elsif (ref($list) eq 'ARRAY') {
                for my $c (@$list) {
                    my $key = join("\x1e", $c->get_name, $c->get_domain, $c->get_path);
                    next if $dedup{$key}++;
                    push @rows, {
                        name      => $c->get_name,           value     => $c->get_value,
                        domain    => $c->get_domain,          path      => $c->get_path,
                        secure    => $c->get_secure ? 1 : 0,  http_only => $c->get_http_only ? 1 : 0,
                    };
                }
            }
            my $last = (--$pending <= 0);            # decrement regardless of $self liveness so the keep-alive is always released
            $timer->stop if $last;                   # all per-URI ops done -- disarm the watchdog
            _release_natives_later(\@hold) if $last; # last per-URI native op done -- drop the keep-alive on a clean tick
            my $self = $wself or return;
            return if !$last;            # more URIs still in flight
            return $self->_defer($cb, undef, $err) if $err;
            my $ok = eval {
                # :utf8 -- _enc (character-mode codec) can hand back a wide
                # Perl string; encode it properly instead of a raw byte dump.
                open my $fh, '>:utf8', $file or die "open $file: $!\n";
                print $fh _enc(\@rows);
                close $fh or die "close $file: $!\n";
                1;
            };
            return $self->_defer($cb, undef, _clean($@)) unless $ok;
            $self->_defer($cb, scalar(@rows), undef);
        });
    }
    return $self;
}

sub load_cookies {
    my ($self, $file, $cb) = @_;
    Carp::croak('load_cookies: callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    if ($self->{_dead} || !$self->{session}) { $self->_defer_final($cb, undef, 'browser closed'); return $self }
    unless (defined $file && length $file) {
        $self->_defer_final($cb, undef, 'snapshot file required');
        return $self;
    }
    $cb = $self->_op_track($cb);   # quit() mid-flight resolves this instead of dropping it
    return $self->_defer($cb, 0, undef) unless -e $file;
    my $rows = eval {
        # :utf8 -- must hand _dec (character-mode codec) back a proper
        # character string, matching how save_cookies wrote it.
        open my $fh, '<:utf8', $file or die "open $file: $!\n";
        my $json = do { local $/; <$fh> };
        close $fh;
        _dec($json);
    };
    $rows = [] if $@ || ref($rows) ne 'ARRAY';   # treat garbage/unreadable jar as empty, not fatal
    # ...and the same for each individual row: a non-hashref entry or one
    # missing a required key is skipped rather than fatal (set_cookie itself
    # now degrades the same way for a bad spec -- see above -- but filtering
    # here keeps the loaded-count semantics honest, since a skipped row was
    # never even attempted).
    my @valid = grep {
        ref $_ eq 'HASH' && defined $_->{name} && defined $_->{value} && defined $_->{domain}
    } @$rows;
    my $n = @valid;
    return $self->_defer($cb, 0, undef) unless $n;
    my ($pending, $loaded, $timedout) = ($n, 0, 0);
    weaken(my $wself = $self);
    for my $row (@valid) {
        $self->set_cookie({
            name      => $row->{name},    value     => $row->{value},
            domain    => $row->{domain},  path      => $row->{path},
            max_age   => defined $row->{expires} ? $row->{expires} - time() : -1,
            secure    => $row->{secure},  http_only => $row->{http_only},
        }, sub {
            my ($ok, $err) = @_;
            $loaded++ if $ok;
            # A watchdog timeout cancelled the delegated set_cookie(s): the load
            # was cut short, so say so. Reporting the plain (loaded, undef) count
            # here would be indistinguishable from "the jar held no valid rows".
            $timedout = 1 if defined $err && $err eq 'timeout';
            return if --$pending > 0;
            # If quit() has torn the browser down, do NOT deliver a
            # (loaded, undef) success here: each delegated set_cookie is its
            # own tracked op, so quit()'s flush fires this last one AND our
            # own {_ops} entry in an undefined order -- letting this branch win
            # would hand the caller a fake 0-loaded "success" instead of the
            # 'browser closed' our own entry owes them. Leave it to that entry.
            return if $wself && $wself->{_dead};
            # otherwise we're on a clean tick (set_cookie routes its callback
            # through _defer), so a direct $cb->() is safe.
            return $cb->(undef, 'timeout') if $timedout;
            $cb->($loaded, undef);
        });
    }
    return $self;
}

sub quit {
    my $self = shift;
    return if $self->{_dead};
    $self->{_dead} = 1;                                   # set first: re-entrant calls now hit the guards
    # Shut the in-process proxy down first: plain EV/Perl (no GI callbacks), so
    # it is safe even inside a dispatch frame, and stopping it before the
    # GI/window teardown keeps proxy traffic from racing it.
    if (my $proxy = delete $self->{proxy}) { eval { $proxy->shutdown } }
    delete $self->{network_fingerprint};
    $_->stop for values %{ $self->{_defer} || {} };       # cancel in-flight deferred callbacks
    $self->{_defer} = {};
    $_->stop for values %{ $self->{_settle} || {} };
    $self->{_settle} = {};
    if (my $c = $self->{chrome}) { $_->stop for values %{ $c->{settle} || {} }; $c->{settle} = {} }
    # Called from INSIDE a WebKit/GLib dispatch frame (on_dialog, on_policy,
    # on_console, a mock_scheme producer)? Then finish on a clean EV tick
    # instead of here. _teardown resolves other ops' callbacks, and those are
    # promised to arrive on a clean tick -- running one nested in WebKit's frame
    # means a caller's EV::break lands there too, which busy-spins the NEXT
    # EV::run (the EV::Glib lifecycle wedge; see the on_dialog POD). Destroying
    # the native window/view inside that frame is the same class of hazard
    # _release_natives_later exists for. We got here through the loop, so the
    # tick is guaranteed to fire; the timer's strong $self keeps the instance
    # alive until it does. NOT during DESTROY: taking a strong ref to a
    # refcount-0 object resurrects it, and it would be freed anyway the moment
    # DESTROY returns, leaving the timer holding a corpse -- there we tear down
    # in place (nothing can still hold a callback that reaches back to $self, or
    # the refcount would not have hit 0).
    if ($IN_DISPATCH && !$self->{_destroying}) {
        my $t; $t = EV::timer(0, 0, sub { undef $t; $self->_teardown });
        return;
    }
    $self->_teardown;
    return;
}

# Resolve every outstanding async callback exactly once with 'browser closed',
# so nothing a caller is awaiting is silently dropped by _defer's dead-gate,
# then release the natives. wait_for waiters have their own registry (each
# finisher self-dedupes -- see wait_for); every other one-shot op
# (script/find/html/screenshot/pdf/cookie) is tracked in {_ops} (see _op_track)
# and its wrapper likewise fires at most once. Clear each registry BEFORE firing
# so a wrapper's own self-deregister -- or a re-entrant call from the user's
# callback -- finds nothing to delete. Waiters first: a wait_for poll's find()
# lives in {_ops} too, but its finisher has already run by the time that wrapper
# fires (a no-op).
sub _teardown {
    my $self = shift;
    # Collect every owed callback first, then decide HOW to deliver them.
    my @w = values %{ $self->{_waiters} || {} };
    $self->{_waiters} = {};
    my @ops = values %{ $self->{_ops} || {} };
    $self->{_ops} = {};
    my @owed = (@w, @ops);
    $self->{_pdf_queue} = []; $self->{_pdf_active} = 0;   # drop un-started pdf jobs (their cbs are owed below via {_ops}); an active PrintOperation's stray completion is a _defer no-op after this
    $self->{_pdf_timers} = {};                            # disarm every pdf watchdog (queued and active)
    delete $self->{_pdf_pump_timer};                      # and the queue's own continuation tick (nothing left to pump)
    if (my $p = delete $self->{pending}) {                # a still-pending nav is owed an answer too (not via _defer, which now no-ops)
        $p->[1]->stop if $p->[1];
        push @owed, $p->[0] if $p->[0];
    }
    # Still inside a WebKit dispatch frame? Then these callbacks must not run
    # HERE. quit() defers the whole teardown for exactly that reason -- but it
    # cannot when DESTROY brought us here (a strong ref to a refcount-0 object
    # resurrects a corpse), so a bare drop from inside a handler lands right
    # here with the frame still on the stack. Release the natives in place (no
    # choice at refcount 0) but hand the CALLBACKS to a clean tick: delivering
    # them needs nothing from $self -- their answer is already decided -- so the
    # same file-scoped registry _defer_final uses carries them out without
    # holding the instance. ($IN_DISPATCH is false on quit()'s own deferred
    # tick, since `local` unwound with the handler, so that path still delivers
    # synchronously -- as it must, or `$b->quit` with no further EV::run would
    # never resolve anything.)
    if ($IN_DISPATCH) { _flush_later(\@owed) }
    else              { _flush($_) for @owed }
    $self->{win}->destroy if $self->{win};                # release the native GTK window (caller owns the X display)
    delete @{$self}{qw/view win ucm session context chrome _user_scripts _user_styles/};
    return;
}

# Deliver owed callbacks on a clean tick, capturing ONLY the callbacks -- never
# $self, so this can be used while $self is being destroyed.
sub _flush_later {
    my $cbs = shift;
    my @cbs = grep { $_ } @$cbs;
    return unless @cbs;
    my $id = 'q' . ++$_final_seq;
    $FINAL{$id} = EV::timer(0, 0, sub { delete $FINAL{$id}; _flush($_) for @cbs });
    return;
}

# Deliver one flushed callback. EVERY invocation is guarded: a throwing user
# callback must not abort the flush -- that would silently drop every sibling
# callback after it AND skip the native teardown below it. {_dead} is set on
# quit()'s first line, so a later quit() can never retry: an exception escaping
# here used to leak the window, the WebView (with its web + network processes),
# the context and the session for the rest of the process's life, and under a
# bare drop (DESTROY evals quit) it did so in total silence. warn, as on_dialog
# already does for the same reason -- quit() itself never throws.
sub _flush {
    my $cb = shift;
    return unless $cb;
    return if eval { $cb->(undef, 'browser closed'); 1 };
    warn "EV::WebKit: callback died during quit(): $@";
    return;
}
# _destroying: tells quit() it is running on a refcount-0 object, so it must
# tear down in place and never defer itself onto a timer (which would take a
# fresh strong ref to a corpse -- see quit).
sub DESTROY { my $self = shift; $self->{_destroying} = 1; eval { $self->quit } }

{
    package EV::WebKit::UserContent;
    # Handle for one injected user script or stylesheet. Holds a WEAK ref to the
    # browser (so a dangling handle never keeps the instance alive) plus the id
    # of its native in the browser's per-kind registry. remove() is idempotent:
    # the shared registry is the single source of truth, so an item removed
    # individually OR by remove_all_user_* (which clears the registry) makes
    # every later remove() on it a clean no-op.
    sub _new {
        my ($class, $browser, $id, $kind) = @_;
        my $self = bless { id => $id, kind => $kind }, $class;
        Scalar::Util::weaken($self->{browser} = $browser);
        return $self;
    }
    sub remove {
        my $self = shift;
        my $b = $self->{browser} or return $self;       # browser already collected
        return $self if $b->{_dead} || !$b->{ucm};      # torn down: registry gone with the ucm
        my $reg = $b->{"_user_$self->{kind}s"} or return $self;
        my $native = delete $reg->{ $self->{id} } or return $self;   # already removed
        my $m = $self->{kind} eq 'style' ? 'remove_style_sheet' : 'remove_script';
        $b->{ucm}->$m($native);
        return $self;
    }
}

{
    package EV::WebKit::Dialog;
    # lightweight wrapper around a WebKitScriptDialog, valid only for the
    # duration of the script-dialog signal handler that receives it.
    sub _new    { bless { d => $_[1] }, $_[0] }
    sub type    { $_[0]{d}->get_dialog_type }        # nick: alert/confirm/prompt/before-unload-confirm
    sub message { $_[0]{d}->get_message }

    # confirm/before-unload-confirm share the one confirm_set_confirmed setter;
    # alert has no setter at all (acknowledging it is just returning handled=1).
    sub _is_confirm { $_[0] eq 'confirm' || $_[0] eq 'before-unload-confirm' }

    sub accept {
        my ($s, $text) = @_;
        my $d = $s->{d};
        my $t = $d->get_dialog_type;
        if    ($t eq 'prompt')    { $d->prompt_set_text($text) if defined $text }
        elsif (_is_confirm($t))   { $d->confirm_set_confirmed(1) }
        $s->{answered} = 1;
    }

    sub dismiss {
        my $s = shift;
        my $d = $s->{d};
        my $t = $d->get_dialog_type;
        $d->confirm_set_confirmed(0) if _is_confirm($t);
        $s->{answered} = 1;
    }
}

{
    package EV::WebKit::Policy;
    # lightweight wrapper around a WebKit(Navigation|Response)PolicyDecision,
    # valid only for the duration of the decide-policy signal handler that
    # receives it.
    sub _new  { bless { d => $_[1], type => $_[2], uri => $_[3] }, $_[0] }
    sub uri   { $_[0]{uri} }             # nav/new-window: request URI; response: request URI
    sub type  { $_[0]{type} }            # nick: navigation-action/new-window-action/response
    sub allow { $_[0]{d}->use;    $_[0]{done} = 1 }
    sub block { $_[0]{d}->ignore; $_[0]{done} = 1 }
}

1;

=pod

=head1 NAME

EV::WebKit - async WebKitGTK 6.0 (GTK4) browser automation on EV

=head1 SYNOPSIS

    use EV;
    use EV::WebKit;

    # run under `xvfb-run -a perl script.pl` for a headless display,
    # or with a real $DISPLAY for a visible, interactive window.

    die "WebKitGTK 6.0 / GTK4 typelibs not available\n"
        unless EV::WebKit->available;

    my $b = EV::WebKit->new(
        window     => [1024, 768],
        on_console => sub { warn "console: $_[0]\n" },
        on_error   => sub { warn "error: $_[0]\n" },
    );

    $b->go('https://example.com', sub {
        my (undef, $err) = @_;
        die "navigation failed: $err\n" if $err;

        $b->find('h1', sub {
            my ($el, $err) = @_;
            die "find failed: $err\n" if $err;
            $el->text(sub { print "H1: $_[0]\n" }) if $el;
        });

        $b->wait_for('#maybe-async', timeout => 5, sub {
            my ($el, $err) = @_;   # $err eq 'timeout' just means it never showed up

            $b->screenshot('shot.png', sub {
                my (undef, $err) = @_;
                warn "screenshot failed: $err\n" if $err;
                # quit() resolves anything STILL in flight with 'browser
                # closed' -- so only quit once you have the results you want.
                $b->quit;
                EV::break;
            });
        });
    });

    EV::run;

Pass C<< chrome => 1 >> to C<new> and export a real C<$DISPLAY> (instead of
C<xvfb-run>) for a visible, interactive window with basic back/forward/reload
chrome; every method above keeps working unchanged.

=head1 DESCRIPTION

EV::WebKit drives a real, in-process WebKitGTK 6.0 web view for browser
automation: navigation, DOM queries and manipulation, JavaScript execution,
screenshots, PDF export, cookies, and basic network control. It is pure
Perl over GObject Introspection -- no XS, no C compiler needed for this
distribution -- and integrates WebKitGTK's GLib main loop into L<EV> via
L<EV::Glib>, so it composes with other EV-based code in the same process.

DOM access works by injecting JavaScript through WebKit's
C<call_async_javascript_function> and JSON-marshalling the result back into
Perl data; elements found via C<find>/C<find_all> are returned as
lightweight L<EV::WebKit::Element> handles (a page-side registry id plus a
back-reference to the browser), not live DOM references held on the Perl
side -- see L<EV::WebKit::Element>.

EV::WebKit does not manage a display of its own; see L</"LIMITATIONS">.

=head1 CALLBACK CONVENTION

EV::WebKit is entirely single-threaded and cooperative: every operation
that talks to the web view is asynchronous and runs on the ambient L<EV>
loop. The caller starts and stops that loop (C<EV::run>, C<EV::break>) --
no EV::WebKit method ever calls either for you. Methods that need to wait
for a result take a trailing callback:

    sub { my ($result, $err) = @_; ... }

On success, C<$err> is C<undef> and C<$result> holds the method's result
(shape documented per method below). On failure, C<$result> is C<undef>
and C<$err> is a short, human-readable string -- Perl's own " at FILE line
N." diagnostic suffix is stripped where it would otherwise appear -- such
as C<timeout>, C<browser closed>, or a cleaned JavaScript exception
message. Methods never throw for ordinary runtime failures; always check
C<$err>. A handful of methods are plain synchronous accessors/mutators
(C<uri>, C<title>, C<is_loading>, C<can_go_back>, C<can_go_forward>,
C<stop>, C<user_agent>, C<set_user_agent>, C<settings>, C<set_proxy>,
C<mock_scheme>, C<show_devtools>, C<quit>) and take no callback at all.

C<EV::break> is safe to call directly from the trailing C<($result, $err)>
callbacks described above, and from C<on_load>/C<on_error>/C<on_close>, since
all of those run on a clean EV tick. C<on_console>, C<on_dialog>, C<on_policy>
and a C<mock_scheme> producer, however, all fire synchronously inside WebKit's
own dispatch frame -- do NOT call C<EV::break> directly from those; schedule it
instead, e.g. C<< EV::timer(0, 0, sub { EV::break }) >>. (Calling C<quit>
from them B<is> safe: it detects the frame and defers its own teardown.)

=head1 CONSTRUCTOR

=head2 available

    my $ok = EV::WebKit->available;

Returns true if the required WebKit-6.0/Gtk-4.0/Gdk-4.0/JavaScriptCore-6.0
and Soup-3.0 GObject-Introspection typelibs can be loaded, false
otherwise. Safe to call before C<new> to fail gracefully (e.g. to C<plan
skip_all> a test) instead
of letting C<new> die. Checking typelib availability does not require a
display.

=head2 new

    my $b = EV::WebKit->new(%options);

Constructs a new browser: sets up (once per process) the GObject
Introspection typelibs, initializes GTK4 (only once a display is known --
see L</"LIMITATIONS">), creates a WebKit network session, user content
manager, web context and view, and shows a native GTK4 window containing
it. Dies if the typelibs are unavailable or if no X display can be
determined (see C<display> below). C<%options>:

=over 4

=item C<< window => [$width, $height] >>

Initial window size in pixels. Default C<[1280, 1024]>.

=item C<< display => ':N' >>

Sets C<$ENV{DISPLAY}> to this value before initializing GTK. If omitted, an
already-exported C<$DISPLAY> is used; if neither is available, C<new> dies
telling you to run under C<xvfb-run> or pass this option -- EV::WebKit
never starts an X server itself (see L</"LIMITATIONS">).

B<One display per process.> GTK connects to a display once and cannot be
moved to another, so every instance after the first shares the first one's
display. Passing a C<display> that disagrees with it croaks rather than
being silently ignored.

=item C<< timeout => $seconds >>

Default per-operation timeout, in seconds. Applies to every async operation
that can block -- navigation (C<go>/C<load_html>/C<back>/C<forward>/
C<reload>), C<script>/C<script_async>, C<find>/C<find_all> and the
L<EV::WebKit::Element> accessors, C<html>, C<screenshot>, C<pdf>, and the
cookie operations (C<set_cookie>/C<cookies>/C<clear_cookies>/C<save_cookies>/
C<load_cookies>) -- and is the default for C<wait_for>'s and C<pdf>'s own
C<timeout> option. On expiry the operation's callback is resolved with
C<$err eq 'timeout'>. Default C<30>.

=item C<< user_agent => $string >>

Sets the initial User-Agent (equivalent to calling C<set_user_agent> right
after construction).

=item C<< ephemeral => $bool >>

Use an ephemeral (in-memory, non-persistent) network session when true, or
an on-disk/persistent one when false. Default C<1>. Forced to C<0>
automatically when C<cookie_jar> is given -- native cookie persistence
requires a non-ephemeral session (see C<cookie_jar> below).

=item C<< devtools => 1 >>

Enables the C<enable-developer-extras> setting at construction time
(required before the Web Inspector will do anything useful; see
C<show_devtools>).

=item C<< title => $string >>

Sets the native GTK4 window's title.

=item C<< chrome => 1 >>

Build a minimal browser chrome: a GNOME header bar with back, forward and
reload buttons and an address entry, installed as the window title bar.
Intended for visible use on a real display; harmless under xvfb-run. The
reload button turns into a stop button while a page is loading. The address
entry navigates on Enter (https:// is assumed when no scheme is given) and
tracks the current page uri except while it has keyboard focus. The window
title follows the page title. Automation methods keep working unchanged.

=item C<< cookie_jar => $path >>

Configures C<$path> as this instance's native, WebKit-managed persistent
cookie store (forces a non-ephemeral session -- see C<ephemeral> above).
Cookies with a real expiry (a C<max_age> greater than C<0>, or a
C<Set-Cookie: ...; Max-Age=>/C<Expires=> response header) are written to
C<$path> automatically and read back automatically by any later instance
pointed at the same file -- no C<save_cookies>/C<load_cookies> call needed.
SESSION cookies (no expiry) are I<excluded> from this store by design (RFC
6265, same as every real browser); use C<save_cookies>/C<load_cookies> to
snapshot those. See L</"Cookie Management"> and L</"LIMITATIONS">.
Do not point save_cookies/load_cookies at the same file as cookie_jar: the
native store and the JSON snapshot are different formats written by
independent writers, and sharing a path will corrupt the file.

=item C<< jar_format => 'sqlite' | 'text' >>

Storage format for C<cookie_jar>. C<sqlite> (default) is queryable with
C<sqlite3>; C<text> is a human-readable Netscape-format cookie file.
Ignored unless C<cookie_jar> is given.

=item C<< data_dir => $path >>

Points this instance's entire session -- cookies, C<localStorage>,
C<IndexedDB>, the HTTP cache, service-worker state -- at C<$path>, and restores
it whenever an instance is later built with the same C<$path>. Two instances
with different C<data_dir>s share nothing. Forces a non-ephemeral session (see
C<ephemeral> above); C<< data_dir => ..., ephemeral => 1 >> croaks.

C<data_dir> persists what C<cookie_jar> does B<and more>: C<localStorage>,
C<IndexedDB>, the cache and service-worker state, none of which C<cookie_jar>
touches. Cookies persist under the same rule as C<cookie_jar> -- those with a
real expiry, written to a C<< $data_dir/cookies.sqlite >> the same way (see
L</"LIMITATIONS">). Two things are B<never> written to disk: session cookies
(no expiry -- RFC 6265, use C<save_cookies>/C<load_cookies> to snapshot those)
and C<sessionStorage> (WebKit treats it as inherently per-session).

C<data_dir> and C<cookie_jar> compose: C<data_dir> persists everything to its
own locations, and if C<cookie_jar> is also given, cookies additionally go to
that specific queryable C<sqlite> file. A relative C<$path> is resolved against
the current directory at construction time. C<$path> (and any missing parent
directories) is created for you; an empty string, a path that is already a
non-directory file, or a path with no writable ancestor croaks from C<new>
rather than failing later.

Do not point C<save_cookies>/C<load_cookies> at C<data_dir>'s own cookie file
(C<< $path/cookies.sqlite >>), for the same reason as C<cookie_jar>: they are
different formats written by independent writers. And note C<load_cookies>
replaces any cookie with the same name/domain/path -- since a loaded cookie
comes back as a session cookie (no expiry survives a snapshot), loading a
snapshot into a C<data_dir> instance can B<downgrade> an already-persisted
cookie of that identity, dropping it from the store on the next C<quit>.

B<One live instance per C<data_dir> at a time.> WebKit's C<localStorage> and
C<IndexedDB> databases are not built for concurrent writers, so two live
instances pointed at the same C<data_dir> in one process can corrupt them --
the same caution as not sharing a file between C<cookie_jar> and
C<save_cookies>.

=item C<< cache_dir => $path >>

Overrides where C<data_dir>'s disposable cache is written (default:
C<< $data_dir/cache >>). Useful for putting the regenerable cache on C<tmpfs>,
or keeping a backed-up C<data_dir> free of it. A relative C<cache_dir> is
resolved against the current directory (like C<data_dir>), B<not> nested inside
C<data_dir>. Ignored -- and a croak -- unless C<data_dir> is given, since a
cache dir with no data dir would leak cache to WebKit's shared location and
defeat the isolation.

=item C<< proxy => $uri >> or C<< proxy => { default => $uri, ignore => [@hosts] } >>

Equivalent to calling C<set_proxy> right after construction (see
L</"Network">). An invalid proxy URI croaks out of the constructor itself,
same as calling C<set_proxy> directly.

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
are present; check L</fingerprint_available>. Note: if the extension is present
but fails to load inside the web process (an arch/symbol mismatch), the profile's
User-Agent is still applied while the JS-property spoof is not -- an incoherent
state the module cannot detect from the UI process. B<Coverage:> C<navigator>
(platform, vendor, languages, hardwareConcurrency, deviceMemory, maxTouchPoints),
C<screen>, C<devicePixelRatio>, and the WebGL GPU vendor/renderer strings. The
navigator/screen getters are fully native (prototype-installed, enumerable, not
reversible -- indistinguishable from the engine's own).

A B<coherence layer> fills the gaps a bare navigator/screen spoof would leave: a
Chrome profile also gets C<window.chrome> and a working C<navigator.userAgentData>
(brands/platform plus an async C<getHighEntropyValues>); a mobile profile sizes
the window to the profile's screen (so C<window.innerWidth E<lt>= screen.width>),
adds C<ontouchstart>, and overrides the C<pointer>/C<hover>/C<resolution> media
queries. Unlike the native navigator/screen getters, this layer -- and the WebGL
C<getParameter> override -- is installed as JS (a native replacement cannot
delegate the non-spoofed cases: a JSC C function receives no C<this>). The values
are correct and consistent, but their getters/methods show JS source under a
C<Function.prototype.toString.call> (or a getter-C<toString>) check, so a
determined script can still detect the C<userAgentData>/C<matchMedia>/WebGL
wrappers.

WebGL spoofs the full per-profile B<capability set>, not only the UNMASKED
vendor/renderer strings: the numeric parameters (C<MAX_TEXTURE_SIZE> and friends),
the supported-extension list, and C<getShaderPrecisionFormat> all return the
claimed GPU family's values on both WebGL1 and WebGL2, coherent with the renderer
string. The advertised list is authoritative: C<getExtension> returns C<undef> for
anything not on it, the real object when the host GL genuinely has it, and
otherwise a minimal stub (carrying that extension's constants for the commonly
probed ones, an empty object for the rest -- see the B<Ceiling> notes below).
Extension names are
matched case-insensitively, as the spec requires, and an extension's own pnames
(the UNMASKED pair, C<MAX_TEXTURE_MAX_ANISOTROPY_EXT>) are answered only once
C<getExtension> has enabled that extension on the context -- before that they
report C<null> and raise C<INVALID_ENUM>, exactly as a real context does.

The capability tables are a curated subset covering the parameters fingerprinters
actually read; a pname not in the table falls through to the real host value.

The B<DOM interface set> is aligned per profile too: a Chrome profile exposes
C<navigator.connection>, C<usb>, C<bluetooth>, C<getBattery>, C<scheduling> and
C<RTCPeerConnection> (the Android profile correctly omits C<hid>/C<serial>); a
Safari profile exposes only C<storage> and C<RTCPeerConnection>. Every stub is
installed only when the build lacks the real API, so a WebKitGTK that ships one
keeps it.

B<Ceiling:> the spoof is thorough but not perfect, and these residuals remain.
B<Workers are not covered at all.> The extension hooks
C<window-object-cleared>, which fires only for window globals, so a
C<Worker>/C<SharedWorker>/C<ServiceWorker> global keeps the real
C<navigator.platform>, C<languages> and hardware values and gets no readback
noise -- while its C<userAgent> B<is> spoofed (that comes from the browser
settings, not this extension). Reading C<navigator.platform> on both sides of a
C<postMessage>, or hashing an C<OffscreenCanvas> inside a worker, defeats the
whole layer; treat a page that uses workers as unprotected.
The native navigator/screen getters are also still identifiable by the source
B<text> C<Function.prototype.toString> reports for them: a real accessor renders
as C<function E<lt>propE<gt>() { [native code] }> while these render as
C<function get() { [native code] }>. The name and C<[native code]> marker are
correct, but the embedded identifier is not, and it cannot be corrected without
replacing the getter with JavaScript -- which costs far more than it saves.
The JS-installed layers (C<userAgentData>/C<matchMedia>/WebGL/readback/feature
stubs) show JS source under C<Function.prototype.toString.call> B<and> under a
plain C<toString()>, so a determined script can still detect them. They
deliberately carry no own C<toString> mask: such a mask defeats only the plain
check -- C<Function.prototype.toString.call> bypasses an own property and reveals
the wrapper anyway -- while leaving an artifact no real function has, which
C<Object.keys> enumerates across the whole JS layer with no false positives.
Trading a weak defence for a precise tell is a bad exchange, so the wrappers are
left honest. Readback
noise, when C<seed> is set, is content-independent, so a script that renders a
known image and reads it back can recover and undo it. It is also applied at
B<read> time rather than stored, so it does not survive a round trip: writing
back what was just read (C<putImageData>), or encoding and re-decoding through
C<toDataURL>/C<toBlob>, yields the un-noised pixels, and comparing the two
detects that noise is active without knowing the content. B<Without> C<seed>,
canvas/AudioContext/WebGL-pixel readback reflects the real host output (often
software/llvmpipe) and is not disguised at all. The C<matchMedia> override
answers JS queries (including compound and comma-separated ones), but B<CSS>
C<@media> rules are evaluated by the engine and still reflect the real device, so
a page that compares C<getComputedStyle> against C<matchMedia> sees a
contradiction on a mobile or hi-DPI profile. The WebGL capability values are
the canonical set for each GPU family, so a fingerprinter with a per-driver
database could still find a mismatch, and any pname outside the curated tables
still reports the host's real value. Stubbed extensions and C<RTCPeerConnection>
have no real runtime behaviour (no ICE, no devices), so a script that exercises
their functionality -- rather than merely detecting their presence -- can spot
the stub; an advertised extension the host GL lacks is an object with the right
constants but no working methods. C<navigator.languages> is a real array with
the profile's tags, but B<not> a C<FrozenArray>: a real browser caches one
frozen array and returns it every time, so C<navigator.languages ===
navigator.languages> and C<Object.isFrozen(navigator.languages)> are both true
there and false here. Closing that was built and then reverted -- caching one
frozen array per JS context works, but a C<JSCValue> holds a strong reference to
its C<JSCContext>, making cache/array/context a refcount cycle whose destroy
notify never runs, which leaks an entire JS context per navigation; and
anchoring the array on the JavaScript side instead would turn C<languages> into
a B<data> property where every real browser has an accessor, a louder tell than
the one being fixed. C<navigator.plugins> and
C<navigator.mimeTypes> are B<not> spoofed at all: WebKitGTK reports the five
PDF-viewer entries the HTML specification hardcodes for any browser with
C<navigator.pdfViewerEnabled> true, which is what desktop Chrome, desktop
Safari and iOS Safari all report -- but Chrome on B<Android> has no inline PDF
viewer and reports an empty list, so C<pixel-chrome> is likely wrong here.
That one is left alone deliberately rather than guessed at: Chrome was
reportedly gaining an Android PDF viewer around the 131 timeframe, so the
correct value for that exact version is not settled, and a confidently wrong
value is worse than a documented gap. Encoding a large canvas through C<toDataURL>
is markedly slower with C<seed> set, which is itself weakly timeable. And this is the JS layer only -- the
network-layer fingerprint (TLS JA3/JA4, HTTP/2) is untouched unless you also
enable C<network_fingerprint> (below). A self-consistent B<custom> profile is
your responsibility.

=item C<< seed => 12345 >>

Enable seeded B<readback noise> on canvas, C<AudioContext>, and WebGL pixel
readback (opt-in; requires C<fingerprint>). The seed is a non-negative integer.
The perturbation is a content-independent function of the seed and the readback
position -- absolute canvas or drawing-buffer coordinates for pixels, the frame
index for audio samples -- so the same sample re-read through any API, rectangle
or offset gives the same value. A fully opaque pixel gets an LSB flip. A
partially transparent one is moved to an B<adjacent reachable value> instead:
C<getImageData> returns un-premultiplied bytes, so only a lattice of values is
producible at a given alpha and an LSB flip would land off it (the step is
therefore larger than one LSB at low alpha). WebGL C<readPixels> returns the
premultiplied value directly, so there the step is applied to that value. Only
engine-B<rendered> audio buffers are touched, never one the page authored. The
seed is reduced modulo 2**32, so seeds congruent mod 2**32 give identical noise.
That makes the hardware-readback hash B<stable> within a session, yet
different from the automation host's real output (hiding llvmpipe/software GL)
and different across seeds -- so the same profile can present distinct machines.
Wrapped: C<getImageData>, C<toDataURL>/C<toBlob> (via an offscreen copy, so the
encoded image carries the noise and WebGL-backed canvases are covered too),
C<AudioBuffer.getChannelData>/C<copyFromChannel>, the C<AnalyserNode> frequency and time-domain
readers, and C<readPixels>. Without C<seed>, none of this is installed and
readback behaves exactly as before. See the B<Ceiling> notes under
C<fingerprint> above for the residuals.

=item C<< network_fingerprint => 1 >> or C<< network_fingerprint => 'chrome124' >>

Also match the B<connection> fingerprint (TLS JA3/JA4 + HTTP/2 Akamai) to the
C<fingerprint> profile, so the origin sees one coherent device at the network
layer too. Requires C<fingerprint>. It spins an in-process L<Proxy::Impersonate>
on this instance's EV loop and routes the browser through it: the proxy
terminates WebKit's TLS locally and re-originates each request as the matching
real browser via C<libcurl-impersonate>. The curl target is derived from the
profile (C<windows-chrome> -> C<chrome131>, C<macos-safari> -> C<safari18_0>,
C<iphone-safari> -> C<safari18_0_ios>, C<pixel-chrome> -> C<chrome131_android>);
pass a string to override it.

The profile's identity headers (User-Agent + C<Sec-CH-UA>) are forced over the
curl target's defaults, so even a Windows profile is coherent on the (macOS-built)
C<chrome131> target -- Windows and macOS Chrome share the same TLS/HTTP2, so only
the header values differ. WebKit is told to accept the proxy's self-signed cert
(C<set_tls_errors_policy('ignore')>); this is safe because the browser-to-proxy
hop is localhost and the proxy re-verifies the real origin upstream. WebKitGTK 6.0
exposes no custom-CA path (a spike confirmed it honors neither C<SSL_CERT_FILE>
nor a settable C<GTlsDatabase>), which is why the C<IGNORE> policy is used.

Requires the optional L<Proxy::Impersonate> toolchain (which builds
C<curl-impersonate> via L<Alien::curlimpersonate>); croaks if it is unavailable.
Mutually exclusive with an explicit C<proxy>. Out of scope: WebSockets, HTTP/3.
See L</network_fingerprint> and L</proxy_port>.

=item C<on_error>, C<on_load>, C<on_navigate>, C<on_close>, C<on_console>, C<on_dialog>, C<on_policy>

Event callbacks -- see L</"EVENTS">.

=back

=head1 METHODS

=head2 Navigation

Load pages and read basic document state.

=head2 go

    $b->go($uri, sub { my ($result, $err) = @_; ... });

Loads C<$uri>. On success C<$result> is true; on failure (or timeout)
C<$err> is set. If a previous navigation on this instance was still
in-flight, its callback is immediately invoked with C<$err eq
'superseded'>. The callback fires shortly (~10ms) after WebKit's own
C<load-changed:finished> signal, to give the web process time to propagate
C<title>/C<uri> to the UI process; C<on_load> (if configured) fires right
after it. Returns C<$b> (chainable).

=head2 load_html

    $b->load_html($html, sub { my ($result, $err) = @_; ... });

Loads a literal HTML string as the document, with the same completion
semantics as C<go> (no URI, so it does not count toward C<save_cookies>'s
default URI list). Returns C<$b>.

=head2 Navigation history

    $b->back(sub { my ($ok, $err) = @_; ... });     # optional callback
    $b->forward($cb);
    $b->reload($cb);
    $b->stop;
    $b->can_go_back;      # 1 or 0
    $b->can_go_forward;   # 1 or 0

back, forward and reload behave like go: the optional trailing callback is
invoked as ($ok, $err) when the resulting navigation finishes (or fails or
times out). Calling back/forward when the history has no entry in that
direction invokes the callback with the error 'cannot go back' /
'cannot go forward'. stop aborts the current load and returns the browser
object; it takes no callback. can_go_back / can_go_forward are synchronous
and return 1 or 0.

Note: load_html does not add entries to the back-forward list; only real
navigations (go, links, redirects) do.

=head2 uri

    my $uri = $b->uri;

Current document URI. Synchronous.

=head2 title

    my $title = $b->title;

Current document title. Synchronous.

=head2 is_loading

    my $bool = $b->is_loading;

True while a navigation is in progress. Synchronous.

=head2 html

    $b->html(sub { my ($html, $err) = @_; ... });

Fetches the full serialized document markup as C<$html>
(C<document.documentElement.outerHTML>), or C<undef> if there is no document
element. Asynchronous, like C<script>.

=head2 JavaScript Execution

Run arbitrary JavaScript in the page and get JSON-marshalled results back.
Strings crossing this bridge in either direction are full Unicode CHARACTER
data, not bytes -- a Perl string with non-ASCII characters (e.g. built with
C<\x{e9}> escapes, or read from a C<:utf8> filehandle) passed via
C<script_async>'s C<\%args> or an element's C<type>/C<send_keys> arrives in
JS as the same text, and a JS string returned from C<script> or read via an
element accessor (C<text>, C<value>, ...) comes back as the same Perl
character string. Do not C<utf8::encode> a string before handing it to any
of these; that would turn it into a byte string and produce mojibake on the
JS side instead.

=head2 script

    $b->script($js, sub { my ($result, $err) = @_; ... });

Runs C<$js> as the body of an C<async> function (so top-level C<await>
works) and JSON-marshals its C<return> value back as C<$result> (a plain
scalar, arrayref, or hashref; JS C<undefined> or no C<return> becomes Perl
C<undef>). A thrown JS exception becomes C<$err>. Returns C<$b>.

=head2 script_async

    $b->script_async($body, \%args, sub { my ($result, $err) = @_; ... });

Same as C<script>, but C<\%args> is JSON-encoded and made available inside
C<$body> as the const C<A> (e.g. C<A.foo>). This is the primitive
C<find>/C<find_all>/element methods are built on. Returns C<$b>.

=head2 Elements

Locate DOM elements and hand back L<EV::WebKit::Element> handles.

=head2 find

    $b->find($selector, sub { my ($el, $err) = @_; ... });

Runs C<document.querySelector($selector)>. C<$el> is an
L<EV::WebKit::Element> on a match, or C<undef> if nothing matched --
not-found is not an error (C<$err> is C<undef> in that case too).

=head2 find_all

    $b->find_all($selector, sub { my ($els, $err) = @_; ... });

Like C<find>, but C<querySelectorAll>: C<$els> is a (possibly empty)
arrayref of L<EV::WebKit::Element>.

=head2 wait_for

    $b->wait_for($selector, %opts, sub { my ($el, $err) = @_; ... });

Polls C<find($selector)> until it matches (and, if C<visible> is set, until
it is also visible), or until C<timeout> elapses. C<%opts>:

=over 4

=item C<< timeout => $seconds >>

Default: this instance's own C<timeout> (see C<new>).

=item C<< interval => $seconds >>

Poll interval. Default C<0.05>. A non-positive value (C<0> or negative) is
meaningless for a poll and snaps to the default instead, so it can't stall
the deadline check and busy-loop the EV loop.

=item C<< visible => $bool >>

Also wait for the matched element's C<is_visible> to become true before
resolving.

=back

On timeout, C<$el> is C<undef> and C<$err eq 'timeout'>. Returns C<$b>.

=head2 Screenshots and PDF

Capture the rendered page.

=head2 screenshot

    $b->screenshot($path, sub { my ($result, $err) = @_; ... });
    $b->screenshot(\%opts, sub { my ($result, $err) = @_; ... });
    $b->screenshot($path, %opts, sub { my ($result, $err) = @_; ... });

Captures a PNG of the current page. With a plain C<$path>, the PNG is
written there and C<$result> is C<$path>. The C<\%opts>-only form has no
C<$path>, so it requires C<< bytes => 1 >> (below) -- calling it with
neither a path nor C<bytes> errors with C<'screenshot path required (or
bytes => 1)'>. C<%opts>:

=over 4

=item C<< full => $bool >>

Capture the full scrollable document instead of just the visible viewport.

=item C<< transparent => $bool >>

Transparent background instead of opaque white.

=item C<< bytes => $bool >>

Return the raw PNG byte string as C<$result> instead of writing a file --
no file is written even if C<$path> was also given.

=back

Returns C<$b>.

=head2 pdf

    $b->pdf($path, %opts, sub { my ($result, $err) = @_; ... });

Renders the current page to a PDF file at C<$path> via
C<WebKit::PrintOperation>. C<%opts>: C<paper> (GTK paper-size name, default
C<iso_a4>), C<margin> (mm, all four sides, default C<0>), C<resolution>
(dpi, default C<300>), C<timeout> (seconds, overriding the instance default
for this call). C<$result> is C<$path> on success. Returns C<$b>.

C<resolution> is passed through to the GTK print settings, but do not expect
it to change anything: WebKitGTK's print-to-PDF path does not consult it
(72, 300 and 1200 dpi produce byte-identical files), because the output is
vector rather than rasterised. It is accepted for completeness.
C<pdf($path)> errors with C<'pdf: no page loaded'> if called before the view
has navigated anywhere.

Calls are B<serialized>: two C<WebKit::PrintOperation>s running on one view
at once race at the engine level (and crash it), so C<pdf()> queues each
request and runs exactly one at a time. You may fire several C<pdf()> calls
back-to-back; each resolves its own callback in turn, and their outcomes are
deterministic.

The C<timeout> bounds how long B<your callback> waits, counted from the
C<pdf()> call itself -- not from the moment the job reaches the head of the
queue. So it covers the time spent queued behind other prints as well as the
printing, and a call made while an earlier print is stuck still resolves on
its own deadline with C<$err eq 'timeout'>.

What that error means depends on whether the print had started:

=over 4

=item *

B<Still queued> at the deadline: it never runs. Nothing was printed and no
file is written -- the job is dropped when its turn comes.

=item *

B<Already printing> at the deadline: the print is B<not> aborted.
WebKit-6.0's C<WebKit::PrintOperation> has no cancel method at all, so
nothing can stop one once it is under way. Treat C<'timeout'> here as "took
too long, outcome unknown", not "did not happen": the operation may still
complete afterwards and write its file to C<$path>.

=back

For that second case the queue does B<not> advance past a timed-out
operation until the engine actually finishes it (starting the next print
alongside a live one would crash the engine). A subsequent C<pdf()> to the
same path is therefore safely queued behind it, never racing its write.

=head2 Settings

User-Agent and arbitrary WebKitSettings properties.

=head2 set_user_agent

    $b->set_user_agent($ua_string);

Sets the User-Agent. Synchronous, returns C<$b>.

=head2 user_agent

    my $ua = $b->user_agent;

Current User-Agent. Synchronous.

=head2 settings

    $b->settings({ enable_javascript => 0, ... });

Sets arbitrary C<WebKit::Settings> GObject properties: each key has its
underscores turned into hyphens (C<enable_javascript> becomes the
C<enable-javascript> property). Synchronous, returns C<$b>. A reference value,
or a key naming a property that does not exist, croaks. Not transactional: a
croak on an unknown property name may leave earlier keys in the same call
already applied (reference values are all rejected up front, so a typed-value
mistake is caught before anything is set).

=head2 show_devtools

    $b->show_devtools;

Enables C<enable-developer-extras> (if not already) and opens the Web
Inspector window. Synchronous, returns C<$b>.

=head2 Network

Proxy configuration and custom URI-scheme handlers.

=head2 set_proxy

    $b->set_proxy($uri);
    $b->set_proxy({ default => $uri, ignore => [@hosts] });
    $b->set_proxy(undef);          # or 'no-proxy'

Configures (or clears) this instance's proxy. Synchronous, no callback.
Returns C<$b>. Equivalent to the constructor's C<proxy> option.

Only C<undef> and the literal string C<'no-proxy'> clear the proxy; any other
value is treated as a custom proxy to set, and its default URI is validated
up front (must look like C<scheme://authority>). WebKit itself only prints a
C-level CRITICAL and silently falls back to a direct connection for a
malformed proxy URI -- not a Perl exception C<eval> could catch -- so an
invalid or empty default URI (including a C<< { default => ... } >> hash
with no C<default>) makes this method C<Carp::croak> instead, fail-fast
rather than silently discarding the proxy.

=head2 mock_scheme

    $b->mock_scheme($scheme, sub { my ($uri) = @_; return ($body, $content_type) });

Registers a custom URI-scheme handler on this instance's private (not the
shared default) C<WebKit::WebContext>. The producer callback is invoked
once per request to C<$scheme>; C<$content_type> defaults to C<text/html>
if omitted. Must be registered before the first navigation to C<$scheme>.
Pass C<$body> as a character string (e.g. plain ASCII, or containing
C<\x{e9}>-style non-ASCII text); it is served as its UTF-8 encoding. Do not
pass pre-encoded octets -- a byte string that already holds UTF-8 bytes
would be encoded a second time and corrupt the output. As with any HTTP
response, WebKit's HTML parser still needs to be told the encoding: include
C<charset=utf-8> in C<$content_type> (or a C<< <meta charset="utf-8"> >> tag
in the body itself) whenever it isn't plain ASCII, the same as a real web
server would. Synchronous, returns C<$b>.

If the producer dies, the request fails cleanly instead of crashing the
process: the pending navigation's callback receives a defined C<$err>
describing the failure. C<$err>'s exact wording is this module's own, not a
native WebKit network error (C<finish_error>, WebKit's normal way to report
this, is unusable with the currently supported C<Glib::Object::Introspection>
-- see the source comment on C<mock_scheme>'s C<register_uri_scheme>
callback for why).

=head2 Cookie Management

C<set_cookie>/C<cookies>/C<clear_cookies> operate on this instance's live
session. C<cookie_jar> (see C<new>) gives native persistent storage for
non-session cookies automatically; C<save_cookies>/C<load_cookies> below
are an explicit, opt-in JSON snapshot mechanism -- see L</"LIMITATIONS">.

=head2 set_cookie

    $b->set_cookie(\%spec, sub { my ($ok, $err) = @_; ... });

C<%spec>: C<name>, C<value>, C<domain>, C<path> (default C</>), C<max_age>
(seconds, default C<-1> = session cookie), C<secure> (bool), C<http_only>
(bool). C<$ok> is true on success. Errors with
C<"set_cookie: missing '<key>'"> if C<name>/C<value>/C<domain> is missing
from C<%spec>. Returns C<$b>.

=head2 cookies

    $b->cookies($uri, sub { my ($list, $err) = @_; ... });

C<$list> is an arrayref of C<{ name, value, domain, path, secure,
http_only }> hashrefs visible to C<$uri> (C<secure>/C<http_only> are 1 or
0). Errors with C<'cookies: uri required'> if C<$uri> is missing/empty.
Returns C<$b>.

=head2 clear_cookies

    $b->clear_cookies(sub { my ($ok, $err) = @_; ... });

Clears every cookie in this instance's session (not scoped to a single
domain/URI). Returns C<$b>.

=head2 save_cookies

    $b->save_cookies($file, sub { my ($count, $err) = @_; ... });
    $b->save_cookies($file, \@uris, sub { my ($count, $err) = @_; ... });

Writes this instance's cookies to C<$file> as a JSON snapshot, enumerated
per-URI (via the same path as C<cookies>) over C<\@uris>, or, if omitted,
every URI this instance has C<go>ne to. C<$count> is the number of
(deduplicated) cookies written. C<$file> is written as UTF-8 text, so
cookie values containing non-ASCII characters round-trip correctly. This
is an explicit, opt-in mechanism, distinct from C<cookie_jar>'s native
persistence (see C<new>) -- it is the only way to capture SESSION cookies,
which native persistence excludes by design. Errors with C<'snapshot file
required'> if C<$file> is missing/empty, C<'no URIs to save ...'> if there
is no URI list (navigate first, or pass C<\@uris> explicitly), or a
filesystem error. Cookie I<expiry> is deliberately not part of the saved
data -- see L</"LIMITATIONS">. Returns C<$b>.

=head2 load_cookies

    $b->load_cookies($file, sub { my ($loaded, $err) = @_; ... });

Reads C<$file> (as written by C<save_cookies>, UTF-8 text) and replays each
row through C<set_cookie>. C<$loaded> is the number successfully
re-applied. If the file doesn't exist, or exists but isn't valid JSON, this
is not an error -- C<$loaded> is simply C<0>. Individual rows are treated
the same way: a row that isn't a hashref, or is missing C<name>/C<value>/
C<domain>, is silently skipped rather than failing the whole load --
C<$loaded> only counts rows that were actually well-formed. Every cookie in a
snapshot this module wrote is loaded back as a session cookie, even if it had
an expiry when saved -- C<save_cookies> cannot read expiries back out of
WebKit, so it never records one (see L</"LIMITATIONS">). A hand-written
snapshot B<may> carry an C<expires> key (epoch seconds), and that one is
honoured: the cookie is restored with its remaining lifetime and, in a
C<cookie_jar> session, persists across restarts. Errors with
C<'snapshot file required'> if C<$file> is missing/empty. Returns C<$b>.

=head2 User content injection

Inject your own JavaScript and CSS into the pages this instance loads.

=head2 add_user_script

    my $h = $b->add_user_script($js, %opts);

Inject C<$js> into every page this instance loads, from the B<next> navigation
onward (WebKit injects user content at load time, so it does not affect the page
already showing). Returns an L</EV::WebKit::UserContent> handle whose C<remove>
takes just this script back out.

Options:

=over 4

=item at => 'end' (default) | 'start'

When the script runs relative to the page's own scripts. C<start> runs before
any page script -- but the DOM does not exist yet (C<document.body> is C<undef>),
so a script that touches the DOM should use C<end>.

=item world => 'main' (default) | 'isolated'

C<main> shares the page's JavaScript globals (what the page's own code sees).
C<isolated> gets a private global scope the page cannot read or corrupt, while
still sharing the one DOM -- use it to observe or rewrite a page without the page
noticing your variables.

=item frames => 'all' (default) | 'top'

Inject into all frames, or only the top-level document.

=item allow => [ globs ], deny => [ globs ]

Optional URL-pattern allow/deny lists (WebKit C<UserContentURLPattern> syntax). A
pattern is C<scheme://host/path> with C<*> wildcards and B<must> include a path
component (C<'https://*.example.com/*'>, not C<'https://*.example.com'>). With
C<allow>, the script runs only on matching URLs; C<deny> excludes matching URLs;
C<deny> wins over C<allow>. Each entry must be a non-empty string (undef, empty,
and non-string entries croak); a syntactically malformed pattern is not caught
here and simply never matches. Omit a list to match every URL -- an empty list
(C<< allow => [] >>) is rejected rather than silently meaning match-all.

=back

C<$js> should be a decoded Perl character string (not raw bytes): it is handed to
WebKit as UTF-8, so a byte string with high bytes would be re-encoded (mojibake).

Croaks on a source that is undef, a reference, or contains a NUL byte (which would
silently truncate the injected content); on an invalid option value or an unknown
option key; and -- unlike the quiet-no-op mutators (see L</Lifecycle>) -- on a
call after the browser is closed (there is no handle it could meaningfully return).

=head2 add_user_style

    my $h = $b->add_user_style($css, %opts);

Like L</add_user_script> but injects a CSS stylesheet. Accepts C<frames>,
C<allow>, and C<deny> as above (no C<world> -- a world does not change how a
stylesheet affects the document, so it is not surfaced), plus:

=over 4

=item level => 'author' (default) | 'user'

C<author> mixes with the page's own author styles. C<user> is a user-agent-level
override that beats page CSS -- use it to reliably hide elements
(C<< 'div.ad { display:none !important }' >>).

=back

Returns an L</EV::WebKit::UserContent> handle.

=head2 remove_all_user_scripts

    $b->remove_all_user_scripts;

Remove every script added with L</add_user_script>. Does not touch the module's
own internal injection (the element registry that L</find> and L</html> rely on).
Chainable.

=head2 remove_all_user_styles

    $b->remove_all_user_styles;

Remove every stylesheet added with L</add_user_style>. Chainable.

=head2 Fingerprinting

See the C<fingerprint> constructor option above for the device-profile spoofing
this exposes.

=head3 fingerprint

    my $profile = $b->fingerprint;   # resolved hashref, or undef

The resolved fingerprint profile for this instance (read-only), or C<undef>.

=head3 network_fingerprint

    my $target = $b->network_fingerprint;   # e.g. 'chrome131', or undef

The active curl-impersonate target when C<network_fingerprint> is enabled, else
C<undef>. See the C<network_fingerprint> constructor option above.

=head3 proxy_port

    my $port = $b->proxy_port;   # or undef

The localhost port of the in-process re-origination proxy when
C<network_fingerprint> is enabled, else C<undef>.

=head3 fingerprint_profiles

    my @names = EV::WebKit->fingerprint_profiles;

The names of the shipped presets.

=head3 fingerprint_available

    EV::WebKit::fingerprint_available() or warn "no fingerprint support";

Whether the web-process extension was built at install.

=head2 Lifecycle

Tear the instance down.

=head2 quit

    $b->quit;

Tears down this instance: resolves every in-flight callback -- including a
still-pending navigation -- exactly once with C<$err eq 'browser closed'>,
destroys the native GTK window (the X display itself is left alone -- see
L</"LIMITATIONS">), and drops the view/session/etc. Idempotent -- safe to
call more than once, and run automatically from C<DESTROY>: an instance holds
only weak references to itself from its native signal handlers, so a plain
C<undef $b> or a scope exit collects it and tears it down (calling C<quit>)
without an explicit call. Calling C<quit> yourself is still useful to release
the native window/session B<promptly> and deterministically rather than
whenever the instance is next collected. After
C<quit>, any method that would otherwise run JavaScript (C<script>,
C<script_async>, C<find>, C<find_all>, C<html>, and all L<EV::WebKit::Element>
methods) resolves immediately with C<$err eq 'browser closed'>.
Synchronous accessors (C<uri>, C<title>, C<is_loading>, C<user_agent>)
instead degrade quietly after C<quit>, returning C<undef> (C<0> for
C<is_loading>), and synchronous mutators (C<set_user_agent>, C<settings>,
C<set_proxy>, C<mock_scheme>, C<show_devtools>) become no-ops that just
return C<$b>.

An operation already in flight at the moment C<quit> is called is resolved
deterministically, exactly once, rather than left dangling. Every pending
C<script>/C<script_async>/C<find>/C<find_all>/C<html>/C<screenshot>/C<pdf>
call, cookie call, outstanding C<wait_for>, and navigation resolves with
C<$err eq 'browser closed'>. Any call made I<after> C<quit> has returned
likewise resolves immediately with C<'browser closed'>.

C<quit> never throws. It has to run your callbacks in order to resolve them,
and one of them dying must not abort the teardown -- that would drop every
callback still queued behind it and leak the window, view and session for the
life of the process (nothing could retry: C<quit> is already marked done). An
exception from a callback is caught and reported with C<warn>.

Calling C<quit> from inside an event handler (C<on_dialog>, C<on_policy>,
C<on_console>, or a C<mock_scheme> producer) is safe. Those run inside
WebKit's own dispatch frame, so C<quit> defers the teardown -- and the
callbacks it resolves -- to the next clean tick of the loop rather than
running them nested inside that frame, where an C<EV::break> from one of them
would wedge the loop (see L</on_dialog>).

C<'browser closed'> reports how the B<callback> was resolved, not whether
the operation's effect took place. A cookie B<mutation> already in flight
when C<quit> lands -- C<set_cookie>, C<save_cookies> (which may still write
its file), or C<clear_cookies> -- can still complete its native effect even
though its callback reports C<'browser closed'>, because cancelling it
mid-flight would risk a use-after-free during teardown. Treat
C<'browser closed'> on an in-flight mutation as "outcome unknown", not
"did not happen". (This does not apply to calls made I<after> C<quit>, which
never start any native work.)

=head2 Handler accessors

    my $cb = $b->on_console;          # get
    $b->on_console(sub { ... });      # set, returns $b
    $b->on_console(undef);            # clear

Every C<on_*> handler (C<on_load>, C<on_error>, C<on_close>, C<on_navigate>,
C<on_console>, C<on_dialog>, C<on_policy>) has a get/set accessor, so code that
did not construct the browser can still observe it -- and can B<chain> an
existing handler rather than clobbering it:

    my $prev = $b->on_console;
    $b->on_console(sub { $prev->(@_) if $prev; ...also mine... });

Croaks on a non-coderef. Enabling C<on_console> after a page has loaded takes
effect from the B<next> navigation: the console proxy is a user script, and
those are injected at document start.

=head1 EVENTS

Optional callbacks passed to C<new>:

=over 4

=item C<< on_error => sub { my ($err) = @_ } >>

Called for a navigation failure that has no C<go>/C<load_html> callback
waiting for it (e.g. a stray C<load-failed> signal). Ordinary navigation
failures go to that call's own callback instead, not here.

=item C<< on_load => sub { } >>

Called with no arguments when a navigation started through this API
(C<go>, C<load_html>, C<back>, C<forward>, or C<reload>) finishes
successfully, right after that navigation's own callback (if any). It does
NOT fire for user- or page-JS-initiated navigations (e.g. clicking a link,
or a script-driven redirect) -- only for navigations this instance itself
started through one of the methods above.

=item C<< on_console => sub { my ($text) = @_ } >>

Called for each C<console.log>/C<warn>/C<error>/C<info> from page
JavaScript. C<$text> is a single string of the form C<"$level: $args">,
e.g. C<"log: hi">. Implemented by monkey-patching C<console> via an
injected user script plus a script-message handler, not WebKit's native
console-message signal.

=item C<< on_dialog => sub { my ($dialog) = @_ } >>

Called for C<window.alert>/C<confirm>/C<prompt> and the beforeunload
confirmation. C<$dialog> is an L</"EV::WebKit::Dialog"> object, valid only
for the duration of this call. If C<on_dialog> is not given, every dialog
is auto-dismissed so the page is never blocked.

=item C<< on_navigate => sub { my ($uri) = @_ } >>

Called for B<every> navigation that commits, whoever started it -- including one
the page starts itself, which is what a human clicking a link in a visible
window looks like.

C<on_load> is not that. It fires only for a navigation this API started, so
without C<on_navigate> a browser you are also using by hand can change page and
tell you nothing at all. An API navigation fires both.

Delivered on a clean EV tick, so C<EV::break> is safe from it.

=item C<< on_close => sub { } >>

Called when the B<user> closes the window (the titlebar close button, alt-F4,
the window manager) -- not when you call C<quit> yourself. Only reachable in
the visible mode (a real C<$DISPLAY>, usually with C<< chrome => 1 >>).

The instance is torn down first: every in-flight callback resolves with
C<'browser closed'>, the native window is destroyed, and only then is
C<on_close> called. So by the time it runs, C<$b> is already closed -- it is a
notification, not a veto.

It does B<not> stop your C<EV::run> -- nothing in this module ever does; you
own the loop. For a browser window whose closing should end the program, that
is the whole handler:

    my $b = EV::WebKit->new(chrome => 1, on_close => sub { EV::break });
    ...
    EV::run;   # returns when the window is closed

Unlike C<on_console>/C<on_dialog>/C<on_policy>, C<on_close> is delivered on a
clean EV tick, so calling C<EV::break> directly from it is safe.

=item C<< on_policy => sub { my ($info) = @_ } >>

Called for each navigation/new-window/response decision WebKit asks about.
C<$info> is an L</"EV::WebKit::Policy"> object, valid only for the duration
of this call. If C<on_policy> is not given, WebKit's own default (allow)
applies; if the handler doesn't call C<allow>/C<block>, allow happens
automatically once it returns.

If the handler B<dies> before deciding, the navigation is B<blocked> and the
exception reported with C<warn>. This handler is a gate, so it fails closed:
a page that could provoke a die (a URI that breaks the handler's own parsing,
say) would otherwise walk straight through it, since an exception escaping
the handler leaves WebKit to apply its own default -- allow. A handler that
already called C<allow> or C<block> keeps that decision even if it then dies.

=back

=head1 EV::WebKit::Dialog

Passed to C<on_dialog>. Valid only for the duration of that call.

=over 4

=item C<type>

Nick string: C<alert>, C<confirm>, C<prompt>, or C<before-unload-confirm>.

=item C<message>

The dialog's message text.

=item C<accept($text)>

Accept the dialog. For C<prompt>, C<$text> (if defined) becomes the entered
value; for C<confirm>/C<before-unload-confirm>, marks it confirmed;
C<alert> has nothing to set and this just acknowledges it.

=item C<dismiss>

Cancel the dialog (C<confirm>/C<before-unload-confirm> resolve false;
C<alert>/C<prompt> just close).

=back

=head1 EV::WebKit::Policy

Passed to C<on_policy>. Valid only for the duration of that call.

=over 4

=item C<uri>

The request URI for this decision (best-effort; may be C<undef>).

=item C<type>

Nick string: C<navigation-action>, C<new-window-action>, or C<response>.

=item C<allow>

Let the navigation/response proceed.

=item C<block>

Cancel the navigation/response.

=back

=head1 EV::WebKit::UserContent

The handle returned by L</add_user_script> and L</add_user_style>.

=head2 remove

    $h->remove;

Remove just this injected script or stylesheet. Takes effect from the next
navigation. Idempotent and safe: calling it twice, or after the browser has been
closed or collected, is a harmless no-op.

=head1 LIMITATIONS

=over 4

=item Bring-your-own-display

EV::WebKit never spawns or kills an X server. Run under C<xvfb-run -a
your-script.pl> for headless use, or export a real C<$DISPLAY> for a
visible, fully-interactive GTK4 window -- the C<display> constructor option
only sets C<$ENV{DISPLAY}> before GTK initializes, it does not start Xvfb.

=item Cookie persistence

C<cookie_jar> gives WebKit-native persistent cookie storage: cookies with a
real expiry round-trip correctly (expiry included) across instances and
processes. SESSION cookies (no expiry) are permanently excluded from that
store by design (RFC 6265) -- C<save_cookies>/C<load_cookies> are the only
way to snapshot/restore those (or any cookie; snapshots lose expiry, so
every cookie loaded back from one becomes a session cookie regardless of
what it was when saved). C<clear_cookies> clears the whole session, not a
single domain/URI. WebKitGTK's own bulk "all cookies" enumeration
(C<get_all_cookies>) is avoided entirely: a real memory-safety bug was
independently confirmed under valgrind when such a call is left in-flight
at teardown, so this module never calls it, using per-URI C<get_cookies>
throughout instead.

=item GDK backend

C<GDK_BACKEND> is forced to C<x11> (unless already set) since this module
targets X11/Xvfb; it is not tested against a Wayland-native GDK backend.

=item Single EV loop

Native EV watchers, the GLib main context (bridged in by L<EV::Glib>), and
WebKitGTK's own IPC to its web/network processes all share one C<EV::run>.
EV::WebKit defers its own internal callback delivery by one clean tick so
that user code calling C<EV::break> from inside any EV::WebKit callback is
always safe.

=item Overlapping navigation identity

Navigation callbacks are matched to the navigation that requested them
(rather than to whatever navigation merely happens to be pending when a
completion signal arrives) via a generation counter, plus checks on an
incoming C<load-failed> signal: a tracked target URI (C<go> only, kept in
step with server-side redirects and WebKit's own URI normalization), a
started-since check that treats a failure as stray whenever the current
pending navigation has not yet seen its own C<load-changed>
C<started>/C<committed> (WebKit always starts a load before it can fail
it, so a failure that arrives first can only belong to whatever navigation
this one just superseded), and a superseded-uri check (below) for a stray
that arrives after the current pending has already started, which the
started-since check alone can then no longer catch. Together these are
confirmed live to prevent a superseded navigation's own late cancellation
signal from mis-resolving a different, still-pending navigation's
callback: for C<go>-vs-C<go> (all checks apply), both when a
C<mock_scheme> producer reentrantly calls C<go> and for plain
back-to-back C<go> calls a fraction of a millisecond apart; and for
C<back>/C<reload> superseding an in-flight C<go> (the started-since and
superseded-uri checks -- these have no predictable target URI to compare
against, and neither do C<forward> or C<load_html>, which rely on the
same checks by the same reasoning though their own overlap scenarios have
not been separately exercised live). The one remaining theoretical gap: a
navigation with no tracked target that genuinely fails before its own
C<started> fires, for a uri that was never superseded, cannot be told
apart from a stray by these checks alone. This has not been reproduced
live and is not believed reachable in practice -- C<back>/C<forward> only
proceed past C<can_go_back>/C<can_go_forward>, and C<load_html> always
reaches C<started> for any markup. The per-navigation timeout can never
fire against the wrong pending navigation regardless -- that is protected
by the generation counter alone, independent of any load-failed check.

The C<load-changed:finished> success path is matched the same way, via
two complementary, bfcache-safe mechanisms (confirmed live, both directly
and via the tests in F<t/66-nav-finished.t>): first, each pending
navigation captures its OWN committed uri the moment its own
C<load-changed:committed> fires; once captured, a C<finished> whose
current uri (WebKit's C<load-changed:finished> carries no uri of its own,
unlike C<load-failed>) does not match it is stray. This gate is
deliberately inert -- falls through to the second mechanism, below --
for a pending that has not (yet, or ever) seen its own C<committed>,
which is what keeps a bfcache-restored C<back>/C<forward> working: such a
restore may legitimately jump straight to C<finished> with nothing
preceding it at all, and gating on that absence (as C<load-failed>'s
started-since check does) would hang a real, successful navigation --
worse than the bug being fixed. Second, whenever a navigation is torn
down mid-flight to start a new one, the identity of the torn-down
navigation (its own committed uri if it had one, else its current
optimistic uri) is remembered for exactly the lifetime of the nav it
superseded; a C<finished> arriving before that new nav's own commit,
while the browser's current uri does not coincide with the remembered
one, can only be the superseded navigation's belated tail (WebKit
completes a request it has already handed a response to even after
being superseded/cancelled -- confirmed live -- and reliably fires
C<load-changed:finished> as the terminal event of a load's lifecycle even
after a C<load-failed> for that same load) rather than a legitimate
signal-skipping resolution of the still-uncommitted new one. Confirmed
live for C<go>-vs-C<go> (a C<mock_scheme> producer reentrantly starting a
second, real navigation before returning) and for C<reload>-vs-C<go>
(the same reentrant shape, C<reload> superseding onto the last-committed
page) -- in both cases the superseding navigation's real, later, genuine
failure is now correctly delivered instead of being replaced by an
early, false success from the superseded navigation's own tail signal.

If the superseded navigation's uri happens to be identical to the uri
the new, superseding navigation is itself headed to or already showing
(not just for C<reload>, as an earlier revision of this note implied --
the same coincidence is possible for C<go>-vs-C<go> a fraction of a
millisecond apart, or any other overlap pairing that happens to target
the same uri), the two are genuinely indistinguishable from WebKit's own
signals alone, and the callback may end up resolved by the
wrong-but-identical-outcome event rather than by the new navigation's own.
This is irreducible with the information WebKit's signals expose (neither
C<load-changed:finished> nor the browser's current uri carry anything
that identifies which logical navigation they belong to), but harmless in
practice: since the uri is the same either way, the delivered outcome
(success, and which page is actually showing) is truthful regardless of
whose signal technically produced it.

C<< chrome => 1 >>'s reload/stop button and loading state are updated from
a separately-connected C<load-changed> listener that shares the exact same
finished-is-stray verdict as the callback-matching logic above, so a
stray C<finished> for a superseded navigation does not flip it either
(confirmed live: the button stays in its "loading" state across a stray
event, changing only on the superseding navigation's own genuine
completion).

=item Element registry isolation

The C<find>/C<find_all> element registry (C<window.__evwk>) lives in a
dedicated named JavaScript B<isolated world>, not the page's own main world.
An isolated world has its own global object and its own built-in prototypes
and shares only the DOM with the page, so page script cannot see or
overwrite C<window.__evwk>, and every internal DOM call (C<find>,
C<find_all>, C<wait_for>, C<html>, and all L<EV::WebKit::Element> methods)
marshals its result with the world's B<own> C<JSON.stringify> and
C<Object.prototype>. A hostile or buggy page that redefines C<JSON.stringify>
or pollutes C<Object.prototype.toJSON> therefore cannot corrupt an element
handle into pointing at the wrong node, nor stall a callback: those calls
keep returning correct results regardless of what the page does to its own
world. (C<find>/C<find_all> additionally shape-check every decoded result
and surface a clean error rather than dereferencing anything unexpected,
as defence in depth.)

C<script> and C<script_async> are the deliberate exception: they run I<your>
JavaScript in the page's main world so it can reach the page's own globals
and libraries, and so their results are marshalled by the page's (possibly
tampered) C<JSON.stringify>. That is inherent to running code in the page;
a page that has redefined C<JSON.stringify> can make your own C<script>
return a wrong value or a plain marshal error (never a hang). If you need a
trustworthy result from an untrusted page, prefer C<find>/C<find_all> and
the element accessors, which run in the isolated world.

Each navigation gets a brand new registry (ids restart at C<0>) stamped
with a fresh per-document epoch; every L<EV::WebKit::Element> handle
carries the epoch of the registry it was created from, so a handle from a
page you have since navigated away from is correctly detected as stale even
though the new page's registry happens to reuse the same numeric id --
see L<EV::WebKit::Element/"DESCRIPTION">. C<id> and C<epoch> are therefore
reserved argument names for any JavaScript run through an
L<EV::WebKit::Element> method.

=item Async completion closures

Several operations (C<script>, C<find>, C<find_all>, C<wait_for>,
C<screenshot>, and the cookie methods) register their completion with
WebKitGTK's asynchronous (C<GAsyncReadyCallback>-style)
GObject-Introspection methods, which do not release the Perl closure
passed to them once it fires. EV::WebKit is deliberately written around
this: each such closure holds only a weak reference to the browser (or
element), so instances become collectable shortly after C<quit> instead of
only at interpreter exit. This is an internal implementation detail and
requires nothing from calling code.

=back

=head1 REQUIREMENTS

WebKitGTK 6.0, GTK4, JavaScriptCore 6.0 and libsoup3, with their
GObject-Introspection typelibs (C<WebKit-6.0>, C<Gtk-4.0>, C<Gdk-4.0>,
C<JavaScriptCore-6.0>, C<Soup-3.0>); L<Glib::Object::Introspection>,
L<Glib::IO>, L<EV>, L<EV::Glib>, and L<Cpanel::JSON::XS> (falls back to
L<JSON::PP> if unavailable). Xvfb (or a real X server) to actually run
anything. Linux only. No XS/C compiler is needed for this distribution
itself.

=head1 SEE ALSO

L<EV::WebKit::Element>, L<EV>, L<EV::Glib>, L<Glib::Object::Introspection>.

L<Firefox::Marionette> is a similar-spirited Perl browser-automation module
(for Firefox, via the Marionette protocol) that was a source of API-design
inspiration for this one. The WebKitGTK 6.0 API reference is at
L<https://webkitgtk.org/reference/webkitgtk/stable/>.

=head1 AUTHOR

vividsnow

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
