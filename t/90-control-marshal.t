use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available(); use TCTL;
use File::Temp qw(tempdir);
use MIME::Base64 ();
use EV; use EV::WebKit; use EV::WebKit::Control; use EV::WebKit::Protocol;

# Results that are not plain data. Everything here was a live bug: the server
# happily handed a blessed Element, or raw PNG octets, to a JSON encoder.

my $dir  = tempdir(CLEANUP => 1);
my $path = "$dir/m.sock";

my $b = EV::WebKit->new(window => [300,200], ephemeral => 1);
$b->mock_scheme('m', sub { ('<html><body><h1>hi</h1></body></html>', 'text/html') });
my $ctl = EV::WebKit::Control->listen($b, path => $path);
my $cl  = TCTL->new($path);
$cl->pump(1);   # hello
$cl->reply({ i => 1, m => 'go', a => ['m://p'] }, 25);

# 1) wait_for resolves with an ELEMENT, exactly as find/find_all do -- an easy
#    one to miss, because it reads like a plain "wait until" call. Handed to the
#    JSON codec it dies INSIDE EV::WebKit's _defer timer, where $EV::DIED merely
#    warns: the browser lives, and the request is never answered at all. A client
#    hung forever is the one failure mode this protocol must not have.
{
    my $r = $cl->reply({ i => 2, m => 'wait_for', a => ['h1'] }, 25);
    ok($r, 'wait_for is ANSWERED (it used to hang the request forever)')
        or diag('no response at all -- the result was an object the codec could not encode');
    ok($r && !exists $r->{e}, '...without an error') or diag('err=' . ($r->{e} // ''));
    ok($r && ref $r->{r} eq 'HASH' && defined $r->{r}{h},
        '...with an element HANDLE, like find') or diag(explain $r);

    # and the handle actually works
    my $h = $r->{r}{h};
    is($cl->reply({ i => 3, m => 'el.text', h => $h })->{r}, 'hi',
        '...and the handle reads its element');
}

# 2) NOTHING may answer with silence. Any result the codec cannot encode must
#    come back as an error -- this is the general guard, and the reason the next
#    method to return an object will be an error instead of a hung client.
{
    my $r = $cl->reply({ i => 4, m => 'wait_for', a => ['#never'], o => { timeout => 1 } }, 15);
    ok($r, 'a wait_for that times out is answered too');
    is($r && $r->{e}, 'timeout', "...with the module's uniform 'timeout' error");
}

# 3) screenshot's first argument is a PATH or an options HASHREF, and flattening
#    options destroys the distinction: {"o":{"bytes":1}} became
#    screenshot('bytes', 1), which took 'bytes' for a path, wrote a real PNG to a
#    file of that name in the server's working directory, and reported success.
{
    my $cwd_before = -e 'bytes' ? 1 : 0;
    my $r = $cl->reply({ i => 5, m => 'screenshot', o => { bytes => 1 } }, 25);
    ok($r && !exists $r->{e}, 'screenshot(bytes => 1) succeeds') or diag('err=' . ($r->{e} // ''));
    ok(!(-e 'bytes') || $cwd_before,
        '...and does NOT write a stray file called "bytes" into the working directory')
        or do { diag('the server wrote a PNG to a file literally named "bytes"'); unlink 'bytes' };

    # 4) raw PNG octets cannot live in a JSON string: they come back base64'd
    ok($r && ref $r->{r} eq 'HASH' && exists $r->{r}{b64},
        '...and the image comes back base64-encoded, as documented')
        or diag('the raw bytes went straight into the JSON encoder');
    my $png = MIME::Base64::decode_base64($r->{r}{b64} // '');
    is(substr($png, 0, 8), "\x89PNG\r\n\x1a\n", '...and it decodes to a real PNG');
}

# 5) path mode still works, and the result is still the path
{
    my $r = $cl->reply({ i => 6, m => 'screenshot', a => ["$dir/shot.png"] }, 25);
    is($r && $r->{r}, "$dir/shot.png", 'screenshot($path) still answers with the path');
    ok(-s "$dir/shot.png", '...and really wrote the file');
}

# 6) A request PIPELINED behind quit in one write must not be silently swallowed.
#    quit tears the server down mid-loop, and anything behind it used to be
#    dispatched against a client that no longer existed: the side effects ran and
#    the answer went nowhere.
#
#    On its OWN browser+server: quit here tears down that browser, and a second
#    teardown of the shared one (its own quit here, then global destruction)
#    double-frees the native session.
{
    my $qb = EV::WebKit->new(window => [200,150], ephemeral => 1);
    my $qctl = EV::WebKit::Control->listen($qb, path => "$dir/q.sock");
    my $c2 = TCTL->new("$dir/q.sock");
    $c2->pump(1);
    $c2->send_raw(
        EV::WebKit::Protocol::encode({ i => 1, m => 'title' }) .
        EV::WebKit::Protocol::encode({ i => 2, m => 'quit' }) .
        EV::WebKit::Protocol::encode({ i => 3, m => 'title' })
    );
    my @f = $c2->pump(6, 10);
    my %ans = map { $_->{i} => $_ } grep { !defined $_->{ev} && defined $_->{i} } @f;
    ok($ans{1}, 'the request before quit is answered');
    ok($ans{2}, 'the quit itself is answered');
    ok(!$ans{3} || exists $ans{3}{e},
        'a request pipelined AFTER quit is either answered or refused -- never silently run and dropped')
        or diag('it was dispatched against a client that no longer existed');
    $c2->close;
    $qctl->close;   # quit already tore qb down; this is a no-op, but be explicit
}

$ctl->close;
$b->quit;
done_testing;
