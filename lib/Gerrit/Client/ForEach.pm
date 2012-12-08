package Gerrit::Client::ForEach;
use strict;
use warnings;

use AnyEvent::Util;
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
    wd => $workdir,
  );

  return $self->_ensure_cmd(
    event => $event,
    queue => $out,
    name  => 'git reset for workdir',
    cmd   => [ 'git', 'reset', '--hard', $ref ],
    wd => $workdir,
  );
}

sub _ensure_cmd {
  my ( $self, %args ) = @_;

  my $event = $args{event};
  my $name  = $args{name};

  my $donekey = "_cmd_${name}_done";
  my $cvkey   = "_cmd_${name}_cv";

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

    my %run_cmd_args = (
      '>'  => sub { _debug_print( "$cmdstr: ", @_ ) },
      '2>' => sub { _debug_print( "$cmdstr: ", @_ ) },
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
        if ($status) {
          warn __PACKAGE__ . ": $name exited with status $status\n";
        }
        else {
          $event->{$donekey} = 1;
        }
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

sub _dequeue {
  my ($self) = @_;

  if ($Gerrit::Client::DEBUG) {
    _debug_print 'queue before processing: ', Dumper( $self->{queue} );
  }

  my $weakself = $self;
  weaken($weakself);

  my @newqueue;
  foreach my $event ( @{ $self->{queue} || [] } ) {
    my $project = $event->{change}{project};
    my $ref     = $event->{patchSet}{ref};

    next unless $self->_ensure_git_cloned( $event, \@newqueue );
    next unless $self->_ensure_git_fetched( $event, \@newqueue );
    next unless $self->_ensure_git_workdir_uptodate( $event, \@newqueue );

    if ( $self->{args}{on_patch} ) {
      local $CWD = $event->{_workdir};
      $self->{args}{on_patch}->( $event->{change}, $event->{patchSet} );
      next;
    }
    elsif ( $self->{args}{on_patch_fork} ) {
      if ( !$event->{_forked} ) {
        $event->{_forked} = 1;
        local $CWD = $event->{_workdir};
        &fork_call(
          $self->{args}{on_patch_fork},
          $event->{change},
          $event->{patchSet},
          sub {
            $event->{_done} = 1;
            $weakself->_dequeue();
          }
        );
        push @newqueue, $event;
      }
      elsif ( !$event->{_done} ) {
        push @newqueue, $event;
      }
      next;
    }
    elsif ( $self->{args}{on_patch_cmd} ) {
      if ( !$event->{_done} ) {
        my $cmd = $self->{args}{on_patch_cmd};
        if ( !$event->{_cmd_cv} ) {
          if ( $cmd && ref($cmd) eq 'CODE' ) {
            $cmd = [ $cmd->( $event->{change}, $event->{patchSet} ) ];
          }

          {
            local $LIST_SEPARATOR = '] [';
            _debug_print "on_patch_cmd for $project $ref: [@{$cmd}]\n";
          }

          $event->{_cmd_cv} =
            AnyEvent::Util::run_cmd( $cmd,
            on_prepare => sub { chdir( $event->{_workdir} ) } );

          $event->{_cmd_cv}->cb(
            sub {
              my ($cv) = @_;
              my $status = $cv->recv();
              _debug_print
                "on_patch_cmd for $project $ref exited with status $status\n";
              if ($status) {
                $weakself->{args}{on_error}->(
                  "on_patch_cmd for $project $ref exited with status $status");
              }
              $event->{_done} = 1;
              $weakself->_dequeue();
            }
          );
        }
        push @newqueue, $event;
        next;
      }
    }

  }

  $self->{queue} = \@newqueue;

  if ($Gerrit::Client::DEBUG) {
    _debug_print 'queue after processing: ', Dumper( $self->{queue} );
  }

  return;
}

1;
