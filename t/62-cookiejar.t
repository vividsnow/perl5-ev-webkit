use v5.10; use strict; use warnings;
use Test::More;
use File::Temp 'tempdir';
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;

# Cookie hybrid (see .superpowers/sdd/cookie-investigation-report.md):
#
# Part 1 -- native persistence (primary mechanism). cookie_jar => $file wires
# WebKitCookieManager::set_persistent_storage; WebKit itself writes/reads the
# jar, no explicit save/load call needed. Only non-session cookies (a real
# max_age) are ever written -- session cookies (no max_age) are correctly
# EXCLUDED by design (RFC 6265, same as every real browser). The investigation
# proved the "broken" verdict from an earlier attempt was a test bug: that
# test's cookie had no max_age, so it was a session cookie all along.
#
# Part 2 -- save_cookies/load_cookies remain as an explicit, opt-in JSON
# snapshot (per-URI get_cookies enumeration/replay -- get_all_cookies is
# still avoided: a real memory-safety bug was valgrind-confirmed when that
# call is left in-flight at teardown). Snapshots are the only way to capture
# SESSION cookies; expiry is not part of the snapshot (loaded back as session
# cookies).
#
# Two independent EV::WebKit instances per part simulate a save-then-restart
# cycle -- safe to run sequentially in one process thanks to the EV::Glib
# wedge fix (task 13a).
my $dir = tempdir(CLEANUP=>1);

# ===========================================================================
# Part 1: native persistence
# ===========================================================================
my $native_jar = "$dir/jar.sqlite";

# --- Instance A: one persistent cookie (max_age), one session cookie (no
#     max_age); tear down. ---
my $A = EV::WebKit->new(window=>[300,200], cookie_jar=>$native_jar);
my ($keep_err, $sess_err, $sess_ran);
$A->set_cookie({ name=>'keep', value=>'1', domain=>'jar.test', path=>'/', max_age=>3600 }, sub {
    (undef, $keep_err) = @_;
    if ($keep_err) { EV::break; return }
    $A->set_cookie({ name=>'sess', value=>'x', domain=>'jar.test', path=>'/' }, sub {
        (undef, $sess_err) = @_;
        $sess_ran = 1;
        EV::break;
    });
});
TWK::run_with_timeout(10);
ok(!$keep_err, 'set_cookie (persistent, max_age=>3600) did not error') or diag($keep_err);
ok(!$sess_err, 'set_cookie (session, no max_age) did not error') or diag($sess_err);
ok($sess_ran, 'session set_cookie callback ran');
$A->quit;
ok(-s $native_jar, 'native jar file exists and is non-empty after quit (no explicit save call)');

# --- Instance B: fresh browser, same jar -- native persistence auto-restores. ---
my $B = EV::WebKit->new(window=>[300,200], cookie_jar=>$native_jar);
my ($list, $list_err);
# cookies load asynchronously from disk; poll briefly (as in the original
# task-13 recipe -- see cookie-investigation-report.md Hypothesis B).
my $poll = EV::timer(0.5, 0, sub {
    $B->cookies('http://jar.test/', sub { ($list, $list_err) = @_; EV::break });
});
TWK::run_with_timeout(10);
ok(!$list_err, 'cookies() on instance B did not error') or diag($list_err);
my ($keep) = grep { $_->{name} eq 'keep' } @{ $list || [] };
my ($sess) = grep { $_->{name} eq 'sess' } @{ $list || [] };
ok($keep && $keep->{value} eq '1', 'keep=1 persisted natively, no explicit load call')
    or diag(explain($list));
ok(!$sess, 'sess (session cookie) is NOT present -- excluded from native persistence by design');
$B->quit;

# ===========================================================================
# Part 2: snapshot save/load (explicit, opt-in; captures session cookies too)
# ===========================================================================
my $snap = "$dir/snap.json";

# --- Instance C: plain ephemeral, no cookie_jar -- set a session cookie,
#     snapshot it to a file. ---
my $C = EV::WebKit->new(window=>[300,200]);
my ($save_count, $save_err);
$C->set_cookie({ name=>'snap', value=>'2', domain=>'jar.test', path=>'/' }, sub {
    my (undef, $set_err) = @_;
    if ($set_err) { $save_err = $set_err; EV::break; return }
    $C->save_cookies($snap, ['http://jar.test/'], sub { ($save_count, $save_err) = @_; EV::break });
});
TWK::run_with_timeout(10);
ok(!$save_err, 'set_cookie/save_cookies did not error') or diag($save_err);
ok($save_count, 'save_cookies reported a truthy count');
is($save_count, 1, 'save_cookies saved exactly the one cookie we set');
ok(-s $snap, 'snapshot file is non-empty');
$C->quit;

# --- Instance D: plain ephemeral -- load the snapshot; the session cookie
#     comes back (snapshots capture what native persistence excludes). ---
my $D = EV::WebKit->new(window=>[300,200]);
my ($loaded, $load_err, $list2, $cookies_err);
$D->load_cookies($snap, sub {
    ($loaded, $load_err) = @_;
    $D->cookies('http://jar.test/', sub { ($list2, $cookies_err) = @_; EV::break });
});
TWK::run_with_timeout(10);
ok(!$load_err, 'load_cookies did not error') or diag($load_err);
ok($loaded, 'load_cookies reported a truthy loaded count');
ok(!$cookies_err, 'cookies() did not error') or diag($cookies_err);
my ($snapc) = grep { $_->{name} eq 'snap' } @{ $list2 || [] };
ok($snapc && $snapc->{value} eq '2', 'snap=2 round-tripped through save_cookies/load_cookies (session cookie captured)');
$D->quit;

