use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use File::Temp qw(tempdir);
use EV; use EV::WebKit;

# t/45-lifecycle.t pins the EV::Glib wedge for ONE path: _call_js/script().
# Every other op family has its OWN completion (its own _defer call site, or a
# settle timer) -- and if any of them ever delivers its callback straight from
# WebKit's GLib dispatch frame instead of a clean EV tick, a caller's EV::break
# in that callback unwinds out of ev_run from inside the frame and wedges every
# SUBSEQUENT EV::run into a permanent 100%-CPU spin. Mutation testing proved the
# suite was blind to this: firing clear_cookies' callback synchronously left
# every assertion passing and simply HUNG the run.
#
# For each op family: chain N sequential calls inside one EV::run, ending in
# EV::break from the innermost callback (the shape that arms the wedge), then
# demand a second, fully independent EV::run still completes.
#
# Each family runs in a CHILD under `timeout`, because an armed wedge SPINS
# rather than failing -- no in-process watchdog can rescue it (not even an
# unrelated native EV::timer ever fires again). Killing the child turns that
# hang into an ordinary failing assertion instead of a suite that never returns.

my $TIMEOUT = 90;
my $N       = 20;    # comfortably over the ~13 round-trips that armed it for _call_js
my $dir     = tempdir(CLEANUP => 1);
my $jar     = "$dir/jar.json";

my @OPS = (
    ['cookies'       => q{ $b->cookies('http://example.com/', $cb) }],
    ['set_cookie'    => q{ $b->set_cookie({ name=>'a', value=>'b', domain=>'example.com' }, $cb) }],
    ['clear_cookies' => q{ $b->clear_cookies($cb) }],
    ['save_cookies'  => q{ $b->save_cookies($JAR, ['http://example.com/'], $cb) }],
    ['load_cookies'  => q{ $b->load_cookies($JAR, $cb) }],
    ['screenshot'    => q{ $b->screenshot({ bytes => 1 }, $cb) }],
    ['load_html'     => q{ $b->load_html('<p id=p>x</p>', $cb) }],   # the nav settle-timer path
    ['find'          => q{ $b->find('#p', $cb) }],
    ['html'          => q{ $b->html($cb) }],
);

for my $op (@OPS) {
    my ($name, $call) = @$op;

    my $script = "$dir/wedge-$name.pl";
    open my $fh, '>', $script or die $!;
    print $fh <<"CHILD";
use v5.10; use strict; use warnings; \$| = 1;
use EV; use EV::WebKit;
my \$JAR = '$jar';
my \$b = EV::WebKit->new(window => [200,150], ephemeral => 1);
my \$ready = 0;
\$b->load_html('<p id=p>hi</p>', sub { \$ready = 1; EV::break });
my \$g = EV::timer(20, 0, sub { EV::break }); EV::run; undef \$g;
die "setup: no page\\n" unless \$ready;

my \$n = 0;
my \$chain; \$chain = sub {
    my \$cb = sub {
        \$n++;
        if (\$n >= $N) { EV::break }     # ends EV::run #1 from deep inside the chain
        else          { \$chain->() }
    };
    $call;
};
\$chain->();
my \$g2 = EV::timer(60, 0, sub { EV::break }); EV::run; undef \$g2; undef \$chain;
print "ROUNDTRIPS \$n\\n";

# The real assertion: a second, fully independent EV::run. Under an armed wedge
# this never returns -- not even its own timer fires -- so the parent's `timeout`
# is what ends us, and it reports as a failure rather than a hang.
my \$alive = 0;
my \$t = EV::timer(0.05, 0, sub { \$alive = 1; EV::break });
EV::run;
print "WEDGE-FREE\\n" if \$alive;
\$b->quit;
CHILD
    close $fh;

    my $out = `timeout --kill-after=5 $TIMEOUT $^X -Ilib $script 2>/dev/null`;
    my $rc  = $? >> 8;

    my ($n) = $out =~ /^ROUNDTRIPS (\d+)$/m;
    is($n, $N, "$name: $N sequential round-trips completed in one EV::run")
        or diag("child exit=$rc");
    ok($out =~ /^WEDGE-FREE$/m && $rc == 0,
        "$name: a second, independent EV::run still completes (no EV::Glib wedge)")
        or diag($rc == 124 || $rc == 137
            ? "child had to be KILLED: the loop wedged (this op delivered its callback inside a GLib dispatch frame)"
            : "child exit=$rc, output: $out");
}


