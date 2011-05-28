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

while (1) {
    my $server = {};

    my $server_cv = AE::cv;
    AnyEvent::HTTP::http_get 'http://live.nicovideo.jp/api/getalertinfo', sub {
        my ($body, $hdr) = @_;

        warn "$hdr->{Status}: $hdr->{Reason}";

        if (not $body or $hdr->{Status} ne '200') {
            warn "Failed to get alertinfo";
            $server_cv->send;
        }

        my $xml = XMLin($body);
        if ($xml->{status} ne 'ok') {
            warn "Server status is not OK";
            $server_cv->send;
        }

        $server = $xml->{ms};
        $server->{tag} = XMLout({
            thread   => $xml->{ms}{thread},
            res_from => '-1',
            version  => '20061206',
        }, RootName  => 'thread') . "\0";

        $server_cv->send;
    };
    $server_cv->recv;

    if ($server->{tag}) {
        my $cv = AE::cv;

        my $six_hours = 1 * 60 * 60 * 6;
        my $timer; $timer = AE::timer $six_hours, $six_hours, sub {
            printf "[%s]\n", join ', ', @TWEETED;
            undef @TWEETED;
        };

        my $handle; $handle = AnyEvent::Handle->new(
            connect    => [$server->{addr}, $server->{port}],
            on_connect => sub { $handle->push_write($server->{tag}) },
            on_error   => sub {
                warn "Error $_[2]";
                $_[0]->destroy;
                $cv->send
            },
            on_eof     => sub {
                $handle->destroy;
                warn "Done.";
                $cv->send
            },
            on_connect_error => sub {
                warn "Connect Error";
                $cv->send
            },
        );
        $handle->push_read(line => "\0", \&reader);
        $cv->recv;
    }

    my $cv2 = AE::cv;
    my $w; $w = AE::timer 10, 0, sub {
        warn "Waiting 10 seconds";
        undef $w;
        $cv2->send;
    };
    $cv2->recv;
}

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
                            $_[1] ? say encode_utf8 $_[1]->{text} : warn $_[2];
                            push @TWEETED, $stream{user};
                            printf "[%s]\n", join', ', @TWEETED;
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
        return undef if $user eq $_;
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

    return undef unless scalar @matched_words;

    for (@NG) {
        return undef if $user eq $_;
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

    return remove_reply($status);
}

sub remove_reply{
    my $text = shift;
    $text =~ s/\@/@ /g;
    return $text;
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

