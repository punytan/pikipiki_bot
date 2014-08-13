use strict;
use warnings;
use utf8;
use Encode;
use Data::Dumper;
use AnyEvent::HTTP;
use AnyEvent::Handle;
use AnyEvent::Twitter;
use AnyEvent::Log;

use Config::PP;
use XML::Simple;
use Web::Scraper;
use Unicode::Normalize qw/NFKC/;
use Getopt::Long;

GetOptions('config-dir=s' => \$Config::PP::DIR)
    or die "Invalid arguments";

$AnyEvent::HTTP::USERAGENT = 'pikipiki_bot http://twitter.com/pikipiki_bot';
$AnyEvent::Log::FILTER->level("info");

our @TWEETED;
our @NG     = qw/ 3790363 14442791 16447168 7443154 /;
our $OAuth = {
    piki => config_get("piki"),
    nms  => config_get("nms"),
};

our $Words = {
    nms  => [ qw( ギター 弾き語り ピアノ 弾き語る アコギ ベース ) ],
    piki => [ 'C#', 'F#', qw(
        C言語 C++ Objective-C COBOL D言語 Delphi FORTRAN Groovy
        JavaScript Java Pascal Perl Python Ruby 機械語 アセンブリ アセンブラ
        Erlang Haskell LISP OCaml Scala ActionScript Smalltalk プログラミング プログラマ 
    ) ]
};

our $Normalized = {
    nms  => [ normalize(@{$Words->{nms}})  ],
    piki => [ normalize(@{$Words->{piki}}) ],
};

my $CONNECTED;
my $cv = AE::cv;
my $w; $w = AE::timer 1, 10, sub {
    return if $CONNECTED;

    my $server = {};
    AnyEvent::HTTP::http_get 'http://live.nicovideo.jp/api/getalertinfo', sub {
        my ($body, $hdr) = @_;

        AE::log info => "*** $hdr->{Status}: $hdr->{Reason}";
        if (not $body or $hdr->{Status} ne '200') {
            AE::log warn => "*** Failed to get alertinfo";
            return;
        }

        my $xml = XMLin($body);
        if ($xml->{status} ne 'ok') {
            AE::log warn => "*** Server status is not OK";
            return;
        }

        $server = $xml->{ms};
        $server->{tag} = XMLout({
            thread   => $xml->{ms}{thread},
            res_from => '-1',
            version  => '20061206',
        }, RootName  => 'thread') . "\0";

        my $handle; $handle = AnyEvent::Handle->new(
            connect    => [$server->{addr}, $server->{port}],
            on_connect => sub {
                $CONNECTED = 1;
                AE::log info => "Connected";
                $handle->push_write($server->{tag});
            },
            on_error => sub {
                $CONNECTED = 0;
                undef $handle;
                AE::log warn => "*** Error $_[2]";
                $_[0]->destroy;
            },
            on_eof => sub {
                $CONNECTED = 0;
                undef $handle;
                $_[0]->destroy;
                AE::log warn => "*** Done.";
            },
            on_connect_error => sub {
                $CONNECTED = 0;
                undef $handle;
                AE::log warn => "*** Connect Error";
            },
        );

        my $reader; $reader = sub {
            my ($handle, $tag) = @_;

            if ($tag =~ />([^,]+),([^,]+),([^,]+)</) {
                my %stream = (lv => $1, co => $2, user => $3);

                AnyEvent::HTTP::http_get "http://live.nicovideo.jp/api/getstreaminfo/lv" . $stream{lv}, sub {
                    my $xml = shift or return;

                    if (my $meta = is_matched(decode_utf8($xml), $stream{user})) {
                        AnyEvent::HTTP::http_get "http://live.nicovideo.jp/watch/lv" . $stream{lv}, sub {
                            my $res = shift or return;

                            my $body = decode_utf8 $res;
                            if ( $meta->{type} eq 'piki' or ( $meta->{type} eq 'nms' and is_over400($body) ) ) {
                                my $status = construct_status($body, XMLin($xml), $meta->{word}, \%stream);

                                my $credentials = $OAuth->{$meta->{type}};
                                my $ua = AnyEvent::Twitter->new(%$credentials);
                                AE::log info => "going to tweet: $status";
                                $ua->post('statuses/update', { status => $status }, sub {
                                    if ($_[1]) {
                                        AE::log info => "tweeted: $_[1]->{text}";
                                    } else {
                                        AE::log warn => "*** tweet fialed: $_[0]->{Status} $_[2]";
                                    }
                                    push @TWEETED, $stream{user};
                                    AE::log debug => "Status of tweeted array:\n\t[%s]\n", join ', ', @TWEETED;
                                });
                            }

                        };
                    }
                };
            }

            $handle->push_read(line => "\0", $reader);
        };

        $handle->push_read(line => "\0", $reader);

        undef $w;
    };
};

my $six_hours = 1 * 60 * 60 * 6;
my $timer; $timer = AE::timer $six_hours, $six_hours, sub {
    AE::log debug => "Status of tweeted array:\n\t[%s]\n", join ', ', @TWEETED;
    @TWEETED = ();
};

$cv->recv;

sub is_matched {
    my ($xml_str, $user) = @_;

    for (@TWEETED) {
        return if $user eq $_;
    }

    my ($formed) = normalize($xml_str);

    my (@matched_words, $type);
    for my $account (keys %$Normalized) {
        my $words = $Normalized->{$account};
        for (my $i = 0; $i < scalar @$words; $i++) {
            my $regex = quotemeta $words->[$i];
            if ($formed =~ /$regex/) {
                push @matched_words, $Words->{$account}[$i];
                $type = $account;
            }
        }
    }

    return unless scalar @matched_words;

    for (@NG) {
        return if $user eq $_;
    }

    return +{
        type => $type,
        word => shift @matched_words,
    };
}

sub construct_status {
    my ($body, $xml, $word, $stream) = @_;

    my $user = (scraper { process 'span#pedia a', 'name' => 'TEXT'; })->scrape($body);

    my $user_name = $user ? $user : '-';
    my $part  = part($body);
    my $title = substr $xml->{streaminfo}{title},   0, 30;
    my $com   = substr $xml->{communityinfo}{name}, 0, 30;

    my $status = sprintf "[%s] %s (%s人) - %s / %s http://nico.ms/%s #nicolive #%s",
        $word, $com, $part, $title, $user->{name}, $xml->{request_id}, $stream->{co};

    $status =~ s/\@/@ /g;

    return $status;
}

sub part {
    my $body = shift;
    my ($part) = $body =~ m!メンバー：<strong style="font-size:14px;">(\d+)</strong>!gms;
    $part;
}

sub is_over400 {
    my $body = shift;
    my $part = part($body);
    return $part > 400 ? $part : undef;
}

sub normalize {
    return grep {
        my $word = uc NFKC $_;
        $word =~ tr/ぁ-ん/ァ-ン/;
        $word;
    } @_;
}

__END__

