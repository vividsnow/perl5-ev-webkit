requires 'perl', '5.010';
requires 'EV';
requires 'EV::Glib';
requires 'Glib';
requires 'Glib::Object::Introspection';
requires 'Glib::IO';
requires 'Cpanel::JSON::XS';
on test => sub { requires 'Test::More'; };
