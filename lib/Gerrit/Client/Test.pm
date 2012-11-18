#############################################################################
##
## Copyright (C) 2012 Rohan McGovern <rohan@mcgovern.id.au>
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

Gerrit::Client::Test - test helpers for Gerrit::Client

=head1 DESCRIPTION

This package provides various utilities written for testing of the
Gerrit::Client package. It is not intended for general use and the interface is
subject to change.

Gerrit::Client::Test may be used to install and manage a local Gerrit instance
for the purpose of running system tests.

=cut

package Gerrit::Client::Test;

use strict;
use warnings;

use AnyEvent::Socket;
use Capture::Tiny qw(capture_merged capture);
use English;
use File::Path;
use File::Temp;
use File::chdir;
use LWP::UserAgent;
use Test::More;
use autodie;

# like system(), but fail test and diag() the output if the command fails
sub _system_or_fail {
  my (@cmd) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  my $status;
  my ($out) = capture_merged { $status = system(@cmd) };
  if ( $status != 0 ) {
    diag($out);
  }
  return is( $status, 0 );
}

# Returns a TCP port which, at the time of the call, can be bound on 127.0.0.1
sub _find_available_tcp_port {
  my $port;
  my $guard = tcp_server '127.0.0.1', 0, sub { }, sub {
    $port = $_[2];
  };
  return $port;
}

# Fetches the given $url to a local File::Temp, which is returned.
sub _fetch_remote {
  my ($url) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  my $file = File::Temp->new(
    TEMPLATE => 'Gerrit-Client-war.XXXXXX',
    TMPDIR   => 1,
    CLEANUP  => 1
  );

  my $ua = LWP::UserAgent->new();
  diag("Downloading $url ...");
  my $response = $ua->get( $url, ':content_file' => "$file" );
  if ( !ok( $response->is_success(), "can fetch $url" ) ) {
    diag( $response->status_line() . "\n" . $response->decoded_content() );
    return;
  }

  return $file;
}

# Get or set some gerrit config
sub _gerrit_config {
  my ( $key, $value ) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my @cmd = ( 'git', 'config', '-f', 'etc/gerrit.config', $key );
  if ( defined($value) ) {
    push @cmd, $value;
    return _system_or_fail(@cmd);
  }
  my $status;
  my ( $out, $err ) = capture {
    $status = system(@cmd);
  };
  if ( !is( $status, 0, "retrieve gerrit config $key OK" ) ) {
    diag($err);
    return;
  }
  chomp $out;
  return $out;
}

# Returns a string suitable for usage as an Authorization header
# for the given $username and $password, using HTTP Basic authentication
sub _http_basic_auth {
  my ( $username, $password ) = @_;

  use MIME::Base64;
  return 'Basic ' . encode_base64("$username:$password");
}

# Creates a gerrit user account with the given $username and $password;
# this relies on gerrit being set up such that logging in automatically
# creates an account, which is true for HTTP authentication.
sub _create_gerrit_user {
  my ( $self, $username, $password ) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  $password ||= $username;

  return unless $self->ensure_gerrit_running();

  diag("Creating gerrit user $username ...");

  my $auth = _http_basic_auth( $username, $password );
  my $response = LWP::UserAgent->new()
    ->get( $self->{http_url} . '/login/mine', Authorization => $auth );

  ok( $response->is_success(), "user $username created" )
    || diag( $response->status_line() . "\n" . $response->decoded_content() );

  return;
}

