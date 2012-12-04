#############################################################################
##
## Copyright (C) 2012 Rohan McGovern <rohan@mcgovern.id.au>
## Copyright (C) 2012 Digia Plc and/or its subsidiary(-ies)
##
## This library is free software; you can redistribute it and/or
## modify it under the terms of the GNU Lesser General Public
## License as published by the Free Software Foundation; either
## version 2.1 of the License, or (at your option) any later version.
##
## This library is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
## Lesser General Public License for more details.
##
## You should have received a copy of the GNU Lesser General Public
## License along with this library; if not, write to the Free Software
## Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA
##
##
#############################################################################

=head1 NAME

Gerrit::Client - interact with Gerrit code review tool

=head1 SYNOPSIS

  use AnyEvent;
  use Gerrit::Client qw(stream_events);

  # alert me when new patch sets arrive in
  # ssh://gerrit.example.com:29418/myproject
  my $stream = stream_events(
    url => 'ssh://gerrit.example.com:29418',
    on_event => sub {
      my (undef, $event) = @_;
      if ($event->{type} eq 'patchset-added'
          && $event->{change}{project} eq 'myproject') {
        system("xmessage", "New patch set arrived!");
      }
    }
  );

  AE::cv()->recv(); # must run an event loop for callbacks to be activated

This module provides some utility functions for interacting with the Gerrit code
review tool.

This module is an L<AnyEvent> user and may be used with any event loop supported
by AnyEvent.

=cut

package Gerrit::Client;
use strict;
use warnings;

use AnyEvent::Handle;
use AnyEvent::Util;
use AnyEvent;
use Carp;
use Data::Dumper;
use English qw(-no_match_vars);
use File::chdir;
use File::Path;
use File::Spec::Functions;
use Params::Validate qw(:all);
use Scalar::Util qw(weaken);
use URI;

use base 'Exporter';
our @EXPORT_OK = qw(
  for_each_patch
  stream_events
  git_environment
  next_change_id
  random_change_id
  review
);

our @SSH     = ('ssh');
our $VERSION = 20121123;
our $DEBUG   = !!$ENV{GERRIT_CLIENT_DEBUG};

sub _debug_print {
  return unless $DEBUG;
  print STDERR __PACKAGE__ . ': ', @_, "\n";
}

sub _system {
  my (@cmd) = @_;
  if ($DEBUG) {
    local $LIST_SEPARATOR = '] [';
    print STDERR __PACKAGE__ . ": run: [@cmd]\n";
  }
  return system(@cmd);
}

# parses a gerrit URL and returns a hashref with following keys:
#   cmd => arrayref, base ssh command for interacting with gerrit
#   project => the gerrit project name (e.g. "my/project")
sub _gerrit_parse_url {
  my ($url) = @_;

  if ( !ref($url) || !$url->isa('URI') ) {
    $url = URI->new($url);
  }

  if ( $url->scheme() ne 'ssh' ) {
    croak "gerrit URL $url is not supported; only ssh URLs are supported\n";
  }

  my $project = $url->path();

  # remove useless leading/trailing components
  $project =~ s{\A/+}{};
  $project =~ s{\.git\z}{}i;

  return {
    cmd => [
      @SSH,
      '-oBatchMode=yes',    # never do interactive prompts
      '-oServerAliveInterval=30'
      ,    # try to avoid the server silently dropping connection
      ( $url->port() ? ( '-p', $url->port() ) : () ),
      ( $url->user() ? ( $url->user() . '@' ) : q{} ) . $url->host(),
      'gerrit',
    ],
    project => $project,
  };
}

