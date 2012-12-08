package Gerrit::Client::ForEach;
use strict;
use warnings;

use AnyEvent::Util;
use Capture::Tiny qw(capture_merged);
use Data::Alias;
use Data::Dumper;
use English qw(-no_match_vars);
use File::chdir;
use Gerrit::Client;
use Scalar::Util qw(weaken);

sub _debug_print {
  return Gerrit::Client::_debug_print(@_);
}

sub _handle_for_each_event {
  my ( $self, $event ) = @_;

  return unless $event->{type} eq 'patchset-created';

  $self->_enqueue_event($event);

  return $self->_dequeue();
}

sub _enqueue_event {
  my ( $self, $event ) = @_;

  push @{ $self->{queue} }, $event;

  return;
}

sub _giturl {
  my ( $self, $event ) = @_;
  my $project = $event->{change}{project};
  return "$self->{args}{url}/$project";
}

sub _gitdir {
  my ( $self, $event ) = @_;
  my $project = $event->{change}{project};
  return "$self->{args}{workdir}/$project/git";
}

sub _ensure_git_cloned {
  my ( $self, $event, $out ) = @_;

  my $ref     = $event->{patchSet}{ref};
  my $project = $event->{change}{project};

  my $gitdir = $self->_gitdir($event);
  my $giturl = $self->_giturl($event);

  my $cloned = $self->_ensure_cmd(
    event => $event,
    queue => $out,
    name  => 'git clone',
    cmd   => [ 'git', 'clone', '--bare', $giturl, $gitdir ],
    onlyif => sub { !-d $gitdir },
  );
  return unless $cloned;

  if ( !-d $gitdir ) {
    warn __PACKAGE__ . ": failed to clone $giturl to $gitdir\n";
    return;
  }

  return 1;
}

sub _ensure_git_fetched {
  my ( $self, $event, $out ) = @_;

  my $gitdir = $self->_gitdir($event);
  my $giturl = $self->_giturl($event);
  my $ref    = $event->{patchSet}{ref};

  return $self->_ensure_cmd(
    event => $event,
    queue => $out,
    name  => 'git fetch',
    cmd =>
      [ 'git', '--git-dir', $gitdir, 'fetch', '-v', $giturl, "+$ref:$ref" ],
  );
}

sub _ensure_git_workdir_uptodate {
  my ( $self, $event, $out ) = @_;

  my $project = $event->{change}{project};
  my $ref     = $event->{patchSet}{ref};
  my $gitdir  = $self->_gitdir($event);

  alias my $workdir = $event->{_workdir};
  $workdir ||=
    File::Temp->newdir("$self->{args}{workdir}/$project/work.XXXXXX");

  return
    unless $self->_ensure_cmd(
    event => $event,
    queue => $out,
    name  => 'git clone for workdir',
    cmd   => [ 'git', 'clone', $gitdir, $workdir ],
    onlyif => sub { !-d "$workdir/.git" },
    );

  return
    unless $self->_ensure_cmd(
    event => $event,
    queue => $out,
    name  => 'git fetch for workdir',
    cmd   => [ 'git', 'fetch', '-v', 'origin', "+$ref:$ref" ],
    wd    => $workdir,
    );

  return $self->_ensure_cmd(
    event => $event,
    queue => $out,
    name  => 'git reset for workdir',
    cmd   => [ 'git', 'reset', '--hard', $ref ],
    wd    => $workdir,
  );
}

sub _ensure_cmd {
  my ( $self, %args ) = @_;

  my $event = $args{event};
  my $name  = $args{name};

  my $donekey   = "_cmd_${name}_done";
  my $cvkey     = "_cmd_${name}_cv";
  my $statuskey = "_cmd_${name}_status";
  my $outputkey = "_cmd_${name}_output";

  return 1 if ( $event->{$donekey} );

  my $onlyif = $args{onlyif} || sub { 1 };
  my $queue = $args{queue};

  my $weakself = $self;
  weaken($weakself);

  alias my $cmdcv = $event->{$cvkey};
  my $cmd = $args{cmd};
  my $cmdstr;
  {
    local $LIST_SEPARATOR = '] [';
    $cmdstr = "[@{$cmd}]";
  }

  if ( !$cmdcv ) {

    # not done and not started; only needs doing if 'onlyif' returns false
    if ( !$onlyif->() ) {
      $event->{$donekey} = 1;
      return 1;
    }

    my $printoutput = sub { _debug_print( "$cmdstr: ", @_ ) };
    my $handleoutput = $printoutput;

    if ( $args{saveoutput} ) {
      $handleoutput = sub {
        $printoutput->(@_);
        $event->{$outputkey} .= $_[0];
      };
    }

    my %run_cmd_args = (
      '>'  => $handleoutput,
      '2>' => $handleoutput,
    );

    if ( $args{wd} ) {
      $run_cmd_args{on_prepare} = sub {
        chdir( $args{wd} ) || warn __PACKAGE__ . ": chdir $args{wd}: $!";
      };
    }

    $cmdcv = AnyEvent::Util::run_cmd( $cmd, %run_cmd_args, );
    $cmdcv->cb(
      sub {
        my ($cv) = @_;
        my $status = $cv->recv();
        if ( $status && !$args{allownonzero} ) {
          warn __PACKAGE__ . ": $name exited with status $status\n";
        }
        else {
          $event->{$donekey} = 1;
        }
        $event->{$statuskey} = $status;
        $weakself->_dequeue();
      }
    );
    push @{$queue}, $event;
    return;
  }

  if ( !$cmdcv->ready ) {
    push @{$queue}, $event;
    return;
  }

  warn __PACKAGE__ . ": dropped event due to failed command: $cmdstr\n";
  return;
}

