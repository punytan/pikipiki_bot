use practical;
use Encode;
use Data::Dumper;
use AnyEvent::HTTP;
use AnyEvent::Handle;
use AnyEvent::Twitter;

use XML::Simple;
use Web::Scraper;
use Unicode::Normalize qw/NFKC/;

use constant DEBUG => $ENV{PIKIPIKI_DEBUG};

local $AnyEvent::HTTP::USERAGENT = 'pikipiki_bot http://twitter.com/pikipiki_bot';
local $| = 1;

our @TWEETED;
our @NG     = do 'config/ng.pl' or die $!;
our $CONFIG = {};

$CONFIG->{piki}{oauth} = do "config/piki/oauth.pl" or die $!;
$CONFIG->{nms}{oauth}  = do "config/nms/oauth.pl"  or die $!;

$CONFIG->{piki}{words} = do "config/piki/words.pl" or die $!;
$CONFIG->{nms}{words}  = do "config/nms/words.pl"  or die $!;

@{$CONFIG->{piki}{normalized}} = normalize(@{$CONFIG->{piki}{words}});
@{$CONFIG->{nms}{normalized}}  = normalize(@{$CONFIG->{nms}{words}} );

print Dumper [\@TWEETED, \@NG, $CONFIG] if DEBUG;

my $CONNECTED;
my $cv = AE::cv;
my $w; $w = AE::timer 1, 10, sub {
    return if $CONNECTED;

    my $server = {};
    AnyEvent::HTTP::http_get 'http://live.nicovideo.jp/api/getalertinfo', sub {
        my ($body, $hdr) = @_;

        warn "*** $hdr->{Status}: $hdr->{Reason}";
        if (not $body or $hdr->{Status} ne '200') {
            warn "*** Failed to get alertinfo";
            return;
        }

        my $xml = XMLin($body);
        if ($xml->{status} ne 'ok') {
            warn "*** Server status is not OK";
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
                $handle->push_write($server->{tag});
            },
            on_error => sub {
                $CONNECTED = 0;
                undef $handle;
                warn "*** Error $_[2]";
                $_[0]->destroy;
            },
            on_eof => sub {
                $CONNECTED = 0;
                undef $handle;
                $_[0]->destroy;
                warn "*** Done.";
            },
            on_connect_error => sub {
                $CONNECTED = 0;
                undef $handle;
                warn "*** Connect Error";
            },
        );

        $handle->push_read(line => "\0", \&reader);

        undef $w;
    };
};

my $six_hours = 1 * 60 * 60 * 6;
my $timer; $timer = AE::timer $six_hours, $six_hours, sub {
    printf "Status of tweeted array:\n\t[%s]\n", join ', ', @TWEETED if DEBUG;
    @TWEETED = ();
};

$cv->recv;

sub reader {
    my ($handle, $tag) = @_;

    if ($tag =~ />([^,]+),([^,]+),([^,]+)</) {
        my %stream = (lv => $1, co => $2, user => $3);

        AnyEvent::HTTP::http_get "http://live.nicovideo.jp/api/getstreaminfo/lv" . $stream{lv}, sub {
            my $xml = shift;
            return unless $xml;

            my $xml_str = decode_utf8 $xml;
            if (my $meta = is_matched($xml_str, $stream{user})) {
                AnyEvent::HTTP::http_get "http://live.nicovideo.jp/watch/lv" . $stream{lv}, sub {
                    my $res = shift;
                    return unless $res;

                    my $body = decode_utf8 $res;
                    if ( $meta->{type} eq 'piki' or ( $meta->{type} eq 'nms' and is_over400($body) ) ) {
                        my $status = construct_status($body, XMLin($xml), $meta->{word}, \%stream);

                        AnyEvent::Twitter->new(%{$CONFIG->{$meta->{type}}{oauth}})->post('statuses/update', {
                            status => $status
                        }, sub {
                            $_[1] ? say encode_utf8 $_[1]->{text} : warn "*** $_[2]";
                            push @TWEETED, $stream{user};
                            printf "Status of tweeted array:\n\t[%s]\n", join ', ', @TWEETED if DEBUG;
                        });
                    }

                    print Dumper { meta => $meta } if DEBUG;
                };
            }
        };
    }

    $handle->push_read(line => "\0", \&reader);
}

sub is_matched {
    my ($xml_str, $user) = @_;

    for (@TWEETED) {
        return if $user eq $_;
    }

    my ($formed) = normalize($xml_str);

    my (@matched_words, $type);
    for my $account (keys %$CONFIG) {
        for (my $i = 0; $i < scalar @{$CONFIG->{$account}{normalized}}; $i++) {
            if ($formed =~ $CONFIG->{$account}{normalized}[$i]) {
                push @matched_words, $CONFIG->{$account}{words}[$i];
                $type = $account;
            }
        }
    }

    return unless scalar @matched_words;

    for (@NG) {
        return if $user eq $_;
    }

    $matched_words[0] =~ s/\\//g; # for regex of C++

    return +{
        word => $matched_words[0],
        type => $type
    };
}

sub construct_status {
    my ($body, $xml, $word, $stream) = @_;

    my $scraper = scraper { process 'span#pedia a', 'name' => 'TEXT'; };
    my $user = $scraper->scrape($body);

    my $user_name = $user ? $user : '-';
    my $part  = $body =~ m!参加人数：<strong style="font-size:14px;">(\d+)</strong>!gms ? $1 : 0;
    my $title = substr $xml->{streaminfo}{title},   0, 30;
    my $com   = substr $xml->{communityinfo}{name}, 0, 30;

    my $status = sprintf "[%s] %s (%s人) - %s / %s http://nico.ms/%s #nicolive [%s]",
            $word, $com, $part, $title, $user->{name}, $xml->{request_id}, $stream->{co};

    $status =~ s/\@/@ /g;

    return $status;
}

sub is_over400 {
    my $body = shift;
    my $part = $body =~ m!参加人数：<strong style="font-size:14px;">(\d+)</strong>!gms ? $1 : 0;
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

