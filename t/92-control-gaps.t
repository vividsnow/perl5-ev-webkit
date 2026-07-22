use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available(); use TCTL;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use EV; use EV::WebKit; use EV::WebKit::Control; use EV::WebKit::Client; use EV::WebKit::Protocol;

# Gaps mutation testing found: guards that are load-bearing but were unproven,
# and paths no test drove. Each of these is a mutant that survived a green suite.

my $dir  = tempdir(CLEANUP => 1);
my $path = "$dir/g.sock";

my $b = EV::WebKit->new(window => [300,200], ephemeral => 1);
$b->mock_scheme('g', sub { ('<html><body><h1>hi</h1></body></html>', 'text/html') });
my $ctl = EV::WebKit::Control->listen($b, path => $path);

# 1) A SYNC method that CROAKS over the wire must still be answered. settings
#    with a non-hashref, set_user_agent with a ref -- these die inside the
#    browser, and without the dispatch eval the request would get no answer at
#    all: a hung client, the one failure mode this protocol must not have.
{
    my $cl = TCTL->new($path); $cl->pump(1);
    my $r = $cl->reply({ i => 1, m => 'settings', a => ['not a hashref'] });
    ok($r && defined $r->{e}, 'a sync method that croaks is answered with an error, not silence')
        or diag('no answer -- the client would hang');
    # and the connection still works afterwards
    is($cl->reply({ i => 2, m => 'title' })->{i}, 2, '...and the connection survives it');
    $cl->close;
    for (1 .. 3) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run }
}

# 2) A sync request answered EXACTLY once -- no stray second frame for one id.
{
    my $cl = TCTL->new($path); $cl->pump(1);
    $cl->send_frame({ i => 5, m => 'title' });
    my @f = $cl->pump(3, 5);       # pump a bit longer than one answer
    my @ans = grep { !defined $_->{ev} && ($_->{i} // 0) == 5 } @f;
    is(scalar @ans, 1, 'a request is answered exactly once (no double-fire)');
    $cl->close;
    for (1 .. 3) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run }
}

# 3) listen(): a STALE socket file is reused; a LIVE one is refused. Neither
#    branch was exercised anywhere.
{
    my $sp = "$dir/stale.sock";
    # a plain leftover file where the socket should be
    open my $f, '>', $sp or die $!; close $f;
    my $tb = EV::WebKit->new(window => [200,150], ephemeral => 1);
    my $t_ctl = eval { EV::WebKit::Control->listen($tb, path => $sp) };
    ok($t_ctl, 'listen() reuses a stale socket path (a leftover file is cleared)')
        or diag("refused a stale path: $@");

    # a second listen on the SAME live path must be refused, not silently steal it
    my $tb2 = EV::WebKit->new(window => [200,150], ephemeral => 1);
    my $ok = eval { EV::WebKit::Control->listen($tb2, path => $sp); 1 };
    ok(!$ok, 'listen() refuses a path already served by a live process');
    like($@, qr/already served/, '...saying why');
    $t_ctl->close if $t_ctl;
    $tb->quit; $tb2->quit;
}

# 4) ev mode: TWO requests genuinely in flight at once, each matched by its own
#    id -- not by arrival order. A slow op issued before a fast one answers
#    second, and the wrong-order match would silently hand each caller the
#    other's result.
{
    my $c = EV::WebKit::Client->connect($path, ev => 1);
    my (%got, $pending);
    $pending = 2;
    # a slow script (a real delay) issued FIRST, a fast one SECOND
    $c->script('return await new Promise(r => setTimeout(() => r("SLOW"), 400))', sub { $got{slow} = $_[0]; EV::break unless --$pending });
    $c->script('return "FAST"', sub { $got{fast} = $_[0]; EV::break unless --$pending });
    my $wd = EV::timer(20, 0, sub { EV::break }); EV::run; undef $wd;
    is($got{slow}, 'SLOW', 'ev mode: the slow request gets the slow result...');
    is($got{fast}, 'FAST', '...and the fast one gets the fast result (matched by id, not arrival order)');
    $c->disconnect;
}

# 5) ev mode: the browser dies with a request still in flight. Every pending
#    callback must be answered with an error, not dropped -- a dropped callback
#    is a hung caller.
{
    my $tdir = tempdir(CLEANUP => 1);
    my $tpath = "$tdir/die.sock";
    my $tb = EV::WebKit->new(window => [200,150], ephemeral => 1);
    $tb->mock_scheme('d', sub { ('<html><body>x</body></html>', 'text/html') });
    my $tctl = EV::WebKit::Control->listen($tb, path => $tpath);

    my $c = EV::WebKit::Client->connect($tpath, ev => 1);
    my ($fired, $err) = (0, undef);
    # a slow request, so it is genuinely still in flight when we kill the server
    $c->script('return await new Promise(r => setTimeout(() => r(1), 5000))', sub { $fired++; $err = $_[1]; EV::break });
    # tear the server + browser down while it is outstanding
    my $kill = EV::timer(0.3, 0, sub { $tctl->close; $tb->quit });
    my $wd   = EV::timer(15, 0, sub { EV::break }); EV::run; undef $wd; undef $kill;
    is($fired, 1, 'ev mode: a request in flight when the browser dies IS answered');
    ok(defined $err, '...with an error, not dropped') or diag('the callback never fired -- a hung caller');
    $c->disconnect;
}

# 6) Control chains EVERY handler, not just on_console. A browser built with its
#    own on_load/on_error must keep firing them after Control wires its events on
#    top.
{
    my $tdir = tempdir(CLEANUP => 1);
    my $tpath = "$tdir/chain.sock";
    my @own_load;
    my $tb = EV::WebKit->new(window => [200,150], ephemeral => 1,
                             on_load => sub { push @own_load, 'own' });
    $tb->mock_scheme('c', sub { ('<html><body>x</body></html>', 'text/html') });
    my $tctl = EV::WebKit::Control->listen($tb, path => $tpath);   # wires on_load on top

    my $cl = TCTL->new($tpath); $cl->pump(1);
    $cl->reply({ i => 1, m => 'go', a => ['c://p'] }, 20);
    for (1 .. 5) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run }
    ok(scalar(@own_load) >= 1,
        "the browser's own on_load still fires after Control chains onto it (not clobbered)")
        or diag('Control replaced the handler instead of chaining it');
    $cl->close; $tctl->close; $tb->quit;
}

