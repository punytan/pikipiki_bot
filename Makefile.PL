use inc::Module::Install;
name 'App-Pikipiki';
all_from 'lib/App/Pikipiki.pm';

# requires '';

tests 't/*.t';
author_tests 'xt';

test_requires 'Test::More' => 0.98;
auto_set_repository;
auto_include;
WriteAll;