# --- the OTHER half of the wedge: quit() called from inside a dispatch frame.
#
# FOUR handlers run user code nested inside WebKit's own frame, and quit() must
# detect that and defer its teardown in every one of them -- otherwise it
# delivers other ops' callbacks in that frame, and an EV::break from one of them
# wedges the loop. Only two of the four were ever covered; deleting the
# $IN_DISPATCH line from on_policy or on_console left the entire suite green
# while the loop wedged. Cover all four, in children, for the same reason as
# above: an armed wedge spins forever instead of failing.
{
    my @FRAMES = (
        # name          | how the browser is built           | what triggers the frame
        ['on_dialog',  q{on_dialog  => sub { $HIT->(); $_[0]->dismiss }},
                       q{$b->mock_scheme('f', sub { ('<html><body><script>confirm("x")</script>hi</body></html>','text/html') }); $b->go('f://p', sub {})}],
        ['on_policy',  q{on_policy  => sub { $HIT->(); $_[0]->allow }},
                       q{$b->mock_scheme('f', sub { ('<html><body>hi</body></html>','text/html') }); $b->go('f://p', sub {})}],
        ['on_console', q{on_console => sub { $HIT->() }},
                       q{$b->mock_scheme('f', sub { ('<html><body><script>console.log("x")</script>hi</body></html>','text/html') }); $b->go('f://p', sub {})}],
        ['mock_scheme producer', q{},
                       q{$b->mock_scheme('f', sub { $HIT->(); ('<html><body>hi</body></html>','text/html') }); $b->go('f://p', sub {})}],
    );

    for my $f (@FRAMES) {
        my ($name, $ctor, $trigger) = @$f;
        (my $file = $name) =~ s/\W+/-/g;
        my $script = "$dir/frame-$file.pl";
        open my $fh, '>', $script or die $!;
        print $fh <<"CHILD";
use v5.10; use strict; use warnings; \$| = 1;
use EV; use EV::WebKit;
my (\$in_frame, \$saw, \$fired, \$err, \$done) = (0, 0, 0);
our \$b;
my \$HIT = sub {
    return if \$done++;          # these handlers can re-enter; quit() once
    \$in_frame = 1;
    \$b->quit;                   # <-- from inside WebKit's dispatch frame
    \$in_frame = 0;
};
\$b = EV::WebKit->new(window => [300,200], ephemeral => 1, $ctor);
\$b->wait_for('#never', timeout => 30, sub {
    \$fired++; \$err = \$_[1];
    \$saw = \$in_frame;           # 1 => delivered nested INSIDE the frame
    EV::break;                   # documented safe here -- and must stay safe
});
$trigger;
my \$wd = EV::timer(20, 0, sub { EV::break }); EV::run; undef \$wd;
print "FIRED \$fired\\n";
print "ERR ", (\$err // '(undef)'), "\\n";
print "NESTED \$saw\\n";
my \$alive = 0;
my \$t = EV::timer(0.05, 0, sub { \$alive = 1; EV::break });
EV::run;                          # under an armed wedge this NEVER returns
print "WEDGE-FREE\\n" if \$alive;
CHILD
        close $fh;

        my $out = `timeout --kill-after=5 $TIMEOUT $^X -Ilib $script 2>/dev/null`;
        my $rc  = $? >> 8;
        like($out, qr/^FIRED 1$/m, "quit() from $name: the in-flight callback still resolves exactly once");
        like($out, qr/^NESTED 0$/m, "quit() from $name: ...on a clean tick, not nested in the frame");
        ok($out =~ /^WEDGE-FREE$/m && $rc == 0, "quit() from $name: the event loop is not wedged")
            or diag($rc == 124 || $rc == 137
                ? "child had to be KILLED: quit() from $name wedged the loop (is this handler marked as a dispatch frame?)"
                : "child exit=$rc, output: $out");
    }
}

done_testing;
