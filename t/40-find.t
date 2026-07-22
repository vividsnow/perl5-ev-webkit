use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

my $b = EV::WebKit->new(window=>[300,200]);
my ($h1, $missing, $missing_err, $count, $empty, $empty_err, $h1a_text, $h1b_text);
$b->load_html('<h1 class=x>A</h1><h1 class=x>B</h1><p>p</p>', sub {
    my $n=0; my $want=5; my $done = sub { EV::break if ++$n==$want };
    $b->find('h1', sub { $h1 = $_[0]; $done->() });
    $b->find('.none', sub { ($missing, $missing_err) = @_; $missing='SENTINEL' unless defined $missing; $done->() });
    $b->find_all('h1', sub {
        my $els = $_[0];
        $count = @$els;
        # identity, not just count: each returned handle must be wired to its
        # own distinct node, in document order -- not N aliases of one match.
        $els->[0]->text(sub { $h1a_text = $_[0]; $done->() });
        $els->[1]->text(sub { $h1b_text = $_[0]; $done->() });
    });
    $b->find_all('.none', sub { ($empty, $empty_err) = @_; $done->() });
});
TWK::run_with_timeout(10);
isa_ok($h1, 'EV::WebKit::Element', 'find returns Element');
is($missing, 'SENTINEL', 'missing selector -> undef element');
ok(!defined $missing_err, 'missing selector -> no error (not-found is not an error)');
is($count, 2, 'find_all count');
is($h1a_text, 'A', 'find_all[0] is the first element in document order');
is($h1b_text, 'B', 'find_all[1] is the second element in document order (distinct identity)');
is_deeply($empty, [], 'find_all no match -> empty arrayref');
ok(!defined $empty_err, 'find_all no match -> no error');
done_testing;
