use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

my $b = EV::WebKit->new(window=>[300,200]);
my %g;
my $fixture = '<div id=d data-k="v"><span class=s>hi</span><span class=s>yo</span>'
            . '<b style="display:none">x</b></div><input id=inp value="v0">';
$b->load_html($fixture, sub {
    my $n=0; my $want=11; my $done = sub { EV::break if ++$n==$want };
    $b->find('#inp', sub { $_[0]->value(sub { $g{value}=$_[0]; $done->() }) });
    $b->find('#d', sub {
        my ($d) = @_;
        $d->tag(sub            { $g{tag}=$_[0];  $done->() });
        $d->attr('data-k', sub { $g{attr}=$_[0]; $done->() });
        $d->prop('id', sub     { $g{prop}=$_[0]; $done->() });
        $d->html(sub           { $g{html}=$_[0]; $done->() });
        $d->find('span', sub   { my ($el)=@_; $g{scoped_isa}=ref $el; $el->text(sub { $g{span}=$_[0]; $done->() }) });
        $d->find('.none', sub  { ($g{sf_el}, $g{sf_err}) = @_; $g{sf_el}='NONE' unless defined $g{sf_el}; $done->() });
        $d->find_all('span', sub {
            my $spans = $_[0];
            $g{fa}=scalar @$spans;
            # identity, not just count: distinct nodes in document order.
            $spans->[0]->text(sub { $g{span0}=$_[0]; $done->() });
            $spans->[1]->text(sub { $g{span1}=$_[0]; $done->() });
        });
        $d->find_all('.none', sub { ($g{fa_empty}, $g{fa_empty_err}) = @_; $done->() });
        $d->find('b', sub      { $_[0]->is_visible(sub { $g{hidden}=$_[0]; $done->() }) });
    });
});
TWK::run_with_timeout(12);
is($g{tag}, 'div', 'tag lowercased');
is($g{attr}, 'v', 'attr read');
is($g{prop}, 'd', 'prop(id) read');
like($g{html}, qr{<span[^>]*>hi</span>}, 'html returns innerHTML');
is($g{value}, 'v0', 'value read from input');
is($g{scoped_isa}, 'EV::WebKit::Element', 'scoped find returns Element');
is($g{span}, 'hi', 'scoped find + text (first match)');
is($g{sf_el}, 'NONE', 'scoped find not-found -> undef element');
ok(!defined $g{sf_err}, 'scoped find not-found -> no error');
is($g{fa}, 2, 'scoped find_all count');
is($g{span0}, 'hi', 'scoped find_all[0] is the first span in document order');
is($g{span1}, 'yo', 'scoped find_all[1] is the second span in document order (distinct identity)');
is_deeply($g{fa_empty}, [], 'scoped find_all no match -> empty arrayref');
ok(!defined $g{fa_empty_err}, 'scoped find_all no match -> no error');
ok(!$g{hidden}, 'display:none -> not visible');
done_testing;
