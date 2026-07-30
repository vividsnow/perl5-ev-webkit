package EV::WebKit::Control;
use v5.10;
use strict;
use warnings;

use Carp ();
use Errno ();
use EV;
use IO::Socket::UNIX ();   # () like every other import here: its Socket re-exports would otherwise land in this package as callable methods
use MIME::Base64 ();
use Scalar::Util qw(weaken);
use EV::WebKit::Protocol;

our $VERSION = '0.04';

# A control server for a RUNNING EV::WebKit instance: another process can drive
# the browser this one opened. See
# docs/superpowers/specs/2026-07-13-control-protocol-design.md
#
# This server is a PURE CONSUMER of EV::WebKit's public API. It calls the same
# go()/find()/script() any caller would, and adds no code path inside the
# browser. That is load-bearing rather than tidy: the core's invariants hold
# because they are CLOSED, and a socket server reaching into internals would
# reopen every one of them. If you find yourself writing $b->{...} here, stop.

# Methods that answer immediately.
my %SYNC = map { $_ => 1 } qw(
    uri title is_loading user_agent can_go_back can_go_forward status
    stop settings set_user_agent set_proxy show_devtools
);

# Methods that take a trailing callback and answer later.
#
# NOT here, because they need their own handling:
#   find, find_all, wait_for -- all three resolve with an ELEMENT, which cannot
#     cross a socket; they are marshalled into handles below. (wait_for is the
#     easy one to miss: it looks like a plain "wait until" call, but on success
#     it hands back the element it was waiting for.)
#   screenshot -- its first argument is either a path OR an options hashref, a
#     distinction the generic option-flattening destroys, and in bytes mode its
#     result is raw PNG octets that must be base64'd to survive JSON.
#   scroll -- its callback is a NAMED option (cb => ...), not a trailing
#     argument, so the generic (@a, %o, $cb) call below would flatten the
#     callback into %o as a stray odd element. Dispatched separately.
my %ASYNC = map { $_ => 1 } qw(
    go load_html back forward reload
    script script_async html pdf
    press download wait_for_js
    set_cookie cookies clear_cookies save_cookies load_cookies
);

# EV::WebKit::Element's methods, reachable as el.<name> with a handle, and the
# [min, max] arguments each takes BEFORE its callback.
#
# Both bounds are load-bearing. These methods bind positionally rather than
# popping the callback off the end, so a wrong count shifts the callback slot:
# one SHORT leaves the real callback undef (and a callback-less call is legal,
# so nothing complains); one LONG pushes it past the end, where most methods
# croak but uncheck's `my ($s, $cb) = @_` takes the junk silently. Either way
# nothing answers and the client hangs until the socket closes.
my %EL_METHOD = (
    text => [0,0], html => [0,0], value => [0,0], tag => [0,0], is_visible => [0,0],
    click => [0,0], focus => [0,0], clear => [0,0], submit => [0,0],
    scroll_into_view => [0,0], hover => [0,0], box => [0,0], uncheck => [0,0],
    check => [0,1],                       # the state is optional
    attr => [1,1], prop => [1,1], type => [1,1], find => [1,1], find_all => [1,1],
    select_option => [1,1],
    send_keys => [1,1],   # a glob alias for type, and the only alias in the dist
);

