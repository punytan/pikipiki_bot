#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Encode;
use Data::Dumper;
use 5.12.1;

use AnyEvent;
use AnyEvent::HTTP;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Twitter;

use JSON;
use Perl6::Slurp;
use XML::Simple;
use Web::Scraper;
use Unicode::Normalize qw/NFKC/;

local $AnyEvent::HTTP::USERAGENT = 'pikipiki_bot http://twitter.com/pikipiki_bot';

my $json_text = slurp "/home/puny/.account/twitter/pikipiki_bot.json";
my $config = decode_json($json_text);

my $twitty = AnyEvent::Twitter->new(%$config);

my @words = (
    'C言語', 'C\+\+', 'C#', 'F#', 'Objective-C', 'COBOL',
    'D言語', 'Delphi', 'FORTRAN', 'Groovy', 'JavaScript', 'Java', 'Pascal', 'Perl', 'Python',
    'Ruby', '機械語', 'アセンブリ', 'アセンブラ', 'Erlang', 'Haskell', 'LISP', 'OCaml', 'Scala',
    'ActionScript', 'Smalltalk', 'プログラミング', 'プログラマ',
); # Regexp. Except PHP, SQL and AWK

my @normalized_words;
for (@words) {
    my $word = uc NFKC $_;
    $word =~ tr/ぁ-ん/ァ-ン/;
    push @normalized_words, $word;
}

my $json_string = slurp 'ng.json';
my $ng = decode_json($json_string);
my @ng_users = @$ng;

my $server = {};

my $server_cv = AE::cv;
http_get 'http://live.nicovideo.jp/api/getalertinfo', sub {
    my ($body, $hdr) = @_;
    
    warn time, " $hdr->{Status}: $hdr->{Reason} ";
    exit unless ($hdr->{Status} =~ /^2/);

    my $xml = XMLin($body);
    exit unless ($xml->{status} eq 'ok');

    $server = $xml->{ms};
    $server_cv->send;
};
$server_cv->recv;

my $cv = AE::cv;
tcp_connect $server->{addr} => $server->{port}, sub {
    my ($fh) = @_ or die $!;

    my $handle; $handle = new AnyEvent::Handle
        fh       => $fh,
        on_error => sub {
            warn "Error $_[2]";
            $_[0]->destroy;
        },
        on_eof   => sub {
            $handle->destroy;
            warn "Done.";
        };

    my $tag_attr = {
        thread   => $server->{thread},
        res_from => '-1',
        version  => '20061206',
    };

    $handle->push_write(XMLout($tag_attr, RootName => 'thread') . "\0");
    $handle->push_read(line => "\0", \&reader);
};
$cv->recv;

exit;

sub reader {
    my ($handle, $tag) = @_;

    $cv->send unless $handle;

    say $tag;

    if ($tag =~ />([^,]+),([^,]+),([^,]+)</) {
        my %stream = (lv => $1, co => $2, user => $3);

        http_get "http://live.nicovideo.jp/api/getstreaminfo/lv" . $stream{lv}, sub {
            my ($xml_str, $hdr) = @_;
            return unless $xml_str;

            if (my $word = is_matched($xml_str, $stream{user})) {
                http_get "http://live.nicovideo.jp/watch/lv" . $stream{lv}, sub {
                    my $body = decode_utf8 shift;
                    return unless $body;

                    my $status = construct_status($body, XMLin($xml_str), $word, \%stream);
                    $twitty->request(
                        api => 'statuses/update',
                        method => 'POST',
                        params => { status => $status },
                    sub {
                        say encode_utf8($_[1]->{text});
                    });
                };
            }
        };
    }

    $handle->push_read(line => "\0", \&reader);
}

sub is_matched {
    my $xml_str = shift;
    my $user = shift;

    my $formed = uc NFKC decode_utf8 $xml_str;
    $formed =~ tr/ぁ-ん/ァ-ン/;

    my @matched_words;
    for (my $i = 0; $i < scalar @normalized_words; $i++) {
        push @matched_words, $words[$i] if $formed =~ $normalized_words[$i];
    }

    return undef unless (scalar @matched_words);

    for (@ng_users) {
        return undef if $user eq $_;
    }

    $matched_words[0] =~ s/\\//g;
    return $matched_words[0];
}

sub construct_status {
    my ($body, $xml, $word, $stream) = @_;

    my $scraper = scraper { process 'span#pedia a', 'name' => 'TEXT'; };
    my $user = $scraper->scrape($body);

    my $user_name = $user ? $user : '-';
    my $part = $body =~ m!参加人数：<strong style="font-size:14px;">(\d+)</strong>!gms ? $1 : 0;
    my $title = substr $xml->{streaminfo}{title}, 0, 30;
    my $com = substr $xml->{communityinfo}{name}, 0, 30;

    return "[$word] $com (${part}人) - $title / $user->{name} http://nico.ms/$xml->{request_id} #nicolive [$stream->{co}]";
}

__END__

