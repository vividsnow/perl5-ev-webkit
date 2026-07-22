package TWK;
use v5.10; use strict; use warnings;
use Test::More;
use EV::WebKit ();

sub skip_unless_available {
    plan(skip_all => 'WebKit-6.0/Gtk-4.0 typelibs not available')
        unless EV::WebKit::available();
    plan(skip_all => 'no X display (run tests under `xvfb-run -a`)')
        unless defined $ENV{DISPLAY} && length $ENV{DISPLAY};
}

sub run_with_timeout {
    my ($secs) = @_;
    my $t = EV::timer($secs, 0, sub { fail("timeout after ${secs}s"); EV::break });
    EV::run;
}
1;