# Generates an ssh key pair, passphraseless, and sets it as a peer key of
# gerrit; this allows it to be used as a key for the 'Gerrit Code Review' user.
# Sets the following:
#   $self->{ sshkey_public_key }:  ssh public key, unadorned (i.e. no 'ssh-rsa'
#                                  prefix or comment suffix)
#   $self->{ sshkey_file }:        ssh private key filename; public key filename
#                                  is identical with .pub appended
# Note: it may be necessary to flush-cache after this.
sub _setup_peer_key {
  my ($self) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  # create an ssh key set as a peer key, making it usable as the
  # 'Gerrit Code Review' superuser.
  my $sshkey_file = "$CWD/gerrit-client-test-id_rsa";
  if ( !-f $sshkey_file ) {
    return
      unless _system_or_fail( 'ssh-keygen', '-f', $sshkey_file, '-N', q{} );
  }

  {
    my $fh;
    if ( !ok( open( $fh, '<', $sshkey_file . '.pub' ) ) ) {
      diag "open $sshkey_file.pub: $!";
      return;
    }
    my $line = <$fh>;
    close($fh);
    my ( undef, $key, undef ) = split( / /, $line, 3 );
    if ( !ok( open( $fh, '>', 'etc/peer_keys' ) ) ) {
      diag "open peer_keys for write: $!";
      return;
    }
    print $fh "$key\n";
    if ( !ok( close($fh) ) ) {
      diag "close peer_keys after write: $!";
      return;
    }
    $self->{sshkey_public_key} = $key;
  }

  $self->{sshkey_file} = $sshkey_file;
  return;
}

# Creates wrapper scripts for git and ssh to ensure git invokes ssh
# with the needed options for interacting with this gerrit.
sub _setup_git_ssh {
  my ($self) = @_;
  my (@ssh)  = $self->ssh_base();

  my $ssh_cmd;
  {
    local $LIST_SEPARATOR = '" "';
    $ssh_cmd = "\"@ssh\"";
  }

  local $CWD = $self->{dir};
  my $fh;

  eval {
    open( $fh, '>', 'git_ssh_helper' );
    print $fh <<"END_GIT_SSH";
#!/bin/sh
exec $ssh_cmd "\$\@\"
END_GIT_SSH
    close($fh);

    open( $fh, '>', 'git_wrapper' );
    print $fh <<'END_GIT';
#!/bin/sh
GIT_SSH=$(readlink -f $(dirname $0)/git_ssh_helper)
export GIT_SSH
exec git "$@"
END_GIT
    close($fh);

    chmod( 0755, 'git_ssh_helper', 'git_wrapper' );
  };
  if ( my $error = $EVAL_ERROR ) {
    fail("setting up git ssh: $error");
    return;
  }

  return 1;
}

# Perform a $query via gerrit gsql.
# Fails test if the query fails.
# May have some quoting issues; try to avoid the " character within $query.
sub _do_gsql {
  my ( $self, $query ) = @_;

  my (@cmd) = $self->ssh_base('Gerrit Code Review');
  push @cmd, ( 'gerrit', 'gsql', '-c', "\"$query\"" );
  return _system_or_fail(@cmd);
}

# Like _system_or_fail, but operates on a $subref instead of
# a command via system()
sub _cmd_ok {
  my ( $self, $name, $subref, @cmd ) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $cmdstr;
  {
    local $LIST_SEPARATOR = '] [';
    $cmdstr = "[$name] [@cmd]";
  }

  my $status;
  my $captured = capture_merged {
    $status = $subref->( $self, @cmd );
  };
  if ( $status != 0 ) {
    diag($captured);
  }
  return is( $status, 0, "cmd ok: $cmdstr" );
}

sub _load_gerrit {
  my ( $package, %args ) = @_;

  local $CWD = $args{dir};

  my $http_url = URI->new( _gerrit_config('httpd.listenUrl') );
  if ( !$http_url ) {
    warn "Can't load httpd.listenUrl from gerrit in $CWD";
    return;
  }

  my $ssh_address = _gerrit_config('sshd.listenAddress');
  if ( !$ssh_address ) {
    warn "Can't load sshd.listenAddress from gerrit in $CWD";
    return;
  }

  diag("Found gerrit in $CWD, listening on $http_url and $ssh_address");

  $args{http_url}  = $http_url->as_string();
  $args{http_port} = $http_url->port();
  ( undef, $args{ssh_port} ) = split( /:/, $ssh_address, 2 );
  $args{war} ||= "$CWD/bin/gerrit.war";
  $args{user} = _gerrit_config('gerrit-client-test.user');

  my $self = bless \%args, $package;
  $self->_setup_peer_key();
  return $self;
}

