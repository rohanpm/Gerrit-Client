#!/usr/bin/env perl
use strict;
use warnings;

use Gerrit::Client;
use Test::More;

sub run_test {
  # simply compares generated header against a reference implementation (curl)
  my $cb = Gerrit::Client::http_digest_auth(
    'perl-gerrit-client-test',
    'JN+EDyCDgCbf',
    cnonce_cb => sub { 'MDEyNzY1' }
  );

  my $in = {
    URL => 'http://127.0.0.1:34901/a/changes/perl-gerrit-client-test~master~Ib2f73f1d16953ef2c4585d69b76adfeb510fa65a/revisions/80d85d318d06e166dd4e8de011e5cd401e4b191a/review',
    Method => 'POST',
    'www-authenticate' => 'Digest realm="Gerrit Code Review", domain="http://127.0.0.1:34901/", qop="auth", nonce="ierKW5ldomFvA+D0EepkMAOr/SLa3xa0t2eYPA==$"',
  };

  my $out = {};

  $cb->($in, $out);

  is(
    $out->{'Authorization'},
    'Digest username="perl-gerrit-client-test", realm="Gerrit Code Review", nonce="ierKW5ldomFvA+D0EepkMAOr/SLa3xa0t2eYPA==$", uri="/a/changes/perl-gerrit-client-test~master~Ib2f73f1d16953ef2c4585d69b76adfeb510fa65a/revisions/80d85d318d06e166dd4e8de011e5cd401e4b191a/review", cnonce="MDEyNzY1", nc=00000001, qop="auth", response="aabc408563b37b6275a0e568cd2dd83f"'
  );
}

unless (caller) {
  run_test();
  done_testing();
}

1;
