use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'Catmandu::Store::DBI',
    license             => 'perl',
    build_requires => {
        'Test::Exception' => 0,
        'Test::More' => 0,
    },
    requires => {
        'perl' => '5.10.1',
        'Catmandu' => '0.2003',
        'DBI' => '1.616',
        'namespace::clean' => '0.24',
    },
    add_to_cleanup     => [ 'Catmandu-Store-DBI-*' ],
    create_makefile_pl => 'traditional',
    meta_merge => {
        resources => {
            repository => 'https://github.com/LibreCat/Catmandu-Store-DBI.git',
            bugtracker => 'htps://github.com/LibreCat/Catmandu-Store-DBI/issues',
            homepage => 'https://github.com/LibreCat/Catmandu-Store-DBI',
        },
    },
);

$builder->create_build_script;
