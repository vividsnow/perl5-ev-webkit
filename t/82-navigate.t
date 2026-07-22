use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

# on_load fires only for navigations the API started. A page that navigates
# ITSELF -- which is what a human clicking a link in a visible window looks like
# -- changed the page and told nobody: _finish_nav returns early when there is
# no pending nav. So the module could not report the one thing an interactive
# browser most obviously does.
#
# on_navigate reports every committed navigation, whoever caused it.

my (@nav, @load);
my $b = EV::WebKit->new(
    window      => [300,200], ephemeral => 1,
    on_navigate => sub { push @nav,  $_[0] },
    on_load     => sub { push @load, 'load' },
);
$b->mock_scheme('nv', sub {
    my $uri = shift;
    return ('<html><body><a id="lnk" href="nv://second">go</a></body></html>', 'text/html')
        if $uri =~ /first/;
    return ('<html><body><h1>SECOND</h1></body></html>', 'text/html');
});

# 1) an API navigation fires BOTH -- on_navigate is additive, on_load unchanged
$b->go('nv://first', sub { EV::break });
TWK::run_with_timeout(15);
for (1 .. 3) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run }   # let the settle tick land
is(scalar(@nav), 1, 'an API navigation fires on_navigate');
is($nav[0], 'nv://first', '...with the uri');
is(scalar(@load), 1, '...and on_load still fires (unchanged)');

# 2) a navigation the PAGE starts -- the human clicking a link
@nav = (); @load = ();
$b->script('document.getElementById("lnk").click()', sub { });
{ my $t = EV::timer(3, 0, sub { EV::break }); EV::run }
is(scalar(@nav), 1, 'a link click fires on_navigate (nothing used to fire at all)')
    or diag('the page changed and the caller was never told');
is($nav[0], 'nv://second', '...with the new uri');
is(scalar(@load), 0, '...and on_load does NOT (it means "the nav I started finished")');
is($b->uri, 'nv://second', 'sanity: the browser really did navigate');

# 3) load_html is a navigation too
@nav = ();
$b->load_html('<p>x</p>', sub { EV::break });
TWK::run_with_timeout(15);
is(scalar(@nav), 1, 'load_html fires on_navigate');

# 4) nothing after quit
@nav = ();
$b->quit;
for (1 .. 3) { my $t = EV::timer(0.05, 0, sub { EV::break }); EV::run }
is(scalar(@nav), 0, 'no on_navigate after quit');

done_testing;
