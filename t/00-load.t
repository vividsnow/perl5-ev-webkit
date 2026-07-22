use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib';
require_ok('EV::WebKit') or BAIL_OUT('cannot load EV::WebKit');
ok(defined &EV::WebKit::available, 'available() defined');
like($EV::WebKit::VERSION, qr/\A\d+\.\d+\z/, 'version set');
done_testing;
