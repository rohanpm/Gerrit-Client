#!/usr/bin/env perl
use strict;
use warnings;

use AnyEvent;
use Capture::Tiny qw(capture_merged);
use Data::Dumper;
use English qw( -no_match_vars );
use Env::Path;
use File::Temp;
use File::chdir;
use Gerrit::Client;
use Gerrit::Client::Test;
use IO::File;
use JSON;
use Sub::Override;
use Test::More;
use Test::Warn;

# This would normally be loaded internally as needed, but we need to
# load it now for mocking
use Gerrit::Client::ForEach;


my $CHANGE_ID_RE = qr{I[a-f0-9]{40}};

# like system(), but fails the test and shows the command output
# if the command fails
sub system_or_fail {
  my (@cmd) = @_;
  my $status;
  my $output = capture_merged {
    $status = system(@cmd);
  };
  is( $status, 0 )
    || diag "command [@cmd] exited with status $status\noutput:\n$output";
  return;
}

# create a file with the given $filename, or fail
sub touch {
  my ($filename) = @_;
  ok( IO::File->new( $filename, '>>' ), "open $filename" )
    || diag "open $filename failed: $!";
  return;
}

# mock git commands which succeed but don't do much
sub mock_gits_ok
{
  return [
    Sub::Override->new(
      'Gerrit::Client::ForEach::_git_bare_clone_cmd' => sub {
        my (undef, $giturl, $gitdir) = @_;
        return ('git', 'init', '--bare', $gitdir);
      }
    ),
    Sub::Override->new(
      'Gerrit::Client::ForEach::_git_clone_cmd' => sub {
        my (undef, $giturl, $gitdir) = @_;
        return ('git', 'init', $gitdir);
      }
    ),
    Sub::Override->new(
      'Gerrit::Client::ForEach::_git_fetch_cmd' => sub {
        my (undef, $giturl, $gitdir, $ref) = @_;
        return ('perl', '-e1');
      }
    ),
    Sub::Override->new(
      'Gerrit::Client::ForEach::_git_reset_cmd' => sub {
        my (undef, $ref) = @_;
        return ('perl', '-e1');
      }
    ),
  ];
}

# some test changes and patch sets
my $test_rev1 = 'a765609f8b97fd8c9c29d7576d46b8eba99c11ac';
my $test_rev2 = 'bbb5609f8b97fd8c9c29d7576d46b8eba99c11ac';
my $test_rev3 = 'ccc5609f8b97fd8c9c29d7576d46b8eba99c11ac';
my $test_rev4 = 'ddd5609f8b97fd8c9c29d7576d46b8eba99c11ac';
my $test_rev5 = 'eee5609f8b97fd8c9c29d7576d46b8eba99c11ac';

my $test_ps1 = { number => 1, revision => $test_rev1, ref => 'refs/changes/02/2/1' };
my $test_ps2 = { number => 2, revision => $test_rev2, ref => 'refs/changes/01/1/2' };
my $test_ps3 = { number => 3, revision => $test_rev3, ref => 'refs/changes/06/6/3' };
my $test_ps4 = { number => 4, revision => $test_rev4, ref => 'refs/changes/07/7/4' };
my $test_ps5 = { number => 5, revision => $test_rev5, ref => 'refs/changes/07/7/5' };

my $test_change1 = {
  project => "prj1",
  branch  => "master",
  id      => "id1",
  subject => 'Some commit',
  currentPatchSet => $test_ps1,
};
my $test_change2 = {
  project => "prj2",
  branch  => "master",
  id      => "id2",
  subject => 'Some other commit',
  currentPatchSet => $test_ps2,
};
my $test_change3 = {
  project => "prj1",
  branch  => "master",
  id      => "id3",
  subject => 'A great commit',
  currentPatchSet => $test_ps3,
};
my $test_change4 = {
  project => "prj2",
  branch  => "master",
  id      => "id4",
  subject => 'A poor commit',
  currentPatchSet => $test_ps4,
};
my $test_change5 = {
  project => "prj2",
  branch  => "master",
  id      => "id5",
  subject => 'The best commit',
  currentPatchSet => $test_ps5,
};