# ===========================================================================
# Part 3: native persistence with jar_format => 'text' (compact variant of
# Part 1 -- proves the format option is actually honored rather than always
# falling back to the sqlite default; a plain round-trip alone wouldn't
# distinguish the two, since sqlite would also round-trip the cookie).
# ===========================================================================
my $text_jar = "$dir/jar.txt";

my $F = EV::WebKit->new(window=>[300,200], cookie_jar=>$text_jar, jar_format=>'text');
my $tkeep_err;
$F->set_cookie({ name=>'tkeep', value=>'3', domain=>'jar.test', path=>'/', max_age=>3600 }, sub {
    (undef, $tkeep_err) = @_;
    EV::break;
});
TWK::run_with_timeout(10);
ok(!$tkeep_err, 'set_cookie (persistent, jar_format=>text) did not error') or diag($tkeep_err);
$F->quit;
ok(-s $text_jar, 'text-format jar file exists and is non-empty after quit');
open my $tfh, '<:raw', $text_jar or die "open $text_jar: $!";
my $text_bytes = do { local $/; <$tfh> };
close $tfh;
unlike($text_bytes, qr/^SQLite format 3/, 'text-format jar is not a sqlite file (format actually honored)');

my $G = EV::WebKit->new(window=>[300,200], cookie_jar=>$text_jar, jar_format=>'text');
my ($tlist, $tlist_err);
my $tpoll = EV::timer(0.5, 0, sub {
    $G->cookies('http://jar.test/', sub { ($tlist, $tlist_err) = @_; EV::break });
});
TWK::run_with_timeout(10);
ok(!$tlist_err, 'cookies() on fresh text-format instance did not error') or diag($tlist_err);
my ($tkeep) = grep { $_->{name} eq 'tkeep' } @{ $tlist || [] };
ok($tkeep && $tkeep->{value} eq '3', 'tkeep=3 persisted via text-format jar, no explicit load call')
    or diag(explain($tlist));
$G->quit;

# ===========================================================================
# Part 4: malformed snapshot rows are skipped (degrade), never fatal -- the
# comment on load_cookies promises "treat garbage as empty, not fatal", but
# that used to only cover the outer arrayref shape; individual rows that are
# non-hashref or missing a required key must be filtered out too, routing
# only well-formed rows through set_cookie.
# ===========================================================================
my $malformed_file = "$dir/malformed.json";
open my $mfh, '>:utf8', $malformed_file or die "open $malformed_file: $!";
print $mfh '["a","b",42]';   # every row is a non-hashref -- none of them loadable
close $mfh;

my $partial_file = "$dir/partial.json";
open my $pfh, '>:utf8', $partial_file or die "open $partial_file: $!";
print $pfh '[{"name":"good","value":"v","domain":"d.test","path":"/"},{"name":"bad","value":"v"}]';   # 2nd row missing domain
close $pfh;

my $H = EV::WebKit->new(window=>[300,200]);

my ($mcount, $merr);
$H->load_cookies($malformed_file, sub { ($mcount, $merr) = @_; EV::break });
TWK::run_with_timeout(10);
ok(!$merr, 'load_cookies on all-non-hashref rows did not error') or diag($merr);
is($mcount, 0, 'load_cookies skipped every non-hashref row (count=0)');

my ($pcount, $perr);
$H->load_cookies($partial_file, sub { ($pcount, $perr) = @_; EV::break });
TWK::run_with_timeout(10);
ok(!$perr, 'load_cookies on partially-malformed rows did not error') or diag($perr);
is($pcount, 1, 'load_cookies loaded only the one good row, skipped the row missing domain');

$H->quit;

# --- error paths (fresh instance, never navigated) ---
my $E = EV::WebKit->new(window=>[300,200]);

my $file_required_err;
my $file_required_ret = $E->save_cookies(undef, sub { $file_required_err = $_[1]; EV::break });
is($file_required_ret, $E, 'save_cookies without a file returns $b');
TWK::run_with_timeout(5);   # error delivery is deferred to a clean tick (uniform with every other early-error guard)
is($file_required_err, 'snapshot file required', 'save_cookies without a file errors');

my $no_uris_err;
$E->save_cookies("$dir/x.json", sub { $no_uris_err = $_[1]; EV::break });
TWK::run_with_timeout(5);
is($no_uris_err, 'no URIs to save (navigate first or pass a URI list)',
    'save_cookies with no URIs (fresh instance, no go()) errors');
$E->quit;

# data_dir persists cookies too (no cookie_jar): a cookie with an expiry set in
# one instance is read back by the next instance with the same data_dir.
{
    require File::Temp;
    my $ddir = File::Temp::tempdir(CLEANUP => 1);
    {
        my $a = EV::WebKit->new(window => [200,150], data_dir => "$ddir/s");
        my $se;
        $a->set_cookie({ name => 'dd', value => '77', domain => 'example.com', path => '/', max_age => 3600 },
                       sub { (undef, $se) = @_; EV::break });
        TWK::run_with_timeout(10);
        is($se, undef, 'data_dir: cookie set') or diag("err=" . ($se // ''));
        $a->quit;
    }
    { my $t = EV::timer(0.5, 0, sub { EV::break }); EV::run }
    my ($list, $ce);
    {
        my $b = EV::WebKit->new(window => [200,150], data_dir => "$ddir/s");
        $b->cookies('http://example.com/', sub { ($list, $ce) = @_; EV::break });
        TWK::run_with_timeout(10);
        $b->quit;
    }
    ok(scalar(grep { $_->{name} eq 'dd' && $_->{value} eq '77' } @{ $list || [] }),
        'data_dir persists cookies across instances (no cookie_jar needed)')
        or diag("err=" . ($ce // '') . " got " . scalar(@{ $list || [] }) . " cookies");
}

done_testing;
