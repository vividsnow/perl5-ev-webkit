use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

my $b = EV::WebKit->new(window=>[300,200]);
$b->mock_scheme('mock', sub {
    my ($uri) = @_;
    my ($n) = $uri =~ m{mock://(\w+)};
    return ("<html><head><title>$n</title></head><body>$n</body></html>", 'text/html');
});

ok(!$b->can_go_back,    'fresh: cannot go back');
ok(!$b->can_go_forward, 'fresh: cannot go forward');
is($b->stop, $b, 'stop is callable and returns self');

my %g;
$b->back(sub {                                # nothing to go back to -> error, not a hang
    $g{noback_err} = $_[1];
    $b->go('mock://one', sub {
        $b->go('mock://two', sub {
            $g{cgb_after_two} = $b->can_go_back;
            $g{cgf_after_two} = $b->can_go_forward;
            $b->back(sub {
                my (undef, $err) = @_;
                $g{back_err}       = $err;
                $g{uri_after_back} = $b->uri;
                $g{cgf_after_back} = $b->can_go_forward;
                $b->forward(sub {
                    $g{uri_after_forward} = $b->uri;
                    $b->reload(sub {
                        my (undef, $rerr) = @_;
                        $g{reload_err}       = $rerr;
                        $g{uri_after_reload} = $b->uri;
                        $b->forward(sub { $g{nofwd_err} = $_[1]; EV::break });
                    });
                });
            });
        });
    });
});
TWK::run_with_timeout(25);
is($g{noback_err}, 'cannot go back', 'back with empty history -> error');
ok($g{cgb_after_two},  'can_go_back after two navigations');
ok(!$g{cgf_after_two}, 'cannot go forward at newest entry');
is($g{back_err}, undef, 'back resolved without error');
is($g{uri_after_back}, 'mock://one', 'back landed on first page');
ok($g{cgf_after_back}, 'can_go_forward true after going back');
is($g{uri_after_forward}, 'mock://two', 'forward landed on second page');
is($g{reload_err}, undef, 'reload resolved without error');
is($g{uri_after_reload}, 'mock://two', 'reload stays on second page');
is($g{nofwd_err}, 'cannot go forward', 'forward at newest entry -> error');

# overlapping navigations: issuing a second go() before the first settles
# supersedes the first. Deterministic -- the supersede happens synchronously
# inside _start_nav (called from go(), before EV::run is ever entered here),
# not dependent on WebKit's own load timing.
my ($sup_result, $sup_err, $two_result, $two_err, $two_uri);
$b->go('mock://three', sub { ($sup_result, $sup_err) = @_ });
$b->go('mock://four', sub {
    ($two_result, $two_err) = @_;
    $two_uri = $b->uri;
    EV::break;
});
TWK::run_with_timeout(10);
is($sup_err, 'superseded', 'overlapping nav: superseded callback receives err eq superseded');
is($sup_result, undef, 'overlapping nav: superseded callback result is undef');
is($two_err, undef, 'overlapping nav: second (superseding) callback completes without error');
is($two_uri, 'mock://four', 'overlapping nav: second callback lands on the second uri');

done_testing;