# quotes an argument to be passed to gerrit, if necessary.
sub _quote_gerrit_arg {
  my ($string) = @_;
  if ( $string !~ m{ } ) {
    return $string;
  }
  $string =~ s{'}{}g;
  return qq{'$string'};
}

=head1 FUNCTIONS

=over

=item B<< stream_events url => $gerrit_url, ... >>

Connect to "gerrit stream-events" on the given gerrit host and
register one or more callbacks for events. Returns an opaque handle to
the stream-events connection; the connection will be aborted if the
handle is destroyed.

$gerrit_url should be a URL with ssh schema referring to a valid
Gerrit installation (e.g. "ssh://user@gerrit.example.com:29418/").

Supported callbacks are documented below. All callbacks receive the
stream-events handle as their first argument.

=over

=item B<< on_event => $cb->($handle, $data) >>

Called when an event has been received.
$data is a reference to a hash representing the event.

See L<the Gerrit
documentation|http://gerrit.googlecode.com/svn/documentation/2.2.1/cmd-stream-events.html>
for information on the possible events.

=item B<< on_error => $cb->($handle, $error) >>

Called when an error occurs in the connection.
$error is a human-readable string.

Examples of errors include network disruptions between your host and
the Gerrit server, or the ssh process being killed
unexpectedly. Receiving any kind of error means that some Gerrit
events may have been lost.

If this callback returns a true value, stream_events will attempt to
reconnect to Gerrit and resume processing; otherwise, the connection
is terminated and no more events will occur.

The default error callback will warn and return 1, retrying on all
errors.

=back

=cut

sub stream_events {
  my (%args) = @_;

  my $url      = $args{url}      || croak 'missing url argument';
  my $on_event = $args{on_event} || croak 'missing on_event argument';
  my $on_error = $args{on_error} || sub {
    my ( undef, $error ) = @_;
    warn __PACKAGE__ . ": $error\n";
    return 1;
  };

  my $INIT_SLEEP = 2;
  my $MAX_SLEEP  = 60 * 10;
  my $sleep      = $INIT_SLEEP;

  my @ssh = ( @{ _gerrit_parse_url($url)->{cmd} }, 'stream-events' );

  my $cleanup = sub {
    my ($handle) = @_;
    delete $handle->{timer};
    foreach my $key (qw(r_h r_h_stderr)) {
      if ( my $r_h = delete $handle->{$key} ) {
        $r_h->destroy();
      }
    }
    if ( my $cv = delete $handle->{cv} ) {
      $cv->cb( sub { } );
      if ( my $pid = $handle->{pid} ) {
        kill( 15, $pid );
      }
    }
  };

  my $restart;
  my $out_weak;

  my $handle_error = sub {
    my ( $handle, $error ) = @_;
    my $retry;
    eval { $retry = $on_error->( $out_weak, $error ); };
    if ($retry) {

      # retry after $sleep seconds only
      $handle->{timer} =
        AnyEvent->timer( after => $sleep, cb => sub { $restart->($handle) } );
      $sleep *= 2;
      if ( $sleep > $MAX_SLEEP ) {
        $sleep = $MAX_SLEEP;
      }
    }
    else {
      $cleanup->($handle);
    }
  };

  $restart = sub {
    my ($handle) = @_;
    $cleanup->($handle);

    $sleep = $INIT_SLEEP;

    my ( $r,  $w )  = portable_pipe();
    my ( $r2, $w2 ) = portable_pipe();

    $handle->{r_h} = AnyEvent::Handle->new( fh => $r, );
    $handle->{r_h}->on_error(
      sub {
        my ( undef, undef, $error ) = @_;
        $handle_error->( $handle, $error );
      }
    );
    $handle->{r_h_stderr} = AnyEvent::Handle->new( fh => $r2, );
    $handle->{r_h_stderr}->on_error( sub { } );
    $handle->{warn_on_stderr} = 1;

    # run stream-events with stdout connected to pipe ...
    $handle->{cv} = run_cmd(
      \@ssh,
      '>'  => $w,
      '2>' => $w2,
      '$$' => \$handle->{pid},
    );
    $handle->{cv}->cb(
      sub {
        my ($status) = shift->recv();
        $handle_error->( $handle, "ssh exited with status $status" );
      }
    );

    my %read_req;
    %read_req = (

      # read one json item at a time
      json => sub {
        my ( $h, $data ) = @_;

        # every successful read resets sleep period
        $sleep = $INIT_SLEEP;

        $on_event->( $out_weak, $data );
        $h->push_read(%read_req);
      }
    );
    $handle->{r_h}->push_read(%read_req);

    my %err_read_req;
    %err_read_req = (
      line => sub {
        my ( $h, $line ) = @_;

        if ( $handle->{warn_on_stderr} ) {
          warn __PACKAGE__ . ': ssh stderr: ' . $line;
        }
        $h->push_read(%err_read_req);
      }
    );
    $handle->{r_h_stderr}->push_read(%err_read_req);
  };

  my $stash = {};
  $restart->($stash);

  my $out = { stash => $stash };
  if ( defined wantarray ) {
    $out->{guard} = guard {
      $cleanup->($stash);
    };
    $out_weak = $out;
    weaken($out_weak);
  }
  else {
    $out_weak = $out;
  }
  return $out;
}

=item B<< for_each_patch(url => $url, workdir => $workdir, ...) >>

Set up a high-level event watcher to invoke a custom callback or
command for each existing or incoming patch set on Gerrit. This method
is suitable for performing automated testing or sanity checks on
incoming patches.

For each patch set, a git repository is set up with the working tree
and HEAD set to the patch. The callback is invoked with the current
working directory set to the top level of this git repository.

Returns a guard object. Event processing terminates when the object is
destroyed.

Options:

=over

=item B<url>

The Gerrit ssh URL, e.g. C<ssh://user@gerrit.example.com:29418/>. Mandatory.

=item B<workdir>

The top-level working directory under which git repositories and other data
should be stored. Mandatory. Will be created if it does not exist.

The working directory is persistent across runs. Removing the
directory may cause the processing of patch sets which have already
been processed.

=item B<< on_patch => $sub->($change, $patchset) >>

=item B<< on_patch_fork => $sub->($change, $patchset) >>

=item B<< on_patch_cmd> => $sub->($change, $patchset) | $cmd_ref >>

Callbacks invoked for each patch. Only one of the above callback forms
may be used.

=over

=item *

B<on_patch> invokes a subroutine in the current process. The callback
is blocking, which means that only one patch may be processed at a
time. This is the simplest form and is suitable when the processing
for each patch is expected to be fast or the rate of incoming patches
is low.

=item *

B<on_patch_fork> invokes a subroutine in a new child process. The
child terminates when the callback returns. Multiple patches may be
handled in parallel.

The caveats which apply to C<AnyEvent::Util::run_cmd> also apply here;
namely, it is not permitted to run the event loop in the child process.

=item *

B<on_patch_cmd> runs a command to handle the patch.
Multiple patches may be handled in parallel.

The argument to B<on_patch_cmd> may be either a reference to an array
holding the command and its arguments, or a reference to a subroutine
which generates and returns an array for the command and its arguments.

=back

All on_patch callbacks receive B<change> and B<patchset> hashref arguments.
Note that a change may hold several patchsets.

=item B<< review => 0 | 1 | 'code-review' | 'verified' | ... >>

If false (the default), patch sets are not automatically reviewed
(though they may be reviewed explicitly within the B<on_patch_...>
callbacks).

If true, any output (stdout or stderr) from the B<on_patch_...> callback
will be captured and posted as a review message. If there is no output,
no message is posted.

If a string is passed, it is construed as a Gerrit approval category
and a review score will be posted in that category. The score comes
from the return value of the callback (or exit code in the case of
B<on_patch_cmd>).

=back

=cut
sub for_each_patch {
  my (%args) = @_;

  $args{url} || croak 'missing url argument';
  $args{on_patch}
    || $args{on_patch_cmd}
    || $args{on_patch_fork}
    || croak 'missing on_patch{_cmd,_fork} argument';
  $args{workdir} || croak 'missing workdir argument';
  $args{on_error} ||= sub { warn __PACKAGE__, ': ', @_ };

  if ( !-d $args{workdir} ) {
    mkpath( $args{workdir} );
  }

  my $self = bless {}, __PACKAGE__;
  $self->{args} = \%args;

  my $weakself = $self;
  weaken($weakself);

  $self->{stream} = Gerrit::Client::stream_events(
    url      => $args{url},
    on_event => sub {
      $weakself->_handle_for_each_event( $_[1] );
    },

    # TODO: on error, issue a query to automatically find any missed changes?
  );

  return $self;
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

sub _dequeue {
  my ($self) = @_;

  if ($DEBUG) {
    _debug_print 'queue before processing: ', Dumper( $self->{queue} );
  }

  my $weakself = $self;
  weaken($weakself);

  my @newqueue;
  foreach my $event ( @{ $self->{queue} || [] } ) {
    my $project = $event->{change}{project};
    my $ref     = $event->{patchSet}{ref};

    my $giturl = "$self->{args}{url}/$project";
    my $gitdir = "$self->{args}{workdir}/$project/git";

    if ( !-d $gitdir ) {
      if ( !$self->{git_clone_cv}{$gitdir} ) {
        $self->{git_clone_cv}{$gitdir} = run_cmd(
          [ 'git', 'clone', '--bare', $giturl, $gitdir ],
          '>'  => sub { _debug_print( "git clone $giturl: ", @_ ) },
          '2>' => sub { _debug_print( "git clone $giturl: ", @_ ) },
        );
        $self->{git_clone_cv}{$gitdir}->cb(
          sub {
            my ($cv) = @_;
            my $status = $cv->recv();
            if ( $status != 0 ) {
              warn __PACKAGE__
                . ": git clone for $gitdir exited with status $status";
            }
            $weakself->_dequeue();
          }
        );
        push @newqueue, $event;
        next;
      }
      elsif ( !$self->{git_clone_cv}{$gitdir}->ready ) {
        push @newqueue, $event;
        next;
      }
      warn __PACKAGE__
        . ": dropped event for $project $ref, git clone did not create $gitdir\n";
      next;
    }

    if ( !$event->{_fetched} ) {
      if ( !$event->{_fetch_cv} ) {
        $event->{_fetch_cv} = AnyEvent::Util::run_cmd(
          [ 'git', '--git-dir', $gitdir, 'fetch', '-v', $giturl, "+$ref:$ref" ],
          '>'  => sub { _debug_print( "git fetch $giturl: ", @_ ) },
          '2>' => sub { _debug_print( "git fetch $giturl: ", @_ ) },
        );
        $event->{_fetch_cv}->cb(
          sub {
            my ($cv) = @_;
            my $status = $cv->recv();
            if ($status) {
              warn __PACKAGE__
                . ": git fetch $ref from $giturl exited with status $status\n";
            }
            else {
              $event->{_fetched} = 1;
            }
            $weakself->_dequeue();
          }
        );
        push @newqueue, $event;
        next;
      }
      elsif ( !$event->{_fetch_cv}->ready ) {
        push @newqueue, $event;
        next;
      }
      else {
        warn __PACKAGE__
          . ": dropped event for $project $ref due to failed git fetch\n";
        next;
      }
    }

    $event->{_workdir} ||=
      File::Temp->newdir("$self->{args}{workdir}/$project/work.XXXXXX");

    if ( !-d "$event->{_workdir}/.git" ) {
      my $status =
        _system( 'git', 'clone', '--quiet', $gitdir, $event->{_workdir} );
      if ($status) {
        $self->{args}{on_error}->(
          "cloning $gitdir to $event->{_workdir} exited with status $status");
        return;
      }
      local $CWD = $event->{_workdir};
      $status = _system( 'git', 'fetch', '--quiet', 'origin', "+$ref:$ref" );
      if ($status) {
        $self->{args}{on_error}
          ->("fetching $ref into $CWD exited with status $status");
        return;
      }

      $status = _system( 'git', 'reset', '--quiet', '--hard', $ref );
      if ($status) {
        $self->{args}{on_error}
          ->("reset to $ref in $CWD exited with status $status");
        return;
      }
    }

    if ( $self->{args}{on_patch} ) {
      local $CWD = $event->{_workdir};
      $self->{args}{on_patch}->( $event->{change}, $event->{patchSet} );
      next;
    }
    elsif ( $self->{args}{on_patch_fork} ) {
      if ( !$event->{_forked} ) {
        $event->{_forked} = 1;
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

  if ($DEBUG) {
    _debug_print 'queue after processing: ', Dumper( $self->{queue} );
  }

  return;
}


=item B<random_change_id>

Returns a random Change-Id (the character 'I' followed by 40
hexadecimal digits), suitable for usage as the Change-Id field in a
commit to be pushed to gerrit.

=cut
sub random_change_id {
  return 'I' . sprintf(

    # 40 hex digits, one 32 bit integer gives 8 hex digits,
    # therefore 5 random integers
    "%08x" x 5,
    map { rand() * ( 2**32 ) } ( 1 .. 5 )
  );
}

=item B<next_change_id>

Returns the 'next' Change-Id which should be used for a commit created
by the current git author/committer (which should be set by
L<git_environment|/git_environment-name-name-email-email-author_only-0-1->
prior to calling this method). The current working directory must be
within a git repository.

This method is suitable for usage within a script which periodically
creates commits for review, but should have only one outstanding
review (per branch) at any given time.  The returned Change-Id is
(hopefully) unique, and stable; it only changes when a new commit
arrives in the git repository from the current script.

For example, consider a script which is run once per day to clone a
repository, generate a change and push it for review. If this function
is used to generate the Change-Id on the commit, the script will
update the same change in gerrit until that change is merged. Once the
change is merged, next_change_id returns a different value, resulting
in a new change.  This ensures the script has a maximum of one pending
review any given time.

If any problems occur while determining the next Change-Id, a warning
is printed and a random Change-Id is returned.

=cut
sub next_change_id {
  if ( !$ENV{GIT_AUTHOR_NAME} || !$ENV{GIT_AUTHOR_EMAIL} ) {
    carp __PACKAGE__ . ': git environment is not set, using random Change-Id';
    return random_change_id();
  }

  # First preference: change id is the last SHA used by this bot.
  my $author    = "$ENV{GIT_AUTHOR_NAME} <$ENV{GIT_AUTHOR_EMAIL}>";
  my $change_id = qx(git rev-list -n1 --fixed-strings "--author=$author" HEAD);
  if ( my $error = $? ) {
    carp __PACKAGE__ . qq{: no previous commits from "$author" were found};
  }
  else {
    chomp $change_id;
  }

  # Second preference: for a stable but random change-id, use hash of the
  # bot name
  if ( !$change_id ) {
    $change_id = qx(echo "$author" | git hash-object --stdin);
    if ( my $error = $? ) {
      carp __PACKAGE__ . qq{: git hash-object failed};
    }
    else {
      chomp $change_id;
    }
  }

  # Check if we seem to have this change id already.
  # This can happen if an author other than ourself has already used the
  # change id.
  if ($change_id) {
    my $found = qx(git log -n1000 "--grep=I$change_id" HEAD);
    if ( !$? && $found ) {
      carp __PACKAGE__ . qq{: desired Change-Id $change_id is already used};
      undef $change_id;
    }
  }

  if ($change_id) {
    return "I$change_id";
  }

  carp __PACKAGE__ . q{: falling back to random Change-Id};

  return random_change_id();
}

=item B<< git_environment(name => $name, email => $email,
                          author_only => [0|1] ) >>

Returns a copy of %ENV modified suitably for the creation of git
commits by a script/bot.

Options:

=over

=item B<name>

The human-readable name used for git commits. Mandatory.

=item B<email>

The email address used for git commits. Mandatory.

=item B<author_only>

If 1, the environment is only modified for the git I<author>, and not
the git I<committer>.  Depending on the gerrit setup, this may be
required to avoid complaints about missing "Forge Identity"
permissions.

Defaults to 0.

=back

When generating commits for review in gerrit, this method may be used
in conjunction with L</next_change_id> to ensure this bot has only one
outstanding change for review at any time, as in the following
example:

    local %ENV = git_environment(
        name => 'Indent Bot',
        email => 'indent-bot@example.com',
    );

    # fix up indenting in all the .cpp files
    (system('indent *.cpp') == 0) || die 'indent failed';

    # then commit and push them; commits are authored and committed by
    # 'Indent Bot <indent-bot@example.com>'.  usage of next_change_id()
    # ensures that this bot has a maximum of one outstanding change for
    # review
    my $message = "Fixed indentation\n\nChange-Id: ".next_change_id();
    (system('git add -u *.cpp') == 0)
      || die 'git add failed';
    (system('git', 'commit', '-m', $message) == 0)
      || die 'git commit failed';
    (system('git push gerrit HEAD:refs/for/master') == 0)
      || die 'git push failed';

=cut
sub git_environment {
  my (%options) = validate(
    @_,
    { name        => 1,
      email       => 1,
      author_only => 0,
    }
  );

  my %env = %ENV;

  $env{GIT_AUTHOR_NAME}  = $options{name};
  $env{GIT_AUTHOR_EMAIL} = $options{email};

  unless ( $options{author_only} ) {
    $env{GIT_COMMITTER_NAME}  = $options{name};
    $env{GIT_COMMITTER_EMAIL} = $options{email};
  }

  return %env;
}

# options to Gerrit::review which map directly to options to
# "ssh <somegerrit> gerrit review ..."
my %GERRIT_REVIEW_OPTIONS = (
  abandon => { type => BOOLEAN, default => 0 },
  message => { type => SCALAR,  default => undef },
  project => { type => SCALAR,  default => undef },
  restore => { type => BOOLEAN, default => 0 },
  stage   => { type => BOOLEAN, default => 0 },
  submit  => { type => BOOLEAN, default => 0 },
  ( map { $_ => { regex => qr{^[-+]?\d+$}, default => undef } }
      qw(
      code_review
      sanity_review
      verified
      )
  )
);

=item B<< review $commit_or_change, url => $gerrit_url, ... >>

Wrapper for the `gerrit review' command; add a comment and/or update the status
of a change in gerrit.

$commit_or_change is mandatory, and is either a git commit (in
abbreviated or full 40-digit form), or a gerrit change number and
patch set separated by a comment (e.g. 3404,3 refers to patch set 3 of
the gerrit change accessible at http://gerrit.example.com/3404). The
latter form is deprecated and may be removed in some version of
gerrit.

$gerrit_url is also mandatory and should be a URL with ssh schema referring to a
valid Gerrit installation (e.g. "ssh://user@gerrit.example.com:29418/").
The URL may optionally contain the relevant gerrit project.

All other arguments are optional, and include:

=over

=item B<< on_success => $cb->( $commit_or_change ) >>

=item B<< on_error => $cb->( $commit_or_change, $error ) >>

Callbacks invoked when the operation succeeds or fails.

=item B<< abandon => 1|0 >>

=item B<< message => $string >>

=item B<< project => $string >>

=item B<< restore => 1|0 >>

=item B<< stage => 1|0 >>

=item B<< submit => 1|0 >>

=item B<< code_review => $number >>

=item B<< sanity_review => $number >>

=item B<< verified => $number >>

These options are passed to the `gerrit review' command.  For
information on their usage, please see the output of `gerrit review
--help' on your gerrit installation, or see L<the Gerrit
documentation|http://gerrit.googlecode.com/svn/documentation/2.2.1/cmd-review.html>.

Note that certain options can be disabled on a per-site basis.
`gerrit review --help' will show only those options which are enabled
on the given site.

=back

=cut
sub review {
  my $commit_or_change = shift;
  my (%options) = validate(
    @_,
    { url        => 1,
      on_success => { type => CODEREF, default => undef },
      on_error   => {
        type    => CODEREF,
        default => sub {
          my ( $c, @rest ) = @_;
          warn __PACKAGE__ . "::review: error (for $c): ", @rest;
          }
      },
      %GERRIT_REVIEW_OPTIONS,
    }
  );

  my $parsed_url = _gerrit_parse_url( $options{url} );
  my @cmd = ( @{ $parsed_url->{cmd} }, 'review', $commit_or_change, );

  # project can be filled in by explicit 'project' argument, or from
  # URL, or left blank
  $options{project} ||= $parsed_url->{project};
  if (!$options{project}) {
    delete $options{project};
  }

  while ( my ( $key, $spec ) = each %GERRIT_REVIEW_OPTIONS ) {
    my $value = $options{$key};

    # code_review -> --code-review
    my $cmd_key = $key;
    $cmd_key =~ s{_}{-}g;
    $cmd_key = "--$cmd_key";

    if ( $spec->{type} && $spec->{type} eq BOOLEAN ) {
      if ($value) {
        push @cmd, $cmd_key;
      }
    }
    elsif ( defined($value) ) {
      push @cmd, $cmd_key, _quote_gerrit_arg($value);
    }
  }

  my $cv = AnyEvent::Util::run_cmd( \@cmd );

  my $cmdstr;
  {
    local $LIST_SEPARATOR = '] [';
    $cmdstr = "[@cmd]";
  }

  $cv->cb(
    sub {
      my $status = shift->recv();
      if ( $status && $options{on_error} ) {
        $options{on_error}
          ->( $commit_or_change, "$cmdstr exited with status $status" );
      }
      if ( !$status && $options{on_success} ) {
        $options{on_success}->($commit_or_change);
      }

      # make sure we stay alive until this callback is executed
      undef $cv;
    }
  );

  return;
}

=back

=head1 VARIABLES

=over

=item B<@Gerrit::Client::SSH>

The ssh command and initial arguments used when Gerrit::Client invokes
ssh.

  # force IPv6 for this connection
  local @Gerrit::Client::SSH = ('ssh', '-oAddressFamily=inet6');
  my $stream = Gerrit::Client::stream_events ...

The default value is C<('ssh')>.

=back

=head1 AUTHOR

Rohan McGovern, <rohan@mcgovern.id.au>

=head1 BUGS

Please use L<http://rt.cpan.org/> to view or report bugs.

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2012 Rohan McGovern <rohan@mcgovern.id.au>

Copyright (C) 2012 Digia Plc and/or its subsidiary(-ies)

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU Lesser General Public License version
2.1 as published by the Free Software Foundation.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
USA.

=cut

1;