################################## public ######################################

=head1 METHODS

In typical usage, B<ensure_gerrit_installed> would first be called in order to
obtain a handle to a local Gerrit instance; afterwards, other methods act in
the context of that Gerrit. This means that git and ssh commands are adjusted so
that passwordless superuser access is available to the local Gerrit.

=over

=item Gerrit::Client::Test->B<ensure_gerrit_installed>

=item Gerrit::Client::Test->B<ensure_gerrit_installed>( OPTIONS )

Installs Gerrit, or checks an existing Gerrit installation, and returns an
object representing the Gerrit site.

If no options are provided, an arbitrary version of Gerrit is downloaded and
installed to a temporary directory.

OPTIONS is a hashref with the following permitted keys:

=over

=item dir

Directory in which gerrit should be installed.

Defaults to a new temporary directory, which will be removed when the returned
object is destroyed.

=item war

URL or path to a gerrit.war to use for installation.

Defaults to http://gerrit.googlecode.com/files/gerrit-full-2.5.war .

=item user

Username for the initial gerrit user account (account 1000000).
This account has administrative privileges.

Defaults to "perl-gerrit-client-test".

=item ssh_port

=item http_port

TCP ports for the ssh and http interfaces to this Gerrit site.

Defaults to any unused ports chosen by the operating system.

=back

All of the above described options may also be directly extracted from the
returned $gerrit object, which is a blessed hashref.

=cut
sub ensure_gerrit_installed {
  my ( $package, %args ) = @_;

  # We consider that gerrit is installed if gerrit.war exists in the destination
  # directory
  if ( $args{dir} && -f "$args{ dir }/bin/gerrit.war" ) {
    return $package->_load_gerrit(%args);
  }

  $args{ssh_port}  ||= _find_available_tcp_port();
  $args{http_port} ||= _find_available_tcp_port();
  $args{war}       ||= 'http://gerrit.googlecode.com/files/gerrit-full-2.5.war';
  $args{dir} ||= File::Temp->newdir( 'Gerrit-Client-Test.XXXXXX', TMPDIR => 1 );
  $args{user} ||= 'perl-gerrit-client-test';

  my $local_war;
  my $uri = URI->new( $args{war} );
  if ( !$uri->scheme() ) {
    $local_war = $args{war};
  }
  elsif ( $uri->scheme() eq 'file' ) {
    $local_war = $uri->path();
  }
  else {
    $local_war = _fetch_remote( $args{war} );
  }

  if ( !-d $args{dir} ) {
    mkpath( $args{dir} );
  }
  local $CWD = $args{dir};
  my @installcmd =
    ( 'java', '-jar', $local_war, 'init', '--batch', '--no-auto-start' );
  return unless _system_or_fail(@installcmd);

  $args{http_url} = "http://127.0.0.1:$args{http_port}";

  return unless _gerrit_config( 'auth.type', 'HTTP' );
  return
    unless _gerrit_config( 'sshd.listenAddress', "127.0.0.1:$args{ssh_port}" );
  return unless _gerrit_config( 'httpd.listenUrl',         $args{http_url} );
  return unless _gerrit_config( 'gerrit.canonicalWebUrl',  $args{http_url} );
  return unless _gerrit_config( 'gerrit-client-test.user', $args{user} );

  my $self = bless \%args, $package;
  $self->_setup_peer_key();
  $self->_setup_git_ssh();
  $self->_create_gerrit_user( $args{user} );
  $self->_do_gsql( "insert into account_ssh_keys("
      . "ssh_public_key, valid, account_id, seq"
      . ") values("
      . "'ssh-rsa $args{ sshkey_public_key } test','Y',1000000,0"
      . ")" );
  $self->_do_gsql( "insert into account_external_ids("
      . "account_id,email_address,external_id"
      . ") values("
      . "1000000, 'perl-gerrit-client-test\@127.0.0.1', "
      . "'mailto:perl-gerrit-client-test\@127.0.0.1'"
      . ")" );
  $self->gerrit( 'flush-caches', '--all' );

  return $self;
}

