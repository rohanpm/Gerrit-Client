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
      my ($event) = @_;
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
use Capture::Tiny qw(capture);
use Carp;
use Data::Alias;
use Data::Dumper;
use English qw(-no_match_vars);
use File::Path;
use File::Spec::Functions;
use File::Temp;
use File::chdir;
use JSON;
use Params::Validate qw(:all);
use Scalar::Util qw(weaken);
use URI;

use base 'Exporter';
our @EXPORT_OK = qw(
  for_each_patchset
  stream_events
  git_environment
  next_change_id
  random_change_id
  review
  query
  quote
);

our @GIT             = ('git');
our @SSH             = ('ssh');
our $VERSION         = 20121218;
our $DEBUG           = !!$ENV{GERRIT_CLIENT_DEBUG};
our $MAX_CONNECTIONS = 2;
our $MAX_FORKS       = 4;

sub _debug_print {
  return unless $DEBUG;
  print STDERR __PACKAGE__ . ': ', @_, "\n";
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
  $url->path(undef);

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
    gerrit => $url->as_string(),
  };
}

# Like qx, but takes a list, so no quoting issues
sub _safeqx {
  my (@cmd) = @_;
  my $status;
  my $output = capture { $status = system(@cmd) };
  $? = $status;
  return $output;
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

=item B<< on_event => $cb->($data) >>

Called when an event has been received.
$data is a reference to a hash representing the event.

See L<the Gerrit
documentation|http://gerrit.googlecode.com/svn/documentation/2.2.1/cmd-stream-events.html>
for information on the possible events.

=item B<< on_error => $cb->($error) >>

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
    my ($error) = @_;
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
    eval { $retry = $on_error->($error); };
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

        $on_event->($data);
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

=item B<< for_each_patchset(url => $url, workdir => $workdir, ...) >>

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

=item B<< on_patchset => $sub->($change, $patchset) >>

=item B<< on_patchset_fork => $sub->($change, $patchset) >>

=item B<< on_patchset_cmd => $sub->($change, $patchset) | $cmd_ref >>

Callbacks invoked for each patchset. Only one of the above callback
forms may be used.

=over

=item *

B<on_patchset> invokes a subroutine in the current process. The callback
is blocking, which means that only one patch may be processed at a
time. This is the simplest form and is suitable when the processing
for each patch is expected to be fast or the rate of incoming patches
is low.

=item *

B<on_patchset_fork> invokes a subroutine in a new child process. The
child terminates when the callback returns. Multiple patches may be
handled in parallel.

The caveats which apply to C<AnyEvent::Util::run_cmd> also apply here;
namely, it is not permitted to run the event loop in the child process.

=item *

B<on_patchset_cmd> runs a command to handle the patch.
Multiple patches may be handled in parallel.

The argument to B<on_patchset_cmd> may be either a reference to an array
holding the command and its arguments, or a reference to a subroutine
which generates and returns an array for the command and its arguments.

=back

All on_patchset callbacks receive B<change> and B<patchset> hashref arguments.
Note that a change may hold several patchsets.

=item B<< on_error => $sub->($error) >>

Callback invoked when an error occurs. $error is a human-readable error string.

All errors are treated as recoverable. To abort on an error, explicitly undefine
the loop guard object from within the callback.

By default, a warning message is printed for each error.

=item B<< review => 0 | 1 | 'code-review' | 'verified' | ... >>

If false (the default), patch sets are not automatically reviewed
(though they may be reviewed explicitly within the B<on_patchset_...>
callbacks).

If true, any output (stdout or stderr) from the B<on_patchset_...> callback
will be captured and posted as a review message. If there is no output,
no message is posted.

If a string is passed, it is construed as a Gerrit approval category
and a review score will be posted in that category. The score comes
from the return value of the callback (or exit code in the case of
B<on_patchset_cmd>).

=item B<< on_review => $sub->( $change, $patchset, $message, $score ) >>

Optional callback invoked prior to performing a review (when the `review'
option is set to a true value).

The callback should return a true value if the review should be
posted, false otherwise. This may be useful for the implementation of
a dry-run mode.

The callback may be invoked with an undefined $message and $score, which
indicates that a patchset was successfully processed but no message
or score was produced.

=item B<< wanted => $sub->( $change, $patchset ) >>

The optional `wanted' subroutine may be used to limit the patch sets processed.

If given, a patchset will only be processed if this callback returns a
true value. This can be used to avoid git clones of unwanted projects.

For example, patchsets for all Gerrit projects under a 'test/' namespace could
be excluded from processing by the following:

    wanted => sub { $_[0]->{project} !~ m{^test/} }

=item B<< git_work_tree => 0 | 1 >>

By default, while processing a patchset, a git work tree is set up
with content set to the appropriate revision.

C<< git_work_tree => 0 >> may be passed to disable the work tree, saving
some time and disk space. In this case, a bare clone is used, with HEAD
referring to the revision to be processed.

This may be useful when the patch set processing does not require a
work tree (e.g. the incoming patch is directly scanned).

Defaults to 1.

=item B<< query => $query | 0 >>

The Gerrit query used to find the initial set of patches to be
processed.  The query is executed when the loop begins and whenever
the connection to Gerrit is interrupted, to avoid missed patchsets.

Defaults to "status:open", meaning every open patch will be processed.

Note that the query is not applied to incoming patchsets observed via
stream-events. The B<wanted> parameter may be used for that case.

If a false value is passed, querying is disabled altogether. This
means only patchsets arriving while the loop is running will be
processed.

=back

=cut

sub for_each_patchset {
  my (%args) = @_;

  $args{url} || croak 'missing url argument';
       $args{on_patchset}
    || $args{on_patchset_cmd}
    || $args{on_patchset_fork}
    || croak 'missing on_patchset{_cmd,_fork} argument';
  $args{workdir} || croak 'missing workdir argument';
  $args{on_error} ||= sub { warn __PACKAGE__, ': ', @_ };

  if ( !exists( $args{git_work_tree} ) ) {
    $args{git_work_tree} = 1;
  }

  if ( !exists( $args{query} ) ) {
    $args{query} = 'status:open';
  }

  if ( !-d $args{workdir} ) {
    mkpath( $args{workdir} );
  }

  # drop the path section of the URL to get base gerrit URL
  my $url = URI->new($args{url});
  $url->path( undef );
  $args{url} = $url->as_string();

  require "Gerrit/Client/ForEach.pm";
  my $self = bless {}, 'Gerrit::Client::ForEach';
  $self->{args} = \%args;

  my $weakself = $self;
  weaken($weakself);

  # stream_events takes care of incoming changes, perform a query to find
  # existing changes
  my $do_query = sub {
    return unless $args{query};

    query(
      $args{query},
      url               => $args{url},
      current_patch_set => 1,
      on_error          => sub { $args{on_error}->(@_) },
      on_success        => sub {
        return unless $weakself;
        my (@results) = @_;
        foreach my $change (@results) {

          # simulate patch set creation
          my ($event) = {
            type     => 'patchset-created',
            change   => $change,
            patchSet => delete $change->{currentPatchSet},
          };
          $weakself->_handle_for_each_event($event);
        }
      },
    );
  };

  # Unfortunately, we have no idea how long it takes between starting the
  # stream-events command and when the streaming of events begins, so if
  # we query straight away, we could miss some changes which arrive while
  # stream-events is e.g. still in ssh negotiation.
  # Therefore, introduce this arbitrary delay between when we start
  # stream-events and when we'll perform a query.
  my $query_timer;
  my $do_query_soon = sub {
    $query_timer = AE::timer( 4, 0, $do_query );
  };

  $self->{stream} = Gerrit::Client::stream_events(
    url      => $args{url},
    on_event => sub {
      $weakself->_handle_for_each_event(@_);
    },
    on_error => sub {
      my ($error) = @_;

      $args{on_error}->("connection lost: $error, attempting to recover\n");

      # after a few seconds to allow reconnect, perform the base query again
      $do_query_soon->();

      return 1;
    },
  );

  $do_query_soon->();

  return $self;
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
  my $change_id = _safeqx( @GIT, qw(rev-list -n1 --fixed-strings),
    "--author=$author", 'HEAD' );
  if ( my $error = $? ) {
    carp __PACKAGE__ . qq{: no previous commits from "$author" were found};
  }
  else {
    chomp $change_id;
  }

  # Second preference: for a stable but random change-id, use hash of the
  # bot name
  if ( !$change_id ) {
    my $tempfile = File::Temp->new(
      'perl-Gerrit-Client-hash.XXXXXX',
      TMPDIR  => 1,
      CLEANUP => 1
    );
    $tempfile->printflush($author);
    $change_id = _safeqx( @GIT, 'hash-object', "$tempfile" );
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
    my $found = _safeqx( @GIT, 'log', '-n1000', "--grep=I$change_id", 'HEAD' );
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

=item B<< on_success => $cb->() >>

=item B<< on_error => $cb->( $error ) >>

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
          warn __PACKAGE__ . "::review: error: ", @_;
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
  if ( !$options{project} ) {
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
      push @cmd, $cmd_key, quote($value);
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
        $options{on_error}->("$cmdstr exited with status $status");
      }
      if ( !$status && $options{on_success} ) {
        $options{on_success}->();
      }

      # make sure we stay alive until this callback is executed
      undef $cv;
    }
  );

  return;
}

# options to Gerrit::Client::query which map directly to options to
# "ssh <somegerrit> gerrit query ..."
my %GERRIT_QUERY_OPTIONS = (
  ( map { $_ => { type => BOOLEAN, default => 0 } }
      qw(
      all_approvals
      comments
      commit_message
      current_patch_set
      dependencies
      files
      patch_sets
      submit_records
      )
  )
);

=item B<< query $query, url => $gerrit_url, ... >>

Wrapper for the `gerrit query' command; send a query to gerrit
and invoke a callback with the results.

$query is the Gerrit query string, whose format is described in L<the
Gerrit
documentation|https://gerrit.googlecode.com/svn/documentation/2.2.1/user-search.html>.
"status:open age:1w" is an example of a simple Gerrit query.

$url is the URL with ssh schema of the Gerrit site to be queried
(e.g. "ssh://user@gerrit.example.com:29418/").
If the URL contains a path (project) component, it is ignored.

All other arguments are optional, and include:

=over

=item B<< on_success => $cb->( @results ) >>

Callback invoked when the query completes.

Each element of @results is a hashref representing a Gerrit change,
parsed from the JSON output of `gerrit query'. The format of Gerrit
change objects is described in L<the Gerrit documentation|
https://gerrit.googlecode.com/svn/documentation/2.2.1/json.html>.

=item B<< on_error => $cb->( $error ) >>

Callback invoked when the query command fails.
$error is a human-readable string describing the error.

=item B<< all_approvals => 0|1 >>

=item B<< comments => 0|1 >>

=item B<< commit_message => 0|1 >>

=item B<< current_patch_set => 0|1 >>

=item B<< dependencies => 0|1 >>

=item B<< files => 0|1 >>

=item B<< patch_sets => 0|1 >>

=item B<< submit_records => 0|1 >>

These options are passed to the `gerrit query' command and may be used
to increase the level of information returned by the query.
For information on their usage, please see the output of `gerrit query
--help' on your gerrit installation, or see L<the Gerrit
documentation|http://gerrit.googlecode.com/svn/documentation/2.2.1/cmd-query.html>.

=back

=cut

sub query {
  my $query = shift;
  my (%options) = validate(
    @_,
    { url        => 1,
      on_success => { type => CODEREF, default => undef },
      on_error   => {
        type    => CODEREF,
        default => sub {
          warn __PACKAGE__ . "::query: error: ", @_;
          }
      },
      %GERRIT_QUERY_OPTIONS,
    }
  );

  my $parsed_url = _gerrit_parse_url( $options{url} );
  my @cmd = ( @{ $parsed_url->{cmd} }, 'query', '--format', 'json' );

  while ( my ( $key, $spec ) = each %GERRIT_QUERY_OPTIONS ) {
    my $value = $options{$key};
    next unless $value;

    # some_option -> --some-option
    my $cmd_key = $key;
    $cmd_key =~ s{_}{-}g;
    $cmd_key = "--$cmd_key";

    push @cmd, $cmd_key;
  }

  push @cmd, quote($query);

  my $output;
  my $cv = AnyEvent::Util::run_cmd( \@cmd, '>' => \$output );

  my $cmdstr;
  {
    local $LIST_SEPARATOR = '] [';
    $cmdstr = "[@cmd]";
  }

  $cv->cb(
    sub {
      # make sure we stay alive until this callback is executed
      undef $cv;

      my $status = shift->recv();
      if ( $status && $options{on_error} ) {
        $options{on_error}->("$cmdstr exited with status $status");
        return;
      }

      return unless $options{on_success};

      my @results;
      foreach my $line ( split /\n/, $output ) {
        my $data = eval { decode_json($line) };
        if ($EVAL_ERROR) {
          $options{on_error}->("error parsing result `$line': $EVAL_ERROR");
          return;
        }
        next if ( $data->{type} && $data->{type} eq 'stats' );
        push @results, $data;
      }

      $options{on_success}->(@results);
      return;
    }
  );

  return;
}

=item B<< quote $string >>

Returns a copy of the input string with special characters escaped, suitable
for usage with Gerrit CLI commands.

Gerrit commands run via ssh typically need extra quoting because the ssh layer
already evaluates the command string prior to passing it to Gerrit.
This function understands how to quote arguments for this case.

B<Note:> do not use this function for passing arguments to other Gerrit::Client
functions; those perform appropriate quoting internally.

=cut

sub quote {
  my ($string) = @_;

  # character set comes from gerrit source:
  # gerrit-sshd/src/main/java/com/google/gerrit/sshd/CommandFactoryProvider.java
  # 'split' function
  $string =~ s{([\t "'\\])}{\\$1}g;
  return $string;
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

=item B<@Gerrit::Client::GIT>

The git command and initial arguments used when Gerrit::Client invokes
git.

  # use a local object cache to speed up initial clones
  local @Gerrit::Client::GIT = ('env', "GIT_ALTERNATE_OBJECT_DIRECTORIES=$ENV{HOME}/gitcache", 'git');
  my $guard = Gerrit::Client::for_each_patchset ...

The default value is C<('git')>.

=item B<$Gerrit::Client::MAX_CONNECTIONS>

Maximum number of simultaneous git connections Gerrit::Client may make
to a single Gerrit server. The amount of parallel git clones and
fetches should be throttled, otherwise the Gerrit server may drop
incoming connections.

The default value is C<2>.

=item B<$Gerrit::Client::MAX_FORKS>

Maximum number of processes allowed to run simultaneously for handling
of patchsets in for_each_patchset. This limit applies only to local
work processes, not git clones or fetches from gerrit.

Note that C<$AnyEvent::Util::MAX_FORKS> may also impact the maximum number
of processes. C<$AnyEvent::Util::MAX_FORKS> should be set higher than or
equal to C<$Gerrit::Client::MAX_FORKS>.

The default value is C<4>.

=item B<$Gerrit::Client::DEBUG>

If set to a true value, various debugging messages will be printed to
standard error.  May be set by the GERRIT_CLIENT_DEBUG environment
variable.

=back

=head1 AUTHOR

Rohan McGovern, <rohan@mcgovern.id.au>

=head1 BUGS

Please use L<http://rt.cpan.org/> to view or report bugs.

When reporting a reproducible bug, please include the output of your
program with the environment variable GERRIT_CLIENT_DEBUG set to 1.

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