# 7) A cookie set through the protocol survives a disconnect + reconnect. This is
#    the design's use case 2 (reuse a logged-in session), and nothing tested it
#    through the wire -- the shipped re-attach test only checked uri/title.
#
#    Driven with TCTL (a raw socket that pumps the loop itself), NOT a blocking
#    EV::WebKit::Client: a blocking client in THIS process would sit in sysread
#    and never let the browser's own loop run to answer it -- a deadlock, which
#    is exactly why the real blocking-client tests run in a child (see t/88).
{
    my $tdir = tempdir(CLEANUP => 1);
    my $tpath = "$tdir/cookie.sock";
    my $tb = EV::WebKit->new(window => [200,150], ephemeral => 1);
    my $tctl = EV::WebKit::Control->listen($tb, path => $tpath);

    my $c1 = TCTL->new($tpath); $c1->pump(1);       # hello
    $c1->reply({ i => 1, m => 'set_cookie',
                 a => [{ name => 'sid', value => '42', domain => 'example.com', path => '/' }] }, 15);
    $c1->close;
    for (1 .. 5) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run }   # let the server reap it

    my $c2 = TCTL->new($tpath); $c2->pump(1);       # a fresh connection, same browser
    my $r = $c2->reply({ i => 1, m => 'cookies', a => ['http://example.com/'] }, 15);
    my $list = $r->{r} || [];
    ok(scalar(grep { $_->{name} eq 'sid' && $_->{value} eq '42' } @$list),
        'a cookie set through the protocol survives a client disconnect + reconnect (session reuse)')
        or diag('the cookie did not survive -- use case 2 is broken over the wire');
    $c2->close;
    $tctl->close; $tb->quit;
}

$ctl->close;
$b->quit;
done_testing;
