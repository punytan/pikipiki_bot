use inc::Module::Install;
name 'App-Pikipiki';
all_from 'lib/App/Pikipiki.pm';

requires 'AE';
requires 'AnyEvent::HTTP';
requires 'AnyEvent::Handle';
requires 'AnyEvent::Log';
requires 'AnyEvent::Twitter';
requires 'Cache::LRU::WithExpires';
requires 'EV';
requires 'JSON';
requires 'Web::Scraper';
requires 'XML::Simple';

tests 't/*.t';
author_tests 'xt';

install_script 'script/pikipiki_bot.pl';

test_requires 'Test::More' => 0.98;
auto_set_repository;
auto_include;
WriteAll;
