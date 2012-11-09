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
    },
    PREREQ_PM => {
        #'ABC'              => 1.6,
        #'Foo::Bar::Module' => 5.0401,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'Gerrit-Client-*' },
);