sub _do_cb_sub {
  my ( $self, $sub, $event ) = @_;

  my $score;
  my $run = sub {
    local $CWD = $event->{_workdir};
    $score = $sub->( $event->{change}, $event->{patchSet} );
  };

  my $output;
  if ($self->{args}{review}) {
    $output = &capture_merged( $run );
  } else {
    $run->();
  }

  return {
    score => $score,
    output => $output
  };
}

sub _do_cb_forksub {
  my ( $self, $sub, $event, $queue ) = @_;

  my $weakself = $self;
  weaken($weakself);

  if ($event->{_forksub_result}) {
    return $event->{_forksub_result};
  }

  if ( $event->{_forked} ) {
    push @{$queue}, $event;
    return;
  }

  $event->{_forked} = 1;
  &fork_call(
    \&_do_cb_sub,
    $self,
    $sub,
    $event,
    sub {
      my ($result) = $_[0];
      if (!$result) {
        if ($@) {
          $result = {output => $@};
        } else {
          $result = {output => $!};
        }
      }
      $event->{_forksub_result} = $result;
      $weakself->_dequeue();
    }
  );
  push @{$queue}, $event;
  return;
}

sub _do_cb_cmd {
  my ( $self, $cmd, $event, $out ) = @_;

  return if ( $event->{_done} );

  my $project = $event->{change}{project};
  my $ref     = $event->{patchSet}{ref};

  if ( !$event->{_cmd} ) {
    if ( $cmd && ref($cmd) eq 'CODE' ) {
      $cmd = [ $cmd->( $event->{change}, $event->{patchSet} ) ];
    }
    $event->{_cmd} = $cmd;
    local $LIST_SEPARATOR = '] [';
    _debug_print "on_patch_cmd for $project $ref: [@{$cmd}]\n";
  }

  return unless $self->_ensure_cmd(
    event => $event,
    queue => $out,
    name  => 'on_patch_cmd',
    cmd   => $event->{_cmd},
    wd    => $event->{_workdir},
    saveoutput => $self->{args}{review},
    allownonzero => 1,
  );

  my $score = 0;
  my $output = $event->{_cmd_on_patch_cmd_output};
  my $status = $event->{_cmd_on_patch_cmd_status};

  if ($status == -1) {
    # exited abnormally; treat as neutral score
  } elsif ($status & 127) {
    # exited due to signal; treat as neutral score,
    # append signal to output
    $output .= "\n[exited due to signal ".($status&127)."]\n";
  } else {
    # exited normally; exit code is score
    $score = $status >> 8;
    # interpret exit code as signed
    if ($score > 127) {
      $score = $score - 256;
    }
  }

  return {
    score => $score,
    output => $output
  };
}

sub _do_callback {
  my ( $self, $event, $out ) = @_;

  my $ref;
  my $result;

  if ( $ref = $self->{args}{on_patch} ) {
    $result = $self->_do_cb_sub( $ref, $event );
  }
  elsif ( $ref = $self->{args}{on_patch_fork} ) {
    $result = $self->_do_cb_forksub( $ref, $event, $out );
  }
  elsif ( $ref = $self->{args}{on_patch_cmd} ) {
    $result = $self->_do_cb_cmd( $ref, $event, $out );
  }

  if ($result && $Gerrit::Client::DEBUG) {
    _debug_print 'callback result: '.Dumper($result);
  }
}

sub _dequeue {
  my ($self) = @_;

  if ($Gerrit::Client::DEBUG) {
    _debug_print 'queue before processing: ', Dumper( $self->{queue} );
  }

  my $weakself = $self;
  weaken($weakself);

  my @newqueue;
  foreach my $event ( @{ $self->{queue} || [] } ) {
    next unless $self->_ensure_git_cloned( $event, \@newqueue );
    next unless $self->_ensure_git_fetched( $event, \@newqueue );
    next unless $self->_ensure_git_workdir_uptodate( $event, \@newqueue );
    $self->_do_callback( $event, \@newqueue );
  }

  $self->{queue} = \@newqueue;

  if ($Gerrit::Client::DEBUG) {
    _debug_print 'queue after processing: ', Dumper( $self->{queue} );
  }

  return;
}

1;
