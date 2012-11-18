use 5.010;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Gerrit::Client',
    AUTHOR           => q{Rohan McGovern <rohan@mcgovern.id.au>},
    VERSION_FROM     => 'lib/Gerrit/Client.pm',
    ABSTRACT_FROM    => 'lib/Gerrit/Client.pm',
    LICENSE          => 'LGPL_2',
    PL_FILES         => {},
    MIN_PERL_VERSION => 5.010,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
        'LWP' => 0,
        'File::chdir' => 0,
        'Capture::Tiny' => 0,
    },
    PREREQ_PM => {
        'Params::Validate' => 0,
        'AnyEvent' => 0,
        'JSON' => 0,
        'URI' => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'Gerrit-Client-*' },
);