sub listen {
    my ($class, $browser, %o) = @_;
    Carp::croak('listen: a browser is required') unless ref $browser;
    my $path = $o{path} or Carp::croak('listen: path is required');

    # The socket is the authentication boundary: anyone who can connect can run
    # arbitrary JavaScript in this browser and read every cookie it holds. So
    # refuse to put it anywhere the world can reach.
    my ($dir) = $path =~ m{^(.*)/[^/]+$};
    $dir = '.' unless defined $dir && length $dir;
    my @st = stat $dir or Carp::croak("listen: cannot stat '$dir': $!");
    Carp::croak("listen: refusing to listen in a world-writable directory ('$dir')")
        if ($st[2] & 0002) && !($st[2] & 01000);   # world-writable and not sticky

    # A leftover socket file from a crashed process is ordinary; a LIVE one means
    # somebody else already owns this path. Tell them apart by connecting.
    if (-e $path) {
        if (IO::Socket::UNIX->new(Peer => $path)) {
            Carp::croak("listen: '$path' is already served by a live process");
        }
        unlink $path or Carp::croak("listen: cannot remove stale socket '$path': $!");
    }

    my $old = umask 0177;             # create it 0600 with no chmod race
    my $srv = IO::Socket::UNIX->new(Local => $path, Listen => 16);
    umask $old;
    Carp::croak("listen: cannot listen on '$path': $!") unless $srv;
    $srv->blocking(0);

    # Writing to a client that has closed raises SIGPIPE, whose default is to
    # KILL THE PROCESS -- so an ordinary client disconnect, timed badly, would
    # take the browser down with it. In practice Gtk4::init() happens to set
    # SIGPIPE to ignore, so this has never fired; relying on a side effect of
    # somebody else's initialiser is not a plan. Say it ourselves, and let
    # _flush's EPIPE check do the work. (Process-wide, as signal dispositions
    # are -- but ignoring SIGPIPE is what any socket server does.)
    $SIG{PIPE} = 'IGNORE';

    my $self = bless {
        browser     => $browser,
        path        => $path,
        srv         => $srv,
        clients     => {},   # id => client state
        next_id     => 0,
        handles     => {},   # handle => { el => $element, client => $id }
        next_handle => 0,
    }, $class;

    weaken(my $wself = $self);
    $self->{aw} = EV::io($srv, EV::READ, sub {
        my $s = $wself or return;
        while (my $fh = $s->{srv}->accept) { $s->_add_client($fh) }
    });

    $self->_wire_events;
    return $self;
}

# Chain the browser's event handlers so a client hears what it did not ask for --
# above all the human navigating a window the client is also driving.
#
# CHAINED, never clobbered: eg/browser.pl prints console lines to its terminal
# while this server forwards the same lines to its clients, and neither knows
# about the other.
#
# And weakened BOTH ways. The browser holds these closures, so a closure that
# captures the browser strongly is a $b -> on_load -> $b cycle plain refcounting
# can never break -- this module has shipped that exact bug more than once. The
# server is weakened for the same reason from the other side.
sub _wire_events {
    my $self = shift;
    my $b    = $self->{browser};
    weaken(my $ws = $self);
    weaken(my $wb = $b);

    my $prev_nav = $b->on_navigate;
    $b->on_navigate(sub {
        $prev_nav->(@_) if $prev_nav;
        my $s = $ws or return;
        # Every element handle belongs to the page that just went away: the
        # registry's epoch changed, so they are all stale by definition. Freeing
        # them here is what keeps the handle table from growing without bound --
        # see _hold.
        $s->_release_all_handles;
        $s->_broadcast(navigate => { uri => $_[0] });
    });

    my $prev_load = $b->on_load;
    $b->on_load(sub {
        $prev_load->(@_) if $prev_load;
        my ($s, $br) = ($ws, $wb);
        return unless $s && $br;
        $s->_broadcast(load => {
            uri   => scalar eval { $br->uri },
            title => scalar eval { $br->title },
        });
    });

    my $prev_con = $b->on_console;
    $b->on_console(sub {
        $prev_con->(@_) if $prev_con;
        my $s = $ws or return;
        $s->_broadcast(console => { text => $_[0] });
    });

    my $prev_err = $b->on_error;
    $b->on_error(sub {
        $prev_err->(@_) if $prev_err;
        my $s = $ws or return;
        $s->_broadcast(error => { error => $_[0] });
    });

    # The HUMAN closing the window. (A client's quit over the wire does not come
    # through here -- see the quit branch of _dispatch, which broadcasts too.)
    my $prev_close = $b->on_close;
    $b->on_close(sub {
        if (my $s = $ws) {
            $s->_broadcast(close => {});
            $s->close;
        }
        $prev_close->(@_) if $prev_close;   # the caller's EV::break goes LAST
    });

    return;
}

sub path { $_[0]{path} }