=item $gerrit->B<ssh_base>

=item $gerrit->B<ssh_base>( USERNAME )

Returns the initial part of the ssh command which should be used when
interacting with this Gerrit installation. The command includes options for
setting the port number and identity file to allow passwordless access to this
Gerrit site.

If USERNAME is given, the command will also contain the USER@HOST argument;
otherwise, it must be specified manually. The HOST is always "127.0.0.1".

=cut
sub ssh_base {
  my ( $self, $user ) = @_;

  my @out = (
    'ssh',
    "-oUserKnownHostsFile=$self->{ dir }/ssh_known_hosts",
    '-oStrictHostKeyChecking=no',
    '-oBatchMode=yes',
    '-i',
    $self->{sshkey_file},
    '-p',
    $self->{ssh_port},
  );

  if ($user) {
    push @out, "$user\@127.0.0.1";
  }
  return @out;
}

=item $gerrit->B<git>( COMMAND )

Runs the given git COMMAND in the context of this gerrit.
COMMAND should be a git command with arguments, excluding the leading 'git', as
in the following example:

  $gerrit->git( 'fetch', 'origin', 'refs/heads/*:refs/remotes/origin/*' );

Returns the exit status of the git command.

=cut
sub git {
  my ( $self, @cmd ) = @_;
  return system( "$self->{ dir }/git_wrapper", @cmd );
}

=item $gerrit->B<git_ok>( COMMAND )

Like B<git>, but the command is treated as a test.
If the command fails, the test fails and the command's output is printed to the
test log.

=cut
sub git_ok {
  my ( $self, @cmd ) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  return $self->_cmd_ok( 'git', \&git, @cmd );
}

=item $gerrit->B<gerrit>( COMMAND )

=item $gerrit->B<gerrit>( OPTIONS, COMMAND )

Runs the given gerrit COMMAND, via ssh, in the context of this gerrit.
COMMAND should be a gerrit command with arguments, excluding the leading
'gerrit', as in the following example:

  $gerrit->gerrit( 'create-project', 'testproject' );

OPTIONS may be passed as a hashref with the following keys:

=over

=item user

Username for the gerrit connection.

Defaults to $gerrit->{user}, which is the first created user and has
administrative privileges.

=back

Returns the exit status of the ssh command.

=cut
sub gerrit {
  my ( $self, @cmd ) = @_;
  $self->ensure_gerrit_running();
  my $opts;
  if ( ref( $cmd[0] ) ) {
    $opts = shift @cmd;
  }
  $opts->{user} ||= $self->{user};

  my (@base) = $self->ssh_base( $opts->{user} );
  return system( @base, 'gerrit', @cmd );
}

=item $gerrit->B<gerrit_ok>( COMMAND )

=item $gerrit->B<gerrit_ok>( OPTIONS, COMMAND )

Like B<gerrit>, but the command is treated as a test.
If the command fails, the test fails and the command's output is printed to the
test log.

=cut
sub gerrit_ok {
  my ( $self, @cmd ) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  return $self->_cmd_ok( 'gerrit', \&gerrit, @cmd );
}

=item $gerrit->B<git_test_commit>

=item $gerrit->B<git_test_commit>( MESSAGE )

Create a test commit (an arbitrary, non-empty commit) in the local git
repository.

If MESSAGE is given, it is used as the commit message; otherwise, a reasonable
default is used.

