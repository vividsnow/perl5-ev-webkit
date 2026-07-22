use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use File::Temp qw(tempdir);
use EV; use EV::WebKit; use EV::WebKit::Control; use EV::WebKit::Client;

# The client. Blocking by default -- `say $c->title` -- because that is what you
# want from a shell or a one-off script. EV-native with ev => 1, because that is
# what you want inside an event loop.
#
# The browser and the server live in THIS process, and the blocking client talks
# to them over a real socket. That works only because blocking mode is plain
# socket I/O and never runs the event loop: if it did, it would be re-entering
# the very loop the browser is using, which is how EV::Glib gets wedged.
#
# ...which is also why the blocking half runs in a CHILD: this process's EV loop
# has to keep turning for the browser to answer at all.

my $dir  = tempdir(CLEANUP => 1);
my $path = "$dir/cl.sock";

my $b = EV::WebKit->new(window => [300,200], ephemeral => 1);
$b->mock_scheme('cl', sub {
    my $uri = shift;
    return ('<html><head><title>Page</title></head><body><h1>hi</h1>'
          . '<a id="lnk" href="cl://second">go</a><p>a</p><p>b</p></body></html>', 'text/html')
        if $uri =~ /first/;
    return ('<html><head><title>Second</title></head><body><h1>SECOND</h1></body></html>', 'text/html');
});
my $ctl = EV::WebKit::Control->listen($b, path => $path);

# ---- blocking client, in a child (this process must keep running the loop) ----
{
    my $script = "$dir/blocking.pl";
    open my $fh, '>', $script or die $!;
    print $fh <<"CHILD";
use v5.10; use strict; use warnings; \$| = 1;
use EV::WebKit::Client;
my \$c = EV::WebKit::Client->connect('$path');
print "HELLO ", (\$c->hello && \$c->hello->{proto} ? 'yes' : 'no'), "\\n";
\$c->go('cl://first');
print "TITLE ", \$c->title, "\\n";
print "SCRIPT ", \$c->script('return 40 + 2'), "\\n";
my \$el = \$c->find('h1');
print "FIND ", \$el->text, "\\n";
print "TAG ", \$el->tag, "\\n";
my \$all = \$c->find_all('p');
print "FINDALL ", scalar(\@\$all), "\\n";
print "URI ", \$c->uri, "\\n";
# an error CROAKS in blocking mode: synchronous code has no callback to hand it to
my \$ok = eval { \$c->go(undef); 1 };
print "CROAK ", (\$ok ? 'no' : 'yes'), " ", (\$@ =~ /uri required/ ? 'right-error' : "wrong: \$@"), "\\n";
# a stale handle after navigating
\$c->go('cl://second');
my \$stale = eval { \$el->text; 1 } ? 'no' : 'yes';
print "STALE \$stale\\n";
# events arrived while we were working
my \@ev = \$c->events;
print "EVENTS ", scalar(grep { \$_->{ev} eq 'navigate' } \@ev), "\\n";
\$c->disconnect;

# RE-ATTACH. This is use case 2: the browser holds expensive state (a login, a
# warmed-up page), a script does its work and leaves, and the next one picks up
# where it left off. The greeting is what tells it where the browser already is.
my \$c2 = EV::WebKit::Client->connect('$path');
print "REATTACH ", (\$c2->hello->{uri} // '(none)'), "\\n";
print "REATTACH_TITLE ", (\$c2->hello->{title} // '(none)'), "\\n";
\$c2->disconnect;
CHILD
    close $fh;

    # run the child while THIS process keeps the browser's loop turning
    my $out = '';
    open my $ph, '-|', "$^X -Ilib $script 2>/dev/null" or die $!;
    my $iow = EV::io($ph, EV::READ, sub {
        my $n = sysread($ph, my $buf, 8192);
        if (!defined $n or !$n) { return EV::break }
        $out .= $buf;
    });
    my $wd = EV::timer(60, 0, sub { EV::break });
    EV::run;
    undef $iow; undef $wd;
    close $ph;

    like($out, qr/^HELLO yes$/m,   'the client is greeted on connect (it learns where the browser already is)');
    like($out, qr/^TITLE Page$/m,  'a blocking call returns the value: say $c->title');
    like($out, qr/^SCRIPT 42$/m,   'script() runs in the browser and the value comes back');
    like($out, qr/^FIND hi$/m,     'find() returns an element proxy, and its text reads');
    like($out, qr/^TAG h1$/m,      '...and its other methods work');
    like($out, qr/^FINDALL 2$/m,   'find_all() returns a proxy per match');
    like($out, qr/^URI cl:\/\/first$/m, 'uri() reflects where the client sent the browser');
    like($out, qr/^CROAK yes right-error$/m,
        'an error croaks in blocking mode, with the browser\'s own error string')
        or diag($out);
    like($out, qr/^STALE yes$/m,
        'a handle from the previous page is stale after navigating (it does not read the wrong node)');
    like($out, qr/^EVENTS [1-9]/m,
        'events that arrived while working are collected, not lost');
    like($out, qr{^REATTACH cl://second$}m,
        'a NEW client attaching later is told where the browser already is (session reuse)')
        or diag($out);
    like($out, qr/^REATTACH_TITLE Second$/m, '...including the title');
}

# ---- EV-native client, in this process ----
{
    my $c = EV::WebKit::Client->connect($path, ev => 1);

    my ($r, $e, $fired) = (undef, undef, 0);
    $c->go('cl://first', sub { ($r, $e) = @_; $fired++; EV::break });
    { my $wd = EV::timer(25, 0, sub { EV::break }); EV::run; undef $wd }
    is($fired, 1, 'ev mode: the callback fires exactly once');
    is($e, undef, '...with no error');

    my $title;
    $c->title(sub { $title = $_[0]; EV::break });
    { my $wd = EV::timer(10, 0, sub { EV::break }); EV::run; undef $wd }
    is($title, 'Page', 'ev mode: a value comes back through the callback');

    # errors are DELIVERED, not croaked -- the same ($result, $err) shape as
    # EV::WebKit itself, so code moves between local and remote unchanged
    my ($er, $ee);
    $c->go(undef, sub { ($er, $ee) = @_; EV::break });
    { my $wd = EV::timer(10, 0, sub { EV::break }); EV::run; undef $wd }
    like($ee // '', qr/uri required/, 'ev mode: an error is delivered to the callback, not croaked');
    is($er, undef, '...with no result');

    # an element proxy in ev mode
    my $el;
    $c->find('h1', sub { $el = $_[0]; EV::break });
    { my $wd = EV::timer(10, 0, sub { EV::break }); EV::run; undef $wd }
    isa_ok($el, 'EV::WebKit::Client::Element', 'ev mode: find gives an element proxy, which');

    # calling without a callback in ev mode croaks: it cannot block, you own the loop
    my $ok = eval { $c->title; 1 };
    ok(!$ok && $@ =~ /callback is required/, 'ev mode: a call with no callback croaks');

    $c->disconnect;
}

$ctl->close;
$b->quit;
done_testing;
