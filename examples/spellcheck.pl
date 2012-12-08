#!/usr/bin/env perl
use strict;
use warnings;

use AnyEvent::Util;
use English qw(-no_match_vars);
use Gerrit::Client qw(for_each_patch);
use Getopt::Long qw(:config pass_through);
use Lingua::EN::CommonMistakes qw(%MISTAKES);
use FindBin;
use File::chdir;
use File::Temp;

my $script = "$FindBin::Bin/$FindBin::Script";
my $workdir = "$ENV{ HOME }/gerrit-spell-check-bot";
my $url;
my $maxproc = 5;
my $i       = 0;

sub check_patch {
  my $log = qx(git --no-pager log -n1 --format=format:%B HEAD);
  my @errors;
  foreach my $word (map { lc $_ } split /\b/, $log) {
    if (my $correction = $MISTAKES{$word}) {
      push @errors, "$word -> $correction";
    }
  }
  if (!@errors) {
    print "No spelling errors found in:\n";
    system("git --no-pager log -n1");
    return 0;
  }
  local $LIST_SEPARATOR = "\n  ";
  print "Likely spelling error(s):$LIST_SEPARATOR@errors\n";
  return -1;
}

sub run_daemon {
  my $url;
  my $style = 'sub';
  GetOptions( 'url=s' => \$url, 'style=s' => \$style, ) || die;
  $url || die 'missing mandatory --url argument';

  my $stream = for_each_patch(
    url => $url,

    ($style eq 'cmd' ? (on_patch_cmd => [ $EXECUTABLE_NAME, $script ]) : ()),
    ($style eq 'sub' ? (on_patch => \&check_patch) : ()),
    ($style eq 'fork' ? (on_patch_fork => \&check_patch) : ()),

    workdir => $workdir,
    review => 1,
  );
  AE::cv()->recv();
}

sub run {
  my $daemon = 0;
  GetOptions( daemon => \$daemon ) || die;
  if ($daemon) {
    return run_daemon();
  }
  exit check_patch();
}

run() unless caller;
1;