=cut
sub git_test_commit {
  my ( $self, $message ) = @_;

  my $opts;
  if ( $message && ref($message) ) {
    $opts    = $message;
    $message = shift;
  }

  $message ||= 'test commit';

  my $fh;
  open( $fh, '>>', 'testfile' );
  print $fh "===\n$message\n";
  close($fh);

  my @commit_cmd = ( 'commit', '-m', $message );
  if ( $opts->{amend} ) {
    @commit_cmd = ( 'commit', '--amend', '--reuse-message', 'HEAD' );
  }

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  return $self->git_ok( 'add', 'testfile' )
    && $self->git_ok(@commit_cmd);
}

=item $gerrit->B<giturl_base>

=item $gerrit->B<giturl_base>( USER )

Returns the base git URL for this gerrit site.

The URL contains scheme, user, host and port components.
By default, $gerrit->{user} is used as the username;
this may be overriden by the USER parameter.

The URL has no path component, and hence the full git URL for a given
project may be constructed as in the following example:

  my $giturl = $gerrit->giturl_base() . '/some/project';
  $gerrit->git( 'clone', $giturl );
  ...

=cut
sub giturl_base {
  my ( $self, $user ) = @_;
  $user ||= $self->{user};
  return "ssh://$user\@127.0.0.1:$self->{ ssh_port }";
}

=item $gerrit->B<git_ssh_wrapper>

Returns the path to a wrapper script for the ssh command.  The wrapper
script may be used in place of 'ssh' to ensure that the correct setup
is used for passwordless access to this gerrit site.

Useful in conjunction with @Gerrit::Client::SSH to allow Gerrit::Client
passwordless access to this gerrit:

  local @Gerrit::Client::SSH = ( $gerrit->git_ssh_wrapper() );
  my $stream = Gerrit::Client::stream_events(
    url => $gerrit->giturl_base(),
    ...
  );

=cut
sub git_ssh_wrapper {
  my ($self) = @_;
  return "$self->{ dir }/git_ssh_helper";
}

=item $gerrit->B<start_gerrit>

Start the gerrit daemon or add a failure to the test log.

=cut
sub start_gerrit {
  my ($self) = @_;

  local $CWD = $self->{dir};
  diag("Starting gerrit in $CWD...");
  return _system_or_fail( 'bin/gerrit.sh', 'start' );
}

=item $gerrit->B<stop_gerrit>

Stop the gerrit daemon or add a failure to the test log.

=cut
sub stop_gerrit {
  my ($self) = @_;

  local $CWD = $self->{dir};
  diag("Stopping gerrit in $CWD...");
  return _system_or_fail( 'bin/gerrit.sh', 'stop' );
}

=item $gerrit->B<gerrit_pid>

Returns the PID of the main Gerrit process, if available.

This may return a stale value if Gerrit was terminated unexpectedly.

=cut
sub gerrit_pid {
  my ($self) = @_;

  my $pidfile = "$self->{ dir }/logs/gerrit.pid";
  if (! -f $pidfile) {
    return;
  }
  open( my $fh, '<', $pidfile );
  my $pid = <$fh>;
  chomp $pid;
  close($fh);

  return 0+$pid;
}

=item $gerrit->B<gerrit_running>

Returns 1 if and only if this Gerrit instance appears to be running.

=cut
sub gerrit_running {
  my ($self) = @_;

  my $pid = $self->gerrit_pid();
  if (!$pid) {
    return;
  }
  return kill( 0, $pid );
}

=item $gerrit->B<ensure_gerrit_running>

Start gerrit only if it is not already running, or add a failure to the test
log.

=cut
sub ensure_gerrit_running {
  my ($self) = @_;

  if ( $self->gerrit_running() ) {
    return 1;
  }
  return $self->start_gerrit();
}

=item $gerrit->B<ensure_gerrit_stopped>

Stop gerrit only if it is running, or add a failure to the test log.

=cut
sub ensure_gerrit_stopped {
  my ($self) = @_;

  if ( !$self->gerrit_running() ) {
    return 1;
  }
  return $self->stop_gerrit();
}

=back

=cut

1;
