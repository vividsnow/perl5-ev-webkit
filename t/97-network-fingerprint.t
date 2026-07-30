use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;
plan skip_all => 'network_fingerprint needs Proxy::Impersonate'
    unless eval { require Proxy::Impersonate; 1 };
plan skip_all => 'network_fingerprint needs the fingerprint web-process extension'
    unless EV::WebKit->fingerprint_available;

# requires a fingerprint profile
eval { EV::WebKit->new(window => [400,300], network_fingerprint => 1) };
like($@, qr/network_fingerprint requires fingerprint/, 'croaks without a fingerprint profile');

# conflicts with an explicit proxy
eval { EV::WebKit->new(window => [400,300], fingerprint => 'windows-chrome',
                       network_fingerprint => 1, proxy => 'http://x:1') };
like($@, qr/network_fingerprint/, 'croaks when combined with an explicit proxy');

# the promised value check actually rejects. Rejecting only references let
# every other number through: 2 was silently treated as 1 (feature on, target
# derived), and 0.5 -- which contains a non-digit, so it read as an explicit
# target name -- was handed to Proxy::Impersonate as the target '0.5', surfacing
# as a confusing error from a layer further down. A real curl target has letters.
for my $bad (2, 42, 0.5, '007') {
    eval { EV::WebKit->new(window => [400,300], fingerprint => 'windows-chrome',
                           network_fingerprint => $bad) };
    like($@, qr/must be 1 or a curl-target string/,
         "network_fingerprint => $bad is rejected, not silently reinterpreted");
}

# enabled: derives the target, spins an in-process proxy, reports the port
my $b = EV::WebKit->new(window => [400,300],
    fingerprint => 'windows-chrome', network_fingerprint => 1);
is($b->network_fingerprint, 'chrome131', 'derived curl target from the profile');
ok($b->proxy_port, 'proxy_port is set (in-process proxy bound)');

# explicit override
my $b2 = EV::WebKit->new(window => [400,300],
    fingerprint => 'windows-chrome', network_fingerprint => 'chrome124');
is($b2->network_fingerprint, 'chrome124', 'explicit target override honored');

# off by default
my $b3 = EV::WebKit->new(window => [400,300], fingerprint => 'windows-chrome');
is($b3->network_fingerprint, undef, 'off unless requested');
is($b3->proxy_port, undef, 'no proxy when off');

# teardown is clean (proxy shut down)
$b->quit;
is($b->proxy_port, undef, 'proxy_port cleared after quit');
is($b->network_fingerprint, undef, 'network_fingerprint cleared after quit');
$_->quit for $b2, $b3;
done_testing;