sub _add_client {
    my ($self, $fh) = @_;
    $fh->blocking(0);
    my $id = ++$self->{next_id};
    my $c  = $self->{clients}{$id} = {
        id  => $id,
        fh  => $fh,
        dec => EV::WebKit::Protocol::decoder(),
        out => '',
    };

    weaken(my $wself = $self);
    $c->{rw} = EV::io($fh, EV::READ, sub {
        my $s = $wself or return;
        my $n = sysread($fh, my $buf, 65536);
        if (!defined $n) {
            return if $!{EAGAIN} || $!{EINTR};
            return $s->_drop_client($id);
        }
        return $s->_drop_client($id) unless $n;     # EOF
        # Stop the instant this client is gone. A `quit` frame tears the server
        # down mid-loop, and anything pipelined behind it in the same read would
        # otherwise be dispatched against a client that no longer exists: the
        # side effects would run and the answer would go nowhere, which is a
        # silently dropped request -- a hung client.
        for my $f ($c->{dec}->($buf)) {
            # Guarded per FRAME: a die inside _dispatch escapes into the read
            # watcher, losing this frame's answer AND every sibling decoded from
            # the same sysread. The known cause is fixed at its source, but a
            # whole batch is too much to lose to any future unguarded path.
            unless (eval { $s->_dispatch($id, $f); 1 }) {
                my $e = _clean($@) || 'internal error';
                warn "EV::WebKit::Control: dispatch died: $e";
                eval { $s->_send($id, { i => $f->{i}, e => $e }) };
            }
            last unless exists $s->{clients}{$id};
        }
    });

    # Greet, so a client attaching to a long-lived session learns where the
    # browser already is without having to ask for it.
    my $b = $self->{browser};
    $self->_send($id, {
        ev    => 'hello',
        proto => EV::WebKit::Protocol::PROTO,
        uri   => scalar eval { $b->uri },
        title => scalar eval { $b->title },
    });
    return;
}

sub _drop_client {
    my ($self, $id) = @_;
    my $c = delete $self->{clients}{$id} or return;
    $self->_release_handles_of($id);
    delete $c->{rw};
    delete $c->{ww};
    if ($c->{fh}) {
        $self->_drain($c);
        close $c->{fh};
    }
    return;
}

# Get whatever is still queued out of the door before closing the socket.
#
# Without this, close() throws away {out} -- and {out} is exactly where a
# client's own quit-ack and the 'close' event sit when its socket is backed up
# (a burst of broadcasts it has not drained yet). The client then sees a bare
# EOF and cannot tell an orderly shutdown from the browser crashing, which is
# the one thing the close event exists to tell it.
#
# BOUNDED, because the rule that a stalled client must never block the browser
# still holds: half a second, and a peer that has actually gone away fails on the
# first write and costs nothing at all.
sub _drain {
    my ($self, $c) = @_;
    return unless length $c->{out};
    my $end = time + 0.5;
    while (length $c->{out} && time < $end) {
        my $n = syswrite($c->{fh}, $c->{out});
        if (defined $n) { substr($c->{out}, 0, $n, ''); next }
        last unless $!{EAGAIN} || $!{EINTR};    # the peer is gone: nothing to drain to
        my $w = '';
        vec($w, fileno($c->{fh}), 1) = 1;
        select undef, $w, undef, 0.05;          # wait briefly for it to take more
    }
    return;
}

# Queue a frame and flush what we can. A slow or stalled client must NEVER block
# the browser, so anything the socket will not take right now waits in {out} and
# a write watcher drains it.
sub _send {
    my ($self, $id, $frame) = @_;
    my $c = $self->{clients}{$id} or return;
    my $line = eval { EV::WebKit::Protocol::encode($frame) };
    unless (defined $line) {
        # A frame the codec cannot encode must NOT become silence. The die would
        # otherwise happen inside EV::WebKit's _defer timer, where $EV::DIED
        # merely warns -- and the client would wait forever for a response that
        # is never coming. A hung client is the one failure mode this protocol
        # must not have, so an unencodable result is answered AS an error.
        #
        # (What triggers this: a method whose result is an object rather than
        # plain data. find/find_all/wait_for all resolve with an Element, which
        # is why they are marshalled into handles below. This guard is what keeps
        # the NEXT such method from being a silent hang instead of an error.)
        my $why = _clean($@);
        warn "EV::WebKit::Control: cannot encode a frame: $why";
        return unless exists $frame->{i};      # an event: there is nobody to answer
        $line = EV::WebKit::Protocol::encode({ i => $frame->{i}, e => "cannot encode result: $why" });
    }
    $c->{out} .= $line;
    $self->_flush($id);
    return;
}