my %test_change_by_id = (
  id1 => $test_change1,
  id2 => $test_change2,
  id3 => $test_change3,
  id4 => $test_change4,
  id5 => $test_change5,
);

sub patchset_created_json
{
  my ($change) = @_;
  # events do not include the currentPatchSet within change
  my %copy = %{$change};
  my $patchset = delete $copy{currentPatchSet};
  return encode_json(
    { type     => 'patchset-created',
      change   => \%copy,
      patchSet => $patchset
    }
  );
}

my %MOCK_QUERY;
sub mock_query {
  my ($query, %args) = @_;
  my $results = shift @{$MOCK_QUERY{$query} || []};
  $results ||= [];
  foreach my $r (@{$results}) {
    $r = { %{$r} };
    if (!$args{current_patch_set}) {
      delete $r->{currentPatchSet};
    }
  }
  $args{on_success}->( @{$results} );
  return;
}

sub test_for_each_patchset {
  local %ENV = %ENV;
  my $dir = File::Temp->newdir(
    'perl-gerrit-client-test.XXXXXX',
    TMPDIR  => 1,
    CLEANUP => 1
  );
  ok( $dir, 'tempdir created' );
  Env::Path->PATH->Prepend("$dir");

  # start off with these open patch sets...
  local $MOCK_QUERY{'status:open'} = [ [ $test_change1, $test_change2 ] ];
  my $mock_query =
    Sub::Override->new( 'Gerrit::Client::query' => \&mock_query );
  my $mock_git = mock_gits_ok();

  Gerrit::Client::Test::create_mock_command(
    name      => 'ssh',
    directory => $dir,
    sequence  => [

      # simulate various events from a long-lived connection
      { delay    => 30,
        exitcode => 0,
        stdout   => patchset_created_json($test_change3) . "\n"
          . patchset_created_json($test_change4) . "\n"
          . patchset_created_json($test_change5) . "\n"
      }
    ],
  );

  my $cv = AE::cv();

  # make sure we eventually give up if something goes wrong
  my $timeout_timer = AE::timer( 30, 0, sub { $cv->croak('timed out!') } );
  my $done_timer;

  my @events;
  my $guard;
  $guard = Gerrit::Client::for_each_patchset(
    url         => 'ssh://gerrit.example.com/',
    workdir     => "$dir/work",
    on_patchset => sub {
      my ( $change, $patchset ) = @_;
      push @events,
        {
        change   => $change,
        patchset => $patchset,
        wd       => "$CWD",
        };

      # simulate cancelling the loop after 4 events
      if ( @events >= 4 ) {
        undef $guard;
        $done_timer = AE::timer( 1, 0, sub { $cv->send(); undef $done_timer } );
      }
    },
  );

  $cv->recv();

  is( scalar(@events), 4, 'got expected number of events' );

  # events may occur in any order, so sort them before comparison
  @events = sort { $a->{change}{id} cmp $b->{change}{id} } @events;

  my %seen_wd;
  my %seen_id;
  foreach my $e (@events) {

    # there should be a unique temporary work directory for each
    # event, all of which no longer exist
    my $wd = delete $e->{wd};
    ok( !$seen_wd{$wd}, "unique working directory: $wd" );
    ok( !-e $wd,        "working directory $wd was cleaned up" );
    $seen_wd{$wd} = 1;

    my $id = $e->{change}{id};
    ok( !$seen_id{$id}, "unique event $id" );
    $seen_id{$id} = 1;

    my %test_change   = %{ $test_change_by_id{$id} };
    my $test_patchset = delete $test_change{currentPatchSet};
    is_deeply( $e->{change}, \%test_change, "change $id looks ok" )
      || diag explain $e->{change};
    is_deeply( $e->{patchset}, $test_patchset, "patchset $id looks ok" )
      || diag explain $e->{patchset};
  }

  return;
}

sub run_test {
  test_for_each_patchset;

  return;
}

#==============================================================================

if ( !caller ) {
  run_test;
  done_testing;
}
1;
