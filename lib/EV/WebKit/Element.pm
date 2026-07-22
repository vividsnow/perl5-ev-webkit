package EV::WebKit::Element;
use v5.10; use strict; use warnings;
use Carp ();
our $VERSION = '0.01';

sub _new { my ($class, $browser, $id, $epoch) = @_; bless { b => $browser, id => $id, epoch => $epoch }, $class }

# attr/prop/type bind positionally (my ($s, $n, $cb) = @_), so a caller who omits
# the name leaves the CALLBACK sitting in the name slot -- and since a call with
# no callback is legal here, nothing complains: the coderef is quietly shipped to
# the JSON encoder, the encode dies inside a deferred timer where $EV::DIED only
# warns, and the caller waits forever for a result that is never coming. Croak
# instead, as every other method in this API does for a bad argument.
sub _need_name {
    my ($what, $n) = @_;
    Carp::croak("$what: a name is required") unless defined $n;
    Carp::croak("$what: the name must be a plain string, not a " . ref($n) . ' reference'
              . ($n && ref $n eq 'CODE' ? ' (did you omit the name and pass only a callback?)' : ''))
        if ref $n;
    return;
}

sub _call_js {
    my ($self, $code, $args, $cb) = @_;
    # Same synchronous croak every async EV::WebKit method makes, and for the
    # same reason: a non-coderef callback would only blow up later, deep inside
    # the completion, where the die is swallowed by $EV::DIED -- so the caller's
    # EV::run just hangs, waiting for a callback that can never be invoked.
    # Guarding here covers all 13 accessors at once, since they all route
    # through this shim. (An omitted callback stays legal -- _defer no-ops.)
    Carp::croak('callback must be a code reference') if defined $cb && ref $cb ne 'CODE';
    # 'id' and 'epoch' are reserved for this element's registry id/per-
    # document epoch stamp and override any caller key -- epoch lets
    # window.__evwk.get() detect a handle from a page that has since been
    # navigated away from, even if the new page's registry reused the same
    # numeric id (see EV::WebKit's $BOOT script).
    $self->{b}->_call_js($code, { %{ $args // {} }, id => $self->{id}, epoch => $self->{epoch} }, $cb);
}

sub text  { $_[0]->_call_js('return window.__evwk.get(A.id, A.epoch).textContent;', {}, $_[1]) }
sub html  { $_[0]->_call_js('return window.__evwk.get(A.id, A.epoch).innerHTML;',  {}, $_[1]) }
sub value { $_[0]->_call_js('return window.__evwk.get(A.id, A.epoch).value;',      {}, $_[1]) }
sub tag   { $_[0]->_call_js('return window.__evwk.get(A.id, A.epoch).tagName.toLowerCase();', {}, $_[1]) }
sub attr  { my ($s,$n,$cb)=@_; _need_name(attr => $n); $s->_call_js('return window.__evwk.get(A.id, A.epoch).getAttribute(A.name);', {name=>$n}, $cb) }
sub prop  { my ($s,$n,$cb)=@_; _need_name(prop => $n); $s->_call_js('return window.__evwk.get(A.id, A.epoch)[A.name];',               {name=>$n}, $cb) }

sub is_visible {
    $_[0]->_call_js(
        'const el = window.__evwk.get(A.id, A.epoch); const s = getComputedStyle(el);'
      . 'return s.display !== "none" && s.visibility !== "hidden" && el.getClientRects().length > 0;',
        {}, $_[1]);
}

sub find {
    my ($s, $sel, $cb) = @_;
    # These two pass their OWN closure to _call_js, so its callback guard sees a
    # coderef either way and cannot check the caller's -- guard here too, or a
    # non-coderef $cb dies inside the completion below, where $EV::DIED eats it
    # and the caller's EV::run hangs forever.
    Carp::croak('find: last argument must be a callback') if ref $cb ne 'CODE';
    # This wrapper closure is captured strongly by the (permanently
    # GI-retained) _call_js completion closure -- but UNLIKE _call_js/
    # EV::WebKit::find's own $self (the browser, always independently held
    # by the caller's own long-lived variable in practice), $s (an Element)
    # is frequently held ONLY via this closure's own capture -- e.g. several
    # sibling calls issued off the same $el, where none of the sibling
    # closures happen to mention $el by name, so nothing else keeps it
    # reachable during the async gap (confirmed: weakening $s here, mirroring
    # the find()/wait_for() fix, broke exactly that pattern -- t/41's 9
    # concurrent $d->... calls). So $s must stay STRONGLY captured while the
    # call is in flight; instead, break the retention at a single resolution
    # point, explicitly undef'ing our OWN copy the instant we're done needing
    # it (same "single resolution point" shape as wait_for's $finish) -- this
    # releases $s (and transitively $s->{b}, the browser) from THIS closure
    # without affecting any sibling closure's own (still-strong) copy.
    $s->_call_js('const el = window.__evwk.get(A.id, A.epoch).querySelector(A.sel); return el ? { evwk_id: window.__evwk.put(el), evwk_epoch: window.__evwk.epoch } : null;',
        { sel => $sel },
        sub {
            my ($r, $err) = @_;
            # A hostile/buggy page can make ANY JS value come back here (e.g.
            # Object.prototype.toJSON polluted to return something else
            # entirely) -- never trust the decoded shape before dereferencing
            # it: an unvalidated $r->{evwk_id} below would die inside
            # _defer's bare EV::timer(0,0,...), which EV's default $EV::DIED
            # swallows to stderr, permanently dropping this callback (a
            # silent hang, not an error) instead of ever reaching the caller.
            if (!$err && defined $r && !(ref $r eq 'HASH' && defined $r->{evwk_id})) {
                $err = 'find: unexpected result from page (registry tampered?)';
            }
            my $result = (!$err && defined $r) ? EV::WebKit::Element->_new($s->{b}, $r->{evwk_id}, $r->{evwk_epoch}) : undef;
            undef $s;
            $cb->($result, $err);
        });
}

sub find_all {
    my ($s, $sel, $cb) = @_;
    Carp::croak('find_all: last argument must be a callback') if ref $cb ne 'CODE';
    # same reasoning as find() above.
    $s->_call_js('return [...window.__evwk.get(A.id, A.epoch).querySelectorAll(A.sel)].map(e => ({ evwk_id: window.__evwk.put(e), evwk_epoch: window.__evwk.epoch }));',
        { sel => $sel },
        sub {
            my ($r, $err) = @_;
            # same shape distrust as find() above -- a tampered result (e.g.
            # the whole array replaced, or containing non-descriptor
            # elements) must degrade to a clean error, never dereference
            # blind and die inside _defer's unguarded timer.
            if (!$err && !(ref $r eq 'ARRAY' && !grep { ref $_ ne 'HASH' || !defined $_->{evwk_id} } @$r)) {
                $err = 'find_all: unexpected result from page (registry tampered?)';
            }
            my $result = $err ? undef : [ map { EV::WebKit::Element->_new($s->{b}, $_->{evwk_id}, $_->{evwk_epoch}) } @$r ];
            undef $s;
            $cb->($result, $err);
        });
}

sub click { $_[0]->_call_js('window.__evwk.get(A.id, A.epoch).click(); return true;', {}, $_[1]) }
sub focus { $_[0]->_call_js('window.__evwk.get(A.id, A.epoch).focus(); return true;', {}, $_[1]) }

sub type {
    my ($s, $text, $cb) = @_;
    _need_name(type => $text);   # same positional-binding trap as attr/prop -- see there
    $s->_call_js(
        'const el = window.__evwk.get(A.id, A.epoch); const tag = el.tagName;'
      . 'if (tag === "INPUT" || tag === "TEXTAREA") {'
      . '  el.focus(); el.value = (el.value || "") + A.text;'
      . '  el.dispatchEvent(new Event("input",  {bubbles:true}));'
      . '  el.dispatchEvent(new Event("change", {bubbles:true}));'
      . '} else if (el.isContentEditable) {'
      . '  el.focus(); el.textContent = (el.textContent || "") + A.text;'
      . '  el.dispatchEvent(new InputEvent("input", {bubbles:true}));'
      . '} else { throw new Error("element is not editable"); }'
      . 'return true;',
        { text => $text }, $cb);
}
*send_keys = \&type;

sub clear {
    $_[0]->_call_js(
        'const el = window.__evwk.get(A.id, A.epoch); const tag = el.tagName;'
      . 'if (tag === "INPUT" || tag === "TEXTAREA") {'
      . '  el.value = "";'
      . '  el.dispatchEvent(new Event("input", {bubbles:true}));'
      . '} else if (el.isContentEditable) {'
      . '  el.textContent = "";'
      . '  el.dispatchEvent(new InputEvent("input", {bubbles:true}));'
      . '} else { throw new Error("element is not editable"); }'
      . 'return true;',
        {}, $_[1]);
}

sub submit {
    $_[0]->_call_js(
        'const el = window.__evwk.get(A.id, A.epoch); const f = el.form || el;'
      . 'if (f instanceof HTMLFormElement) HTMLFormElement.prototype.submit.call(f);'
      . 'return true;',
        {}, $_[1]);
}
1;

=pod

=head1 NAME

EV::WebKit::Element - a handle to a DOM element found by EV::WebKit

=head1 SYNOPSIS

    $b->find('#login', sub {
        my ($el, $err) = @_;
        die "find failed: $err\n" if $err;
        die "no #login on this page\n" unless $el;

        $el->type('alice', sub {
            my (undef, $err) = @_;
            die "type failed: $err\n" if $err;
            $el->submit(sub {
                my (undef, $err) = @_;
                warn "submit failed: $err\n" if $err;
                EV::break;
            });
        });
    });

=head1 DESCRIPTION

An EV::WebKit::Element is a handle to a single DOM node discovered via
L<EV::WebKit>'s C<find>/C<find_all> methods, or (scoped to that element's
descendants) its own C<find>/C<find_all> below. Internally it is just a
small page-side registry id, the per-document epoch stamp of the registry
it was created from, and a back-reference to the owning L<EV::WebKit>
browser -- not a live DOM reference held on the Perl side. Every method
runs JavaScript against that node asynchronously, on the same L<EV> loop as
the browser, and follows the browser's own callback convention: a trailing
C<sub { my ($result, $err) = @_; ... }>, C<$err> undef on success. See
L<EV::WebKit/"CALLBACK CONVENTION">.

Instances are only ever returned by L<EV::WebKit> methods; there is no
public constructor.

If the underlying DOM node has since been removed from the document, any
method call on that handle fails with a script error whose message
mentions "stale element". The same happens if navigation has replaced the
page entirely, even though the new page's own registry happens to reuse
the same numeric id the old handle had: each navigation re-injects a fresh
registry with a new epoch stamp, every handle carries the epoch it was
created with, and a mismatch is treated exactly like a removed node.
C<id> and C<epoch> are reserved argument names, always set by this class
internally, for every JavaScript snippet run through these methods.

=head1 METHODS

All methods below take a trailing C<sub { my ($result, $err) = @_; ... }>
callback.

=head2 text

    $el->text($cb);

C<$result> is the node's C<textContent>.

=head2 html

    $el->html($cb);

C<$result> is the node's C<innerHTML>.

=head2 value

    $el->value($cb);

C<$result> is the form control's current C<value>.

=head2 tag

    $el->tag($cb);

C<$result> is the node's lower-cased tag name, e.g. C<"div">.

=head2 attr

    $el->attr($name, $cb);

C<$result> is the HTML attribute C<$name> (via C<getAttribute>), or
C<undef> if the attribute is not present.

=head2 prop

    $el->prop($name, $cb);

C<$result> is the live JavaScript/DOM property C<$name> (e.g.
C<< prop('checked') >>), as opposed to C<attr>'s raw HTML attribute --
useful when the two differ (checkbox C<checked> state, current vs default
C<value>, and so on).

=head2 is_visible

    $el->is_visible($cb);

C<$result> is true if the element's computed C<display> is not C<none>,
its computed C<visibility> is not C<hidden>, and it has at least one client
rect (roughly: it takes up visible space in the rendered page).

=head2 find

    $el->find($selector, $cb);

Scoped C<querySelector> under this element. C<$result> is an
L<EV::WebKit::Element> on a match, or C<undef> if nothing matched --
not-found is not an error.

=head2 find_all

    $el->find_all($selector, $cb);

Scoped C<querySelectorAll> under this element. C<$result> is a (possibly
empty) arrayref of L<EV::WebKit::Element>.

=head2 click

    $el->click($cb);

Calls the node's C<click()>.

=head2 type

    $el->type($text, $cb);

On an C<< <input> >> or C<< <textarea> >>, appends C<$text> to the
element's current C<value> and dispatches C<input> and C<change> events.
On a contenteditable element (C<isContentEditable>), appends C<$text> to
its C<textContent> instead (there is no native C<value> to set) and
dispatches an C<input> event. Either way this sets the content directly and
fires the event(s) once -- it does not simulate individual keydown/keyup
events per character. On anything else (not a form control, not
contenteditable), C<$err> is set to an error mentioning "not editable"
rather than silently doing nothing.

=head2 send_keys

An alias for C<type> above (identical behavior, including the "not really
per-key" caveat and the contenteditable/not-editable handling).

=head2 clear

    $el->clear($cb);

On an C<< <input> >> or C<< <textarea> >>, empties C<value> and dispatches
an C<input> event. On a contenteditable element, empties C<textContent>
instead and dispatches an C<input> event. On anything else, C<$err> is set
to an error mentioning "not editable".

=head2 focus

    $el->focus($cb);

Calls the node's C<focus()>.

=head2 submit

    $el->submit($cb);

Calls the native C<submit()> of the element's owning C<< <form> >>, or of
the element itself if it has no C<form> (e.g. calling C<submit> directly on
a C<< <form> >> element). This bypasses any C<onsubmit> handler and may
navigate the page. Resolves successfully even if there was nothing to
submit (a silent no-op).

=head1 SEE ALSO

L<EV::WebKit>

=head1 AUTHOR

vividsnow

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
