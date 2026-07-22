use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit; use File::Temp 'tempdir';

my $b = EV::WebKit->new(window=>[300,200]);
my %got;
$b->load_html('<title>T</title><p id=p>hello</p>', sub {
    my $n = 0; my $done = sub { EV::break if ++$n == 6 };
    $b->script('return 1 + 2', sub { $got{num}  = $_[0]; $done->() });
    $b->script('return document.getElementById("p").textContent', sub { $got{str} = $_[0]; $done->() });
    $b->script('return [1,2,3]', sub { $got{arr} = $_[0]; $done->() });
    $b->script('return {a:1,b:[2,3],c:null}', sub { $got{obj} = $_[0]; $done->() });
    $b->script('throw new Error("boom")', sub { $got{err} = $_[1]; $done->() });
    $b->script_async('return 1', { bad => sub {} }, sub { $got{enc_err} = $_[1]; $done->() });
});
TWK::run_with_timeout(10);
is($got{num}, 3, 'number marshalled');
is($got{str}, 'hello', 'string marshalled');
is_deeply($got{arr}, [1,2,3], 'array marshalled');
is_deeply($got{obj}, {a=>1, b=>[2,3], c=>undef}, 'object marshalled (null -> undef)');
like($got{err}, qr/boom/, 'JS exception -> err');
like($got{enc_err}, qr/^encode error: /, 'unencodable args -> encode error');

# wait_for/screenshot/pdf use `my $cb = pop` with no coderef check, so a
# missing callback silently grabs a data argument (an options hash element or
# a path) as $cb instead -- which then dies with a useless "not a CODE
# reference" deep inside an unrelated later completion. Catch the misuse
# immediately and loudly (croak) instead.
my $tmp = tempdir(CLEANUP=>1);
my $unwanted_png = "$tmp/should-not-be-created.png";
my $unwanted_pdf = "$tmp/should-not-be-created.pdf";

eval { $b->wait_for('#p') };
like($@, qr/callback/i, 'wait_for without a callback croaks immediately');

eval { $b->screenshot($unwanted_png) };
like($@, qr/callback/i, 'screenshot without a callback croaks immediately');

eval { $b->pdf($unwanted_pdf) };
like($@, qr/callback/i, 'pdf without a callback croaks immediately');

ok(!-e $unwanted_png, 'screenshot croak happened before any file was written');
ok(!-e $unwanted_pdf, 'pdf croak happened before any file was written');

# _defer (which backs _call_js's completion, and so script/find/find_all/
# html) lacked _defer_final's `return unless $cb` guard, so a cb-less call on
# a live browser eventually ran `undef->(@a)` inside an EV timer callback.
# EV catches watcher-callback exceptions (unlike the GI-callback-argument
# crash in mock_scheme/finding 1) and routes them to $EV::DIED (default:
# warn) -- so this "only" produced ugly noise rather than crashing, but it
# is still a real bug this fix must silence.
my @caught;
{
    local $EV::DIED = sub { push @caught, "\$EV::DIED: $@" };
    $b->script('return 1');           # no callback at all -- must be a clean no-op
    my $t = EV::timer(0.5, 0, sub { EV::break });
    EV::run;
}
is(scalar(@caught), 0, 'script() with no callback does not trip $EV::DIED')
    or diag(explain(\@caught));

done_testing;