sub _flush {
    my ($self, $id) = @_;
    my $c = $self->{clients}{$id} or return;
    while (length $c->{out}) {
        my $n = syswrite($c->{fh}, $c->{out});
        if (!defined $n) {
            last if $!{EAGAIN} || $!{EINTR};
            return $self->_drop_client($id);       # the peer is gone
        }
        substr($c->{out}, 0, $n, '');
    }
    if (length $c->{out}) {
        weaken(my $wself = $self);
        $c->{ww} ||= EV::io($c->{fh}, EV::WRITE, sub {
            my $s = $wself or return;
            $s->_flush($id);
        });
    }
    else {
        delete $c->{ww};
    }
    return;
}

sub _dispatch {
    my ($self, $id, $f) = @_;
    if ($f->{_bad}) {
        $self->_send($id, { i => undef, e => $f->{_bad} });
        # An oversized line poisons this connection's decoder for good -- it can
        # never make sense of the stream again, and every later request would get
        # the same baffling 'line too long' (even a `title` that takes no
        # arguments at all). Drop it and let the client reconnect, which is the
        # only thing that can actually help.
        $self->_drop_client($id) if $f->{_bad} =~ /too long/;
        return;
    }

    my $rid = $f->{i};
    my $m   = $f->{m} // '';
    # SHAPE, not just presence: `// []` guards a MISSING field and does nothing
    # about a present one of the wrong type, and @{ $hashref } is a fatal "Not an
    # ARRAY reference" thrown inside the read watcher where nothing catches it.
    # So {"a":{}} went unanswered and took every frame decoded from the same
    # sysread with it.
    for my $bad ([a => 'ARRAY', 'an array'], [o => 'HASH', 'an object']) {
        my ($k, $want, $shown) = @$bad;
        next if !defined $f->{$k} || ref $f->{$k} eq $want;
        return $self->_send($id, { i => $rid, e => "'$k' must be $shown" });
    }
    my @a   = @{ $f->{a} // [] };
    my %o   = %{ $f->{o} // {} };
    my $b   = $self->{browser};

    weaken(my $wself = $self);
    my $answer = sub {                       # exactly one response per request
        my ($r, $e) = @_;
        my $s = $wself or return;
        $s->_send($id, defined $e ? { i => $rid, e => "$e" } : { i => $rid, r => $r });
    };

    # quit is special: answer FIRST, because the socket is about to close, and
    # tell every client the browser is going. on_close does not cover this --
    # that fires only when a HUMAN closes the window.
    if ($m eq 'quit') {
        $answer->(1);
        $self->_broadcast(close => {});
        eval { $b->quit };
        $self->close;
        return;
    }

    # An Element cannot cross a socket, so find/find_all answer with a HANDLE the
    # server holds on the client's behalf.
    my $marshal = sub {
        my ($r, $e) = @_;
        my $s = $wself or return;
        return $answer->(undef, $e)                                if defined $e;
        return $answer->(undef)                                    if !defined $r;
        return $answer->([ map { $s->_hold($id, $_) } @$r ])       if ref $r eq 'ARRAY';
        return $answer->($s->_hold($id, $r));
    };

    # All three resolve with an Element on success.
    if ($m eq 'find' || $m eq 'find_all' || $m eq 'wait_for') {
        my $ok = eval { $b->$m(@a, %o, $marshal); 1 };
        return $answer->(undef, _clean($@)) unless $ok;
        return;
    }

    # screenshot($path, %opt, $cb) or screenshot(\%opt, $cb) -- the first argument
    # is a path OR an options hashref, and the generic flattening below cannot
    # express that: {"o":{"bytes":1}} would become screenshot('bytes', 1, $cb),
    # which takes 'bytes' for a PATH and writes a PNG to a file of that name in
    # the server's working directory, then reports success. And in bytes mode the
    # result is raw PNG octets, which cannot live in a JSON string at all.
    if ($m eq 'screenshot') {
        my @args = @a ? (@a, %o) : (\%o);
        # Whether bytes were asked for has to be worked out the same way
        # EV::WebKit::screenshot works it out, because a client sends its
        # arguments positionally, exactly as it received them: the options may be
        # the leading hashref, or trailing pairs after a path.
        my %sopt = (ref $args[0] eq 'HASH') ? %{ $args[0] } : @args[1 .. $#args];
        my $want_bytes = $sopt{bytes};
        my $ok = eval {
            $b->screenshot(@args, sub {
                my ($r, $e) = @_;
                return $answer->(undef, $e) if defined $e;
                return $answer->({ b64 => MIME::Base64::encode_base64($r, '') })
                    if $want_bytes && defined $r;
                return $answer->($r);          # path mode: the result IS the path
            });
            1;
        };
        return $answer->(undef, _clean($@)) unless $ok;
        return;
    }

    if ($m eq 'el.release') {
        # Ownership checked HERE too: this branch returns before the check below,
        # whose own comment names el.release as a case it covers -- so it did
        # not, and handle ids are small sequential integers. Answer as though the
        # handle is not there, which for this client it is not.
        my $h   = $f->{h} // '';
        my $rec = $self->{handles}{$h};
        return $answer->(undef, 'stale element')
            unless $rec && defined $rec->{client} && $rec->{client} == $id;
        delete $self->{handles}{$h};
        return $answer->(1);
    }

    if (index($m, 'el.') == 0) {
        my $em = substr($m, 3);
        return $answer->(undef, "unknown method: $m") unless exists $EL_METHOD{$em};
        my ($min, $max) = @{ $EL_METHOD{$em} };
        if (@a < $min || @a > $max) {
            my $want = $min == $max ? $min : "$min to $max";
            return $answer->(undef,
                "$m: expected $want argument" . ($max == 1 && $min == 1 ? '' : 's') . ', got ' . scalar(@a));
        }
        my $rec = $self->{handles}{ $f->{h} // '' };
        # A handle belongs to the client that made it. Handle ids are small
        # sequential integers, so without this a client could reach another's
        # element -- or el.release it out from under them -- by guessing a
        # number. It grants no capability a client lacks (they can all find()
        # whatever they like: the socket is the privilege boundary, and the
        # design says so), but a handle table keyed per client that does not
        # CHECK the client is an accident waiting to be relied upon.
        return $answer->(undef, 'stale element')
            unless $rec && defined $rec->{client} && $rec->{client} == $id;
        my $el = $rec->{el};
        my $cb = ($em eq 'find' || $em eq 'find_all') ? $marshal : sub { $answer->(@_) };
        my $ok = eval { $el->$em(@a, $cb); 1 };
        return $answer->(undef, _clean($@)) unless $ok;
        return;
    }

    if ($SYNC{$m}) {
        # Sync methods croak (settings, set_user_agent and set_proxy all do). A
        # die in one client's request must never kill the browser or drop
        # anybody else's work -- the same lesson quit()'s flush loops taught.
        my $r = eval { $b->$m(@a) };
        return $answer->(undef, _clean($@)) if $@;
        $r = 1 if ref $r;                    # a mutator returns $b; do not try to serialize a browser
        return $answer->($r);
    }

    # scroll's callback is a named option: passed positionally it would land in
    # %o as a stray odd element.
    if ($m eq 'scroll') {
        my $ok = eval { $b->scroll(@a, %o, cb => sub { $answer->(@_) }); 1 };
        return $answer->(undef, _clean($@)) unless $ok;
        return;
    }

    if ($ASYNC{$m}) {
        my $ok = eval { $b->$m(@a, %o, sub { $answer->(@_) }); 1 };
        return $answer->(undef, _clean($@)) unless $ok;
        return;
    }

    return $answer->(undef, "unknown method: $m");
}

sub _broadcast {
    my ($self, $ev, $data) = @_;
    $self->_send($_, { ev => $ev, %{ $data || {} } }) for keys %{ $self->{clients} };
    return;
}

# Element handles.
#
# Every find() mints an EV::WebKit::Element that holds the browser, so a table
# that is never pruned rebuilds -- in Perl -- the unbounded registry growth that
# was just fixed on the JavaScript side. And a find() poll loop against a
# long-lived page is the ordinary case, not an exotic one.
#
# So handles are freed on three events: the page NAVIGATES (they are all stale by
# then -- the page's epoch changed), the CLIENT DISCONNECTS, and an explicit
# el.release. That bounds the table by "handles made since the last navigation,
# by clients still connected".
sub _hold {
    my ($self, $cid, $el) = @_;
    my $h = ++$self->{next_handle};
    $self->{handles}{$h} = { el => $el, client => $cid };
    return { h => $h };
}

sub _release_handles_of {
    my ($self, $cid) = @_;
    for my $h (keys %{ $self->{handles} || {} }) {
        delete $self->{handles}{$h}
            if defined $self->{handles}{$h}{client} && $self->{handles}{$h}{client} == $cid;
    }
    return;
}

sub _release_all_handles { $_[0]{handles} = {}; return }

sub _clean {
    my $e = shift // 'error';
    $e =~ s/ at \S+ line \d+\.?\s*\z//;
    $e =~ s/\s+\z//;
    return length $e ? $e : 'error';
}

sub close {
    my $self = shift;
    return if $self->{_closed}++;
    delete $self->{aw};
    $self->_drop_client($_) for keys %{ $self->{clients} };
    close $self->{srv} if $self->{srv};
    delete $self->{srv};
    unlink $self->{path} if defined $self->{path} && -S $self->{path};
    return;
}

sub DESTROY { local $@; eval { $_[0]->close } }

1;

__END__

=head1 NAME

EV::WebKit::Control - drive a running EV::WebKit instance from another process

=head1 SYNOPSIS

    use EV; use EV::WebKit; use EV::WebKit::Control;

    my $b   = EV::WebKit->new(chrome => 1, on_close => sub { EV::break });
    my $ctl = EV::WebKit::Control->listen($b, path => "$ENV{XDG_RUNTIME_DIR}/evwk.sock");
    EV::run;

Then, from anywhere else:

    use EV::WebKit::Client;
    my $c = EV::WebKit::Client->connect("$ENV{XDG_RUNTIME_DIR}/evwk.sock");
    $c->go('https://example.com');
    say $c->title;

=head1 DESCRIPTION

An C<EV::WebKit> instance can otherwise only be driven by the process that
created it, which makes a visible browser window a dead end: you can watch it,
but nothing can ask it anything. C<EV::WebKit::Control> puts it on a unix
socket.

The server is a plain consumer of C<EV::WebKit>'s public API -- it calls the
same methods you would -- so it can do nothing to the browser that your own code
could not.

=head1 METHODS

=head2 listen

    my $ctl = EV::WebKit::Control->listen($browser, path => $path);

Starts serving C<$browser> on a unix socket at C<$path>. Croaks if the
containing directory is world-writable, or if a live process already serves that
path. A stale socket file left by a crashed process is removed.

=head2 path

The socket path.

=head2 close

Closes every client connection, stops listening, and removes the socket file.
Idempotent, and run automatically on destruction.

=head1 SECURITY

B<Anyone who can connect to this socket can run arbitrary JavaScript in this
browser and read every cookie it holds.> That is what the tool is for.

The socket is therefore the authentication boundary: it is created mode C<0600>,
and C<listen> refuses to create it in a world-writable directory. There is
deliberately no TCP listener -- that would turn a local privilege into a
network-reachable one.

=head1 SEE ALSO

L<EV::WebKit>, L<EV::WebKit::Client>, L<EV::WebKit::Protocol>.

=cut
