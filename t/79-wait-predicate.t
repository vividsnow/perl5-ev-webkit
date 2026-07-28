use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

# wait_for(gone => 1) and wait_for_js.
#
# Both run on the same polling engine as wait_for -- extracted rather than
# copied, so the weak-alias / waiter-registry / single-resolution-point
# invariants have exactly one home. t/43, t/44, t/50 and friends still cover
# that engine through wait_for itself.
#
# One instance, one EV::run, queued steps (t/42's constraint).

my $b = EV::WebKit->new(window => [300, 200], timeout => 10);
my %g;
my @steps;
my $run; $run = sub { my $s = shift @steps or return EV::break; $s->() };

my $fixture = <<'HTML';
<div id=spinner>loading</div>
<script>
  window.appReady = false;
  setTimeout(() => { document.getElementById('spinner').remove(); }, 150);
  setTimeout(() => { window.appReady = true; }, 200);
  setTimeout(() => { window.late = { ready: true }; }, 250);
</script>
HTML

# --- gone: waits for the selector to match nothing ---
push @steps, sub {
    my $t0 = time;
    $b->wait_for('#spinner', gone => 1, sub {
        my ($ok, $err) = @_;
        $g{gone_ok}  = $ok;
        $g{gone_err} = $err;
        $g{gone_took} = time - $t0;
        $run->();
    });
};

# ...and returns immediately when it already matches nothing
push @steps, sub {
    $b->wait_for('#never-existed', gone => 1, sub {
        ($g{absent_ok}, $g{absent_err}) = @_;
        $run->();
    });
};

# ...and times out when the element STAYS
push @steps, sub {
    $b->wait_for('body', gone => 1, timeout => 0.3, sub {
        ($g{stays_ok}, $g{stays_err}) = @_;
        $run->();
    });
};

# --- wait_for_js: a predicate that becomes true ---
push @steps, sub {
    $b->wait_for_js('window.appReady', sub {
        ($g{js_val}, $g{js_err}) = @_;
        $run->();
    });
};

# A predicate that THROWS until it does not: `window.late.ready` is a TypeError
# for as long as window.late is undefined. This is the case that makes
# retry-on-throw mandatory -- failing on it would make the common shape unusable.
#
# The scheduling is deliberate and load-bearing. An earlier version armed this
# in the page fixture, and by the time the queued steps reached it the timer had
# long since fired, so the predicate NEVER threw and the assertion passed
# vacuously -- proven by mutation: making a throw terminal did not fail it.
# Arming it here, immediately before the wait, guarantees the throwing window.
push @steps, sub {
    $b->script('delete window.late; setTimeout(() => { window.late = { ready: true } }, 200); return 1;', sub {
        # confirm it really is throwing right now, so the assertion below cannot
        # go vacuous again without this failing first
        $b->script('try { return window.late.ready === undefined ? "no-throw" : "no-throw" } catch (e) { return "throws" }', sub {
            $g{throw_state} = $_[0];
            $b->wait_for_js('window.late.ready', sub {
                ($g{throw_val}, $g{throw_err}) = @_;
                $run->();
            });
        });
    });
};

# a predicate that never comes true: times out, and the message names the
# expression rather than saying a bare 'timeout'
push @steps, sub {
    $b->wait_for_js('window.nope === 42', timeout => 0.3, sub {
        ($g{never_val}, $g{never_err}) = @_;
        $run->();
    });
};

# a predicate that always throws: also times out, but the message carries the
# last JS error -- otherwise a typo is indistinguishable from "not yet"
push @steps, sub {
    $b->wait_for_js('no_such_function()', timeout => 0.3, sub {
        ($g{bad_val}, $g{bad_err}) = @_;
        $run->();
    });
};

$b->load_html($fixture, sub { $run->() });
TWK::run_with_timeout(40);

# --- gone ---
ok($g{gone_ok},        'wait_for(gone) resolves once the element is removed');
is($g{gone_err}, undef, 'wait_for(gone): no error');
ok($g{absent_ok},      'wait_for(gone) resolves immediately if it never matched');
is($g{absent_err}, undef, '...with no error');
ok(!$g{stays_ok},      'wait_for(gone) does NOT resolve while the element stays');
is($g{stays_err}, 'timeout', '...it times out');

# --- wait_for_js ---
ok($g{js_val},          'wait_for_js resolves when the predicate becomes true');
is($g{js_err}, undef,   'wait_for_js: no error');
is($g{throw_state}, 'throws',
   'precondition: the predicate really was throwing when the wait started');
ok($g{throw_val},       'wait_for_js polls THROUGH a throwing predicate (window.late.ready)');
is($g{throw_err}, undef, '...and reports no error once it succeeds');

is($g{never_val}, undef, 'a predicate that never holds does not resolve truthily');
like($g{never_err} // '', qr/timeout waiting for: window\.nope === 42/,
     'the timeout message names the expression, not a bare "timeout"');

like($g{bad_err} // '', qr/timeout waiting for/, 'an always-throwing predicate times out');
like($g{bad_err} // '', qr/last JS error/,
     '...and the message carries the last JS error, so a typo is diagnosable');

# --- validation ---
{
    my $b2 = EV::WebKit->new(window => [200,150]);
    eval { $b2->wait_for('#x', gone => 1, visible => 1, sub {}) };
    like($@, qr/mutually exclusive/, 'gone and visible together croak');
    eval { $b2->wait_for_js(undef, sub {}) };
    like($@, qr/expression is required/, 'wait_for_js requires an expression');
    eval { $b2->wait_for_js('1', 'not-a-code-ref') };
    like($@, qr/must be a callback/, 'wait_for_js requires a callback');
    $b2->quit;
}

done_testing;
