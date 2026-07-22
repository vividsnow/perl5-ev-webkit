use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

my $b = EV::WebKit->new(window=>[300,200]);
my ($found, $err2, $visible_found, $visible_err, $visible_before_show);
$b->load_html('<div id=host></div>'
            . '<div id=hidden style="display:none">hidden</div>'
            . '<script>'
            . 'setTimeout(()=>{'
            . '  document.getElementById("host").innerHTML="<b id=late>x</b>";'
            . '},300);'
            . 'setTimeout(()=>{'
            . '  document.getElementById("hidden").style.display="block";'
            . '},400);'
            . '</script>', sub {
    my $n = 0;
    my $done = sub { EV::break if ++$n == 3 };

    # Test 1: element appears late, wait_for resolves
    $b->wait_for('#late', timeout=>5, sub {
        my ($el) = @_;
        $el->tag(sub {
            $found = $_[0];
            $done->();
        });
    });

    # Test 2: selector never matches, timeout fires
    $b->wait_for('#never', timeout=>1, sub {
        ($visible_err) = $_[1] // (); # capture only the error
        $err2 = $_[1];
        $done->();
    });

    # Test 3: element exists but hidden, visible=>1 doesn't resolve until shown
    $b->wait_for('#hidden', visible=>1, timeout=>5, sub {
        my ($el) = @_;
        $visible_found = 1;
        $el->is_visible(sub {
            $visible_before_show = $_[0];
            $done->();
        });
    });
});
TWK::run_with_timeout(12);
is($found, 'b', 'wait_for resolved late element');
is($err2, 'timeout', 'wait_for times out for absent selector');
is($visible_found, 1, 'wait_for with visible=>1 resolved when element became visible');
is($visible_before_show, 1, 'element is visible when callback fires');

# --- regression: wait_for(interval=>0 or negative) must not busy-loop and
# starve the EV loop. $elapsed never advances when interval<=0, so the
# deadline check never trips and wait_for re-polls on a zero-delay timer
# forever; a non-positive interval must instead snap to the default at parse
# time. Each case gets its own bounded watchdog -- distinct from
# TWK::run_with_timeout's suite-wide one -- so a pre-fix regression fails
# fast with a clear "didn't resolve on its own" diagnosis instead of quietly
# riding out the whole suite's timeout (confirmed live: pre-fix, the
# callback only ever fires via quit()'s teardown path with 'browser closed',
# never with 'timeout', so it must not be allowed to reach that path here).
for my $case ([0, 'interval=>0'], [-1, 'interval=>-1']) {
    my ($interval, $label) = @$case;
    my $W = EV::WebKit->new(window=>[300,200]);
    my $ready = 0;
    $W->load_html('<div id=host></div>', sub { $ready = 1; EV::break });
    TWK::run_with_timeout(10);
    ok($ready, "$label: page ready");

    my ($werr, $watchdog_fired, $took);
    my $watchdog = EV::timer(6, 0, sub { $watchdog_fired = 1; EV::break });
    my $t0 = EV::time;
    $W->wait_for('#never', interval=>$interval, timeout=>1, sub {
        (undef, $werr) = @_;
        EV::break;
    });
    EV::run;
    $took = EV::time - $t0;
    undef $watchdog;

    ok(!$watchdog_fired, "$label: wait_for resolved on its own (no busy-loop hang)");
    is($werr, 'timeout', "$label: wait_for resolves 'timeout', not a hang");
    ok($took < 2.5, "$label: resolved quickly (took ${took}s), confirms no busy-loop stall")
        if defined $werr;
    $W->quit;
}

# --- regression: wait_for's visible=>1 poll must propagate a REAL is_visible
# error instead of silently treating it as "not visible yet" and surfacing a
# misleading plain 'timeout' much later. is_visible is made to throw a real
# script error on demand, still through the actual _call_js/GI/JS-error
# pipeline (only the JS snippet is substituted -- not the delivery mechanism,
# and not the assertion).
{
    my $b = EV::WebKit->new(window=>[300,200]);
    $b->load_html('<div id="x" style="display:none">hi</div>', sub { EV::break });
    TWK::run_with_timeout(10);

    no warnings 'redefine';
    local *EV::WebKit::Element::is_visible = sub {
        my ($el, $cb) = @_;
        $el->_call_js('throw new Error("kaboom (forced for test)");', {}, $cb);
    };

    my ($res_el, $res_err, $took);
    my $t0 = EV::time;
    $b->wait_for('#x', visible => 1, timeout => 1, sub {
        ($res_el, $res_err) = @_;
        $took = EV::time - $t0;
        EV::break;
    });
    TWK::run_with_timeout(10);

    is($res_el, undef, 'wait_for: is_visible error -> no element result');
    like($res_err // '', qr/kaboom/, 'wait_for: is_visible error propagates as the real error, not swallowed into timeout')
        or diag("res_err=" . ($res_err // 'u'));
    ok((defined $took && $took < 0.5), 'wait_for: resolved promptly on the is_visible error (did not ride out the full timeout)')
        or diag("took=" . ($took // 'u'));

    $b->quit;
}

# --- ...but a STALE element is NOT a real error here, and must NOT end the
# wait. visible=>1 needs two round-trips (find(), then is_visible() on that
# handle), and the page can change the node in between -- __evwk.get throws
# 'stale element' both when the node was detached (isConnected false) and when
# the page navigated (epoch mismatch). Either way it is transient with respect
# to the poll loop, because the NEXT tick does a fresh find(): treating it as
# terminal made wait_for(visible=>1) fail outright on any page that re-renders
# the node it is waiting for -- exactly the pages wait_for exists for. Poll
# through it; if the element never settles, the honest answer is 'timeout'.
{
    my $b = EV::WebKit->new(window=>[300,200]);
    $b->load_html('<div id="x">hi</div>', sub { EV::break });
    TWK::run_with_timeout(10);

    my $throws = 3;    # go stale for the first few polls, then settle
    no warnings 'redefine';
    local *EV::WebKit::Element::is_visible = sub {
        my ($el, $cb) = @_;
        return $el->_call_js('throw new Error("stale element");', {}, $cb) if $throws-- > 0;
        $el->_call_js('return true;', {}, $cb);
    };

    my ($res_el, $res_err);
    $b->wait_for('#x', visible => 1, timeout => 5, sub { ($res_el, $res_err) = @_; EV::break });
    TWK::run_with_timeout(15);

    is($res_err, undef, 'wait_for: a stale handle mid-poll is not an error -- it keeps polling')
        or diag("res_err=" . ($res_err // 'u') . " (a churning page must not break wait_for)");
    ok($res_el, '...and it resolves once the element settles');
    ok($throws <= 0, '...having actually gone through the stale polls');

    $b->quit;
}

done_testing;
