use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

# press / scroll (page level) and Element->box.
#
# One instance, one EV::run, queued steps (t/42's constraint).

my $b = EV::WebKit->new(window => [400, 300], timeout => 15);
my %g;
my @steps;
my $run; $run = sub { my $s = shift @steps or return EV::break; $s->() };

my $fixture = <<'HTML';
<style>
  body { margin: 0 }
  #tall { height: 3000px }
  #boxy { position: absolute; left: 40px; top: 60px; width: 120px; height: 30px }
  #hidden { display: none }
</style>
<input id=field>
<div id=boxy>box</div>
<div id=hidden>invisible</div>
<div id=tall></div>
<script>
  window.keys = [];
  document.addEventListener('keydown', e => window.keys.push(
      [e.key, e.keyCode, e.shiftKey ? 1 : 0, e.ctrlKey ? 1 : 0].join(':')));
  document.addEventListener('keypress', e => window.keys.push('press:' + e.key));
  // a handler that cancels, to prove press() reports cancellation
  document.getElementById('field').addEventListener('keydown', e => {
      if (e.key === 'x') e.preventDefault();
  });
</script>
HTML

# --- press: named key, with modifiers ---
push @steps, sub {
    $b->press('Escape', sub { ($g{esc}, $g{esc_err}) = @_; $run->() });
};
push @steps, sub {
    $b->press('Enter', shift => 1, ctrl => 1, sub { ($g{enter}) = @_; $run->() });
};
# a single character produces keypress as well as keydown/keyup
push @steps, sub {
    $b->press('a', sub { ($g{a}) = @_; $run->() });
};
push @steps, sub {
    $b->script('return JSON.stringify(window.keys)', sub { $g{keys} = $_[0]; $run->() });
};
# press does NOT type: the input's value stays empty
push @steps, sub {
    $b->script('document.getElementById("field").focus(); return 1;', sub {
        $b->press('z', sub {
            $b->script('return document.getElementById("field").value', sub {
                $g{typed} = $_[0]; $run->();
            });
        });
    });
};
# a cancelling handler makes press report false
push @steps, sub {
    $b->press('x', sub { ($g{cancelled}) = @_; $run->() });
};

# --- scroll ---
push @steps, sub {
    $b->scroll(y => 500, cb => sub { ($g{abs}) = @_; $run->() });
};
push @steps, sub {
    $b->scroll(by => 1, y => 100, cb => sub { ($g{rel}) = @_; $run->() });
};
push @steps, sub {
    $b->scroll(to => 'bottom', cb => sub { ($g{bottom}) = @_; $run->() });
};
push @steps, sub {
    $b->scroll(to => 'top', cb => sub { ($g{top}) = @_; $run->() });
};

# --- Element->box ---
push @steps, sub {
    $b->find('#boxy', sub {
        my ($el) = @_;
        $el->box(sub { ($g{box}, $g{box_err}) = @_; $run->() });
    });
};
push @steps, sub {
    $b->find('#hidden', sub {
        my ($el) = @_;
        $el->box(sub { ($g{hidden_box}, $g{hidden_err}) = @_; $run->() });
    });
};

$b->load_html($fixture, sub { $run->() });
TWK::run_with_timeout(40);

# --- press ---
ok($g{esc},      'press(Escape) reports not-cancelled');
is($g{esc_err}, undef, 'press: no error');
require Cpanel::JSON::XS;
my $keys = eval { Cpanel::JSON::XS::decode_json($g{keys} // '[]') } || [];
ok((grep { $_ eq 'Escape:27:0:0' } @$keys), 'the page saw Escape with keyCode 27');
ok((grep { $_ eq 'Enter:13:1:1' } @$keys),  'modifiers reach the page (shift+ctrl+Enter)');
ok((grep { $_ eq 'press:a' } @$keys),       'a character key also produces keypress');
ok(!(grep { $_ eq 'press:Escape' } @$keys), '...and a named key does NOT (as in a real browser)');

# The honest limitation, pinned so the POD cannot drift from it: a synthetic
# key event does not perform text insertion in any engine.
is($g{typed}, '', 'press does NOT type into an input (use Element->type)');
ok(!$g{cancelled}, 'press reports false when a handler calls preventDefault');

# --- scroll ---
is($g{abs}{y}, 500, 'scroll(y => 500) moves to an absolute offset');
is($g{rel}{y}, 600, 'scroll(by => 1, y => 100) is relative to the current offset');
cmp_ok($g{bottom}{y}, '>', 600, 'scroll(to => "bottom") reaches the document end');
is($g{top}{y}, 0,    'scroll(to => "top") returns to the origin');

# --- box ---
is($g{box_err}, undef, 'box: no error');
is($g{box}{left},   40,  'box reports the left offset');
is($g{box}{top},    60,  'box reports the top offset');
is($g{box}{width},  120, 'box reports the width');
is($g{box}{height}, 30,  'box reports the height');
ok(exists $g{box}{page_x}, 'box also carries page-relative coordinates');

# a display:none element has an all-zero rect in every browser; reporting that
# as a box would be a lie a caller could divide by
is($g{hidden_box}, undef, 'box is undef for an element that is not rendered');

# --- validation ---
{
    my $b2 = EV::WebKit->new(window => [200,150]);
    eval { $b2->press(undef, sub {}) };
    like($@, qr/key name is required/, 'press requires a key');
    eval { $b2->press('a', bogus => 1, sub {}) };
    like($@, qr/unknown option/, 'press rejects an unknown modifier');
    eval { $b2->scroll(nope => 1) };
    like($@, qr/unknown option/, 'scroll rejects an unknown option');
    eval { $b2->scroll(to => 'sideways') };
    like($@, qr/top.*bottom/, 'scroll validates the to option');
    $b2->quit;
}

done_testing;
