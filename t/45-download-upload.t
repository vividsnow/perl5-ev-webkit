use v5.10; use strict; use warnings;
use Test::More;
use lib 't/lib'; use TWK; TWK::skip_unless_available();
use EV; use EV::WebKit;
use File::Temp qw(tempdir);
use File::Spec;
use IO::Socket::INET;

# download() / on_download / on_file_chooser.
#
# Downloads are driven through download(), not by hoping a server sends
# something WebKit refuses to render: download_uri always produces a download,
# so the real signal path (download-started -> decide-destination -> finished)
# is exercised deterministically.
#
# The body is served over a real (in-process, non-blocking) HTTP socket rather
# than mock_scheme, because a download does NOT go through the custom-scheme
# handler: mock_scheme is registered on the WebContext, while downloads run on
# the NetworkSession, which has never heard of the scheme and answers "The URL
# can't be shown". file:// does not work either -- it produces no download at
# all. Same in-process EV::io server shape as t/63-proxy.t and xt/66.

my $dir = tempdir(CLEANUP => 1);

my $srv = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0,
                                Listen => 5, ReuseAddr => 1)
    or plan skip_all => "cannot bind a test server socket: $!";
my $port = $srv->sockport;
my %conns;
my $accept_io = EV::io($srv, EV::READ, sub {
    my $c = $srv->accept or return;
    $c->blocking(0);
    my $buf = '';
    my $rw; $rw = EV::io($c, EV::READ, sub {
        my $n = sysread($c, my $chunk, 4096);
        if (!defined $n) { return if $!{EAGAIN} || $!{EWOULDBLOCK}; delete $conns{$c}; return }
        return delete $conns{$c} unless $n;
        $buf .= $chunk;
        return unless $buf =~ /\r?\n\r?\n/;
        delete $conns{$c};
        my $body = 'HELLO-DOWNLOAD';
        print $c "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
               . "Content-Disposition: attachment; filename=\"served.bin\"\r\n"
               . "Content-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
        close $c;
    });
    $conns{$c} = $rw;
});
my $URL = "http://127.0.0.1:$port/served.bin";

