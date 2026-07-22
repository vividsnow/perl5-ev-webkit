use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

my $b = EV::WebKit->new(window => [400,300]);
my ($title, $err, $html, $html_err, $html_ret);
$b->load_html('<html><head><title>Hi</title></head><body><p>ok</p></body></html>', sub {
    (undef, $err) = @_;
    $title = $b->title;
    $html_ret = $b->html(sub {
        ($html, $html_err) = @_;
        EV::break;
    });
});
TWK::run_with_timeout(10);
is($err, undef, 'no nav error');
is($title, 'Hi', 'title read after load');
is($html_ret, $b, 'html returns $b');
is($html_err, undef, 'no html error');
like($html, qr{<p>ok</p>}, 'html contains body markup');
like($html, qr{^<html}i, 'html starts with <html');
done_testing;
