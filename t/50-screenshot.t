use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit; use File::Temp 'tempdir';

my $dir = tempdir(CLEANUP=>1);
my $png = "$dir/shot.png";
my $b = EV::WebKit->new(window=>[320,240]);
my ($ok, $bytes, $full_bytes);

$b->load_html('<body style="background:#0a0"><h1>shot</h1></body>', sub {
    $b->screenshot($png, sub {
        my ($result, $err) = @_;
        $ok = !$err && (-s $png) > 0 && substr(`file "$png"`, 0, 5) ne 'Error';
        # Now test bytes mode
        $b->screenshot({bytes=>1}, sub {
            $bytes = $_[0];
            # Test full-document mode
            $b->screenshot({full=>1, bytes=>1}, sub {
                $full_bytes = $_[0];
                EV::break;
            });
        });
    });
});

TWK::run_with_timeout(10);

ok($ok, 'screenshot wrote a file');
is(substr($bytes, 0, 8), "\x89PNG\r\n\x1a\n", 'bytes are a PNG');
is(substr($full_bytes, 0, 8), "\x89PNG\r\n\x1a\n", 'full-document bytes are a PNG');

# screenshot({}, $cb): no path AND no bytes => must error clearly and
# asynchronously, not fall into `open ... undef` (uninitialized-value
# warnings, a confusing generic "open : ..." error).
my (@warnings, $noopt_err, $noopt_ret);
{
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $noopt_ret = $b->screenshot({}, sub { (undef, $noopt_err) = @_; EV::break });
    TWK::run_with_timeout(10);
}
is($noopt_ret, $b, 'screenshot({}) (no path, no bytes) returns $b');
is($noopt_err, 'screenshot path required (or bytes => 1)',
    'screenshot({}) (no path, no bytes) errors clearly');
my @uninit = grep { /uninitialized/ } @warnings;
is(scalar(@uninit), 0, 'screenshot({}) (no path, no bytes) emits no uninitialized-value warnings')
    or diag(explain(\@warnings));

# a write failure (disk full etc.) must be reported as an error, not silently
# swallowed while claiming success -- /dev/full's write(2) deterministically
# fails with ENOSPC regardless of how much data is written, so it forces the
# print/close path to actually fail without needing a real full filesystem.
SKIP: {
    skip '/dev/full not available/writable in this environment', 2
        unless -e '/dev/full' && -w '/dev/full';
    my $full_err;
    $b->screenshot('/dev/full', sub { (undef, $full_err) = @_; EV::break });
    TWK::run_with_timeout(10);
    ok(defined $full_err, 'screenshot write failure (/dev/full) is reported as an error')
        or diag('got a false success instead of an error');
    like($full_err // '', qr/write|full|space/i,
        'write-failure error message names the failure (not a generic/blank string)');
}

done_testing;