# --- 1) download() writes the body to the path we asked for ---
{
    my $b = EV::WebKit->new(window => [200, 150]);
    my $dest = File::Spec->catfile($dir, 'one.bin');
    my ($got_path, $got_err);
    $b->download($URL, $dest, sub { ($got_path, $got_err) = @_; EV::break });
    TWK::run_with_timeout(20);
    $b->quit;

    is($got_err, undef, 'download: no error') or diag('err=' . ($got_err // 'undef'));
    is($got_path, $dest, 'download: callback reports the destination path');
    ok(-e $dest, 'download: the file exists');
    my $body = -e $dest ? do { open my $fh, '<', $dest or die $!; local $/; <$fh> } : '';
    is($body, 'HELLO-DOWNLOAD', 'download: the body landed on disk intact');
}

# --- 2) a page-initiated download whose handler names NO destination is
# cancelled, not written somewhere unasked. WebKit's own default would drop it
# in the user's Downloads directory behind the caller's back. ---
{
    my $b = EV::WebKit->new(window => [200, 150]);
    my ($seen_uri, $err);
    $b->on_download(sub { $seen_uri = $_[0]->uri; $_[0]->on_finish(sub { $err = $_[1]; EV::break }) });
    $b->{view}->download_uri($URL);
    TWK::run_with_timeout(20);
    $b->quit;

    like($seen_uri // '', qr{^http://127\.0\.0\.1:}, 'on_download sees a page-initiated download');
    like($err // '', qr/no destination/, 'a download with no destination is cancelled, not written');
}

# --- 3) on_download can choose the destination from the SUGGESTED name ---
{
    my $b = EV::WebKit->new(window => [200, 150]);
    my ($suggested, $path, $err);
    $b->on_download(sub {
        my ($d) = @_;
        $suggested = $d->suggested;
        $d->save_to(File::Spec->catfile($dir, 'from-suggestion.bin'));
        $d->on_finish(sub { ($path, $err) = @_; EV::break });
    });
    $b->{view}->download_uri($URL);
    TWK::run_with_timeout(20);
    $b->quit;

    is($suggested, 'served.bin', 'on_download is told the server-suggested filename');
    is($err, undef, 'suggestion-driven download completes');
    ok($path && -e $path, 'the chosen destination exists');
}

# --- 4) quit() with a download still in flight must resolve its callback,
# not leave the caller waiting forever ---
{
    my $b = EV::WebKit->new(window => [200, 150]);
    my $err = 'never called';
    $b->download($URL, File::Spec->catfile($dir, 'x.bin'), sub { $err = $_[1] });
    $b->quit;      # immediately, before the download can finish
    is($err, 'browser closed', 'quit() resolves an in-flight download callback');
}

# --- 5) validation ---
{
    my $b = EV::WebKit->new(window => [200, 150]);
    eval { $b->download($URL, undef, sub {}) };
    like($@, qr/destination path is required/, 'download: missing destination croaks');
    eval { $b->download($URL, '/tmp/z', 'not-a-code-ref') };
    like($@, qr/code reference/, 'download: non-coderef callback croaks');
    my $e;
    $b->download('', '/tmp/z', sub { $e = $_[1]; EV::break });
    TWK::run_with_timeout(5);
    is($e, 'download: uri required', 'download: empty uri resolves with an error');
    $b->quit;
}

# --- 6) file upload: on_file_chooser drives <input type=file>, which cannot be
# populated from JavaScript at all ---
{
    my $upload = File::Spec->catfile($dir, 'upload.txt');
    open my $fh, '>', $upload or die $!; print {$fh} 'PAYLOAD'; close $fh;

    my $b = EV::WebKit->new(window => [300, 200]);
    my ($mimes, $multi, $chose);
    $b->on_file_chooser(sub {
        my ($fc) = @_;
        $mimes = join ',', $fc->mime_types;
        $multi = $fc->multiple;
        $fc->select($upload);
        $chose = 1;
    });
    my %g;
    # WebKit applies the selection ASYNCHRONOUSLY: reading files.length in the
    # click callback still shows 0, and it becomes 1 a tick later. So poll to a
    # deadline rather than reading once (which would be a guaranteed-flaky
    # assertion) or sleeping a magic interval (which would be slow AND flaky).
    my $poll; my $deadline = time + 10;
    $poll = sub {
        $b->script('const f = document.getElementById("f");'
                 . 'return JSON.stringify({ n: f.files.length,'
                 . ' name: f.files[0] ? f.files[0].name : null,'
                 . ' size: f.files[0] ? f.files[0].size : null })',
            sub {
                my ($json) = @_;
                $g{r} = $json;
                return EV::break if ($json // '') =~ /"n":[1-9]/ || time > $deadline;
                my $t; $t = EV::timer(0.05, 0, sub { undef $t; $poll->() });
            });
    };
    $b->load_html('<input type=file id=f accept="text/plain">', sub {
        $b->find('#f', sub { $_[0]->click(sub { $poll->() }) });
    });
    TWK::run_with_timeout(20);
    $b->quit;

    ok($chose, 'on_file_chooser was invoked by a real <input type=file> click');
    like($mimes // '', qr{text/plain}, 'the chooser reports the accept= mime types');
    is($multi, 0, 'a single-file input reports multiple=0');
    require Cpanel::JSON::XS;
    my $r = eval { Cpanel::JSON::XS::decode_json($g{r} // '{}') } || {};
    is($r->{n}, 1, 'the input received exactly one file');
    is($r->{name}, 'upload.txt', 'the page sees the file name we selected');
    # a real size proves the page can actually READ it, not just see a name
    is($r->{size}, 7, 'and its real size -- the file is genuinely readable by the page');
}

# --- 7) file-chooser validation ---
{
    my $b = EV::WebKit->new(window => [300, 200]);
    my $upload = File::Spec->catfile($dir, 'upload.txt');
    my ($e_missing, $e_multi);
    $b->on_file_chooser(sub {
        my ($fc) = @_;
        eval { $fc->select(File::Spec->catfile($dir, 'no-such-file')) };
        $e_missing = $@;
        eval { $fc->select($upload, $upload) };
        $e_multi = $@;
        $fc->cancel;
    });
    $b->load_html('<input type=file id=f>', sub {
        $b->find('#f', sub { $_[0]->click(sub { EV::break }) });
    });
    TWK::run_with_timeout(20);
    $b->quit;
    like($e_missing // '', qr/no such file/,     'select() rejects a path that does not exist');
    like($e_multi   // '', qr/single file only/, 'select() rejects several files on a single-file input');
}

done_testing;
