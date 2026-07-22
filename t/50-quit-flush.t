use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;
use File::Temp qw(tempfile);
my (undef, $SAVE) = tempfile(UNLINK => 1);   # save_cookies was the ONE op family missing from this battery

# quit() must resolve EVERY in-flight async callback exactly once with
# 'browser closed', never silently drop it. Before this, only wait_for and
# navigation callbacks were flushed; an in-flight script/find/html/screenshot/
# cookie op had its GAsyncReadyCallback completion swallowed by _defer's
# dead-gate on quit -- a silent dropped callback that would hang a caller
# awaiting it. Each op below is fired and then quit() is called in the SAME
# tick, so the op is guaranteed still in flight when teardown happens.

my $b = EV::WebKit->new(window=>[200,200]);
$b->mock_scheme('q', sub { ('<html><body><div id="x">X</div></body></html>','text/html') });

my (%fired, %err, %count);
my $rec = sub { my ($label) = @_; return sub { my (undef,$e)=@_; $count{$label}++; $fired{$label}=1; $err{$label}=$e } };

my $ready = 0;
$b->go('q://p', sub {
    my (undef,$e)=@_;
    return EV::break if $e;
    $ready = 1;

    # A batch of DIFFERENT op families, all in flight, then quit() in the same tick.
    $b->find('#x',                       $rec->('find'));
    $b->find_all('div',                  $rec->('find_all'));
    $b->script('return 1;',              $rec->('script'));
    $b->script_async('return A.n;', {n=>7}, $rec->('script_async'));
    $b->html(                            $rec->('html'));
    $b->screenshot({bytes=>1},           $rec->('screenshot'));
    $b->cookies('http://example.com/',   $rec->('cookies'));
    $b->set_cookie({name=>'a',value=>'b',domain=>'example.com'}, $rec->('set_cookie'));
    $b->clear_cookies(                   $rec->('clear_cookies'));
    $b->save_cookies($SAVE, ['http://example.com/'], $rec->('save_cookies'));

    $b->quit;    # tear down while all ten are in flight

    # let any stray late completion try (and fail) to deliver a second time
    EV::timer(2, 0, sub { EV::break });
});

my $wd = EV::timer(25, 0, sub { EV::break });
EV::run;
undef $wd;

ok($ready, 'setup: navigated') or BAIL_OUT('no page');

my @ops = qw(find find_all script script_async html screenshot cookies set_cookie clear_cookies save_cookies);
for my $op (@ops) {
    ok($fired{$op}, "$op: in-flight callback fired after quit (not silently dropped)")
        or diag("$op callback never fired");
    # NB: this pins exactly-once AT QUIT -- it does not pin _op_track's dedupe guard
    # (quit clears {_ops} before firing, and _defer dead-gates the late real
    # completion, so no second fire can arrive by this route anyway). The dedupe is
    # load-bearing for the pdf watchdog instead -- see t/56 test 6, which is what
    # actually fails if it is removed.
    is($count{$op} // 0, 1, "$op: fired exactly once (no double-fire)")
        or diag("$op fired $count{$op} times");
    like($err{$op} // '', qr/browser closed/, "$op: resolved with 'browser closed'")
        or diag("$op err=" . ($err{$op} // '(undef)'));
}

# A second quit() must be a clean no-op (no re-flush, no crash).
eval { $b->quit; 1 } or fail('second quit() threw: ' . $@);
pass('second quit() is a clean no-op');

# load_cookies() delegates to N set_cookie() calls, each its own tracked op, so
# quit() flushes N+1 {_ops} entries in undefined order. The delegated ones must
# NOT let their aggregation deliver a fake (0-loaded, no-error) "success" ahead
# of load_cookies' own entry's 'browser closed'. Loop it: the pre-fix race
# surfaced ~8% of the time, so a batch reliably catches a regression.
{
    use File::Temp qw(tempfile);
    my ($jfh, $jar) = tempfile(UNLINK => 1);
    print $jfh '[', join(',', map {
        qq({"name":"c$_","value":"v$_","domain":"example.com","path":"/"})
    } 1..8), ']';
    close $jfh;

    my ($runs, $bad) = (24, 0);
    for my $i (1 .. $runs) {
        my $lb = EV::WebKit->new(window => [150, 150]);
        $lb->mock_scheme('lq', sub { ('<html><body>hi</body></html>', 'text/html') });
        my ($val, $err, $fired);
        my $settle;
        $lb->go('lq://p', sub {
            my (undef, $e) = @_;
            return EV::break if $e;
            $lb->load_cookies($jar, sub { ($val, $err) = @_; $fired++ });
            $lb->quit;   # tear down while the delegated set_cookie ops are in flight
            $settle = EV::timer(1, 0, sub { EV::break });
        });
        my $wd = EV::timer(15, 0, sub { EV::break });
        EV::run; undef $wd;
        $bad++ unless $fired && ($fired == 1) && (($err // '') =~ /browser closed/);
        diag("run $i: fired=".($fired//0)." val=".(defined $val?$val:'undef')." err=".($err//'undef'))
            unless $fired && $fired == 1 && (($err // '') =~ /browser closed/);
    }
    is($bad, 0, "load_cookies quit-teardown: all $runs runs resolved once with 'browser closed' (no fake-success race)");
}

done_testing;
