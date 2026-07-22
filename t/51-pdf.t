use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit; use File::Temp 'tempdir';

my $dir = tempdir(CLEANUP=>1);
my $pdf = "$dir/out.pdf";
my $b = EV::WebKit->new(window=>[400,300]);
my ($magic, $err);
$b->load_html('<h1>PDF</h1><p>'.('lorem '.'ipsum ' x 200).'</p>', sub {
    $b->pdf($pdf, sub {
        (my $p, $err) = @_;
        if (open my $fh,'<:raw',$pdf) { read $fh,$magic,5; close $fh }
        EV::break;
    });
});
TWK::run_with_timeout(15);
is($err, undef, 'no pdf error');
is($magic, '%PDF-', 'valid PDF produced');

# Finding 1 (r12): two pdf() calls overlapping in flight -- one targeting a
# directory with no write permission -- must not let WebKit's own 'finished'
# signal (fired for the WRONG/doomed op when two PrintOperations race) report
# a false success; pdf() must independently verify the file it claims to
# have written before resolving success.
SKIP: {
    skip 'cannot use permission bits to force a write failure when running as root', 4
        if $> == 0;
    my $dir2  = tempdir(CLEANUP=>1);
    my $rodir = "$dir2/readonly";
    mkdir $rodir or die $!;
    chmod 0500, $rodir or die $!;   # r-x------: cannot create a file inside

    my $b2 = EV::WebKit->new(window=>[300,200]);
    my ($bad_res, $bad_err, $good_res, $good_err, $pending);
    $pending = 2;
    $b2->load_html('<h1>hi</h1>', sub {
        $b2->pdf("$rodir/concurrent.pdf", sub { ($bad_res,  $bad_err)  = @_; EV::break unless --$pending; });
        $b2->pdf("$dir2/good2.pdf",       sub { ($good_res, $good_err) = @_; EV::break unless --$pending; });
    });
    TWK::run_with_timeout(20);
    chmod 0700, $rodir;   # let File::Temp CLEANUP unlink it
    $b2->quit;

    ok(defined $bad_err, 'overlapping pdf(): the doomed (unwritable-dir) call delivers a defined error')
        or diag("false success instead: res=" . (defined $bad_res ? "'$bad_res'" : 'undef'));
    ok(!-e "$rodir/concurrent.pdf", 'overlapping pdf(): no file was actually written for the doomed call');
    is($good_err, undef, 'overlapping pdf(): the valid concurrent call still succeeds');
    ok(-s "$dir2/good2.pdf", 'overlapping pdf(): the valid concurrent call really wrote a PDF');
}

done_testing;
