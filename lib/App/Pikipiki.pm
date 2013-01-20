package App::Pikipiki;
use strict;
use warnings;
use utf8;
our $VERSION = '0.01';

use AE;
use EV;
use AnyEvent::Log;
use AnyEvent::HTTP;
use AnyEvent::Handle;
use AnyEvent::Twitter;

use Encode;
use Data::Dumper;
use XML::Simple;
use Web::Scraper;
use Unicode::Normalize;
use Cache::LRU::WithExpires;

our $SEPARATOR = "\0";
our $URL_BASE  = {
    getalertinfo  => 'http://live.nicovideo.jp/api/getalertinfo',
    getstreaminfo => 'http://live.nicovideo.jp/api/getstreaminfo/lv',
    watch         => 'http://live.nicovideo.jp/watch/lv',
};

$AnyEvent::HTTP::USERAGENT = 'pikipiki_bot http://twitter.com/pikipiki_bot';
$Data::Dumper::Indent   = 0;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Useqq    = 1;

sub new {
    my ($class, %args) = @_;

    my $twitty = AnyEvent::Twitter->new(
        consumer_key    => '',
        consumer_secret => '',
        token           => '',
        token_secret    => '',
        %{ $args{token} || {} },
    );

    my $cache = Cache::LRU::WithExpires->new;

    return bless {
        limit_volumes => 60 * 60 * 6,
        twitty    => $twitty,
        over      => 400,
        words     => [],
        ng_users  => [],
        log_level => 'info',
        %args,
        handle    => undef,
        cache     => $cache,
    }, $class;
}

sub handle { shift->{handle} }
sub twitty { shift->{twitty} }
sub cache  { shift->{cache}  }

sub run {
    my ($self) = @_;
    $self->log(debug => 'run: start');

    my $w; $w = AE::timer 2, 10, sub {
        $self->log(debug => 'run: timer');
        return if $self->handle;
        $self->log(info => 'run: start reading stream');
        $self->read_stream;
    };

    return $w;
}

sub read_stream {
    my ($self) = @_;

    my $reader; $reader = sub {
        my ($handle, $line) = @_;
        my ($lv, $co, $user) = ($line =~ />([^,]+),([^,]+),([^,]+)</);

        unless ($lv && $co && $user) {
            $handle->push_read(line => $SEPARATOR, $reader);
            return;
        }

        if ($self->cache->get("user_id:$user")) {
            $handle->push_read(line => $SEPARATOR, $reader);
            return;
        }

        $self->gather_live_info($lv, $co, $user, sub {
            my $liveinfo = shift;
            my @keys = qw( word com part title user_name request_id );
            my $status = $self->construct_status(@$liveinfo{@keys}, $co);

            if ($self->{over} < $liveinfo->{part}) {
                $self->log(info => encode_utf8 "read_stream: status; $status");

                $self->twitty->post('statuses/update', { status => $status }, sub {
                    my ($hdr, $res, $reason) = @_;
                    $self->cache->set("user_id:$user", $user, $self->{limit_volumes});
                    my ($level, $message) = $res
                        ? (info => "read_stream: Successfully tweeted; $res->{text}")
                        : (warn => "read_stream: failed tweet; $reason");
                    $self->log($level, encode_utf8 $message);
                });
            } else {
                $self->log(info => encode_utf8 "read_stream: under the standard; $status");
            }
        });

        $handle->push_read(line => $SEPARATOR, $reader);
    };

    $self->connect(sub { $self->handle->push_read(line => $SEPARATOR, $reader) });
}

sub is_ignore_user {
    my ($self, $user_id) = @_;
    grep { $user_id == $_ } @{$self->{ng_users}}
}

sub search_words {
    my $self   = shift;
    my ($body) = $self->normalize(shift);
    my @orig_words = @{$self->{words}};
    my @words  = map { quotemeta } grep { defined } $self->normalize(@orig_words);

    $self->log(debug => Dumper { normalized => \@words } );

    my @matched;
    for (my $i = 0; $i < @orig_words; $i++) {
        my ($orig_word, $normalized) = ($orig_words[$i], $words[$i]);
        if ($body =~ /($normalized)/gi) {
            push @matched, $orig_word;
        } else {
            $self->log(debug => encode_utf8 "try match word: $orig_word");
        }
    }

    return @matched;
}

sub gather_live_info {
    my ($self, $lv, $co, $user, $callback)  = @_;

    my $cv = AE::cv;

    AnyEvent::HTTP::http_get "$URL_BASE->{getstreaminfo}$lv", sub {
        my $xml_str = decode_utf8(shift // '');
        if (not $xml_str) {
            $cv->send;
            return;
        }

        my ($word) = $self->search_words($xml_str);
        if (not defined $word) {
            $cv->send("unmatched: lv$lv");
            return;
        } elsif ($self->is_ignore_user($user)) {
            $cv->send("ignore_user: user_id $user");
            return;
        }

        AnyEvent::HTTP::http_get "$URL_BASE->{watch}$lv", sub {
            my $body = decode_utf8(shift // '');
            if (not $body) {
                $cv->send;
                return;
            }

            my $xml   = XMLin($xml_str);
            my $title = substr $xml->{streaminfo}{title},   0, 30;
            my $com   = substr $xml->{communityinfo}{name}, 0, 30;
            my $part  = $self->participant_count($body);
            my $user_info = (scraper { process 'span#pedia a', 'name' => 'TEXT' })->scrape($body)
                || { name => '-' };

            $self->log(warn => "found undef: " . Dumper $xml) unless $xml->{streaminfo}{title};

            my $liveinfo = {
                word  => $word,
                title => $title,
                com   => $com,
                part  => $part,
                user_name  => $user_info->{name},
                request_id => $xml->{request_id},
            };

            $self->log(
                debug => encode_utf8( (Dumper {
                    a_matched_words  => [ $self->search_words($xml_str) ],
                    b_liveinfo       => {
                        a_request_id=> $liveinfo->{request_id},
                        b_word => $liveinfo->{word},
                        c_user_name => $liveinfo->{user_nam},
                        x_com => $liveinfo->{com},
                    }
                }) =~ s/\\x{([0-9a-z]+)}/chr(hex($1))/ger)
            );

            $cv->send($liveinfo);
        };
    };

    $cv->cb(sub {
        my $liveinfo = $cv->recv;

        $self->log(debug => "gather_live_info: " . Dumper $liveinfo);
        if (ref $liveinfo eq 'HASH') {
            $callback->($liveinfo);
        } elsif ($liveinfo =~ /^(unmatched|ignore_user)/) {
            $self->log(debug => "gather_live_info: $liveinfo");
        } else {
            $self->log(warn => "gather_live_info: failed");
        }
    });
}

sub connect {
    my ($self, $callback) = @_;

    $self->get_alertinfo(sub {
        my $server = shift;
        $self->{handle} = AnyEvent::Handle->new(
            connect    => [ @$server{qw/ addr port /} ],
            on_connect => sub {
                $self->log(info => "successfully connected: $server->{addr}:$server->{port}");
                $self->handle->push_write($server->{tag});
            },
            on_error => sub {
                $self->log(warn => "connect error: $_[2]");
                undef $self->{handle};
                $_[0]->destroy;
            },
            on_eof => sub {
                $self->log(warn => "Done");
                undef $self->{handle};
                $_[0]->destroy;
            },
            on_connect_error => sub {
                $self->log(warn => "Error on connect");
                undef $self->{handle};
            },
        );
        $callback->();
    });

}

sub get_alertinfo {
    my ($self, $callback) = @_;

    my $cv = AE::cv;

    $self->log(debug => "getalertinfo: sending request");
    AnyEvent::HTTP::http_get $URL_BASE->{getalertinfo}, sub {
        my ($body, $hdr) = @_;
        $self->log(info => "getalertinfo: $hdr->{Status} [$hdr->{Reason}]");

        if (not $body or $hdr->{Status} != 200) {
            $self->log(warn => "getalertinfo: failed to get alertinfo");
            $cv->send;
            return;
        }

        my $xml = XML::Simple::XMLin($body);
        if ($xml->{status} ne 'ok') {
            $self->log(warn => "getalertinfo: Server status is not OK");
            $cv->send;
            return;
        }

        my $tag = XML::Simple::XMLout(
            {
                thread   => $xml->{ms}{thread},
                res_from => '-1',
                version  => '20061206',
            },
            RootName => 'thread'
        ) . $SEPARATOR;

        my $server = {
            addr => $xml->{ms}{addr},
            port => $xml->{ms}{port},
            tag  => $tag,
        };

        $cv->send($server);
    };

    $cv->cb(sub {
        my $server = $cv->recv;
        $self->log(debug => "server: " . Dumper $server);
        if ($server) {
            $callback->($server);
        }
    });
}

sub construct_status {
    my ($self, $word, $com, $part, $title, $user_name, $request_id, $co) = @_;

    my $status = sprintf "[%s] %s (%s人) - %s / %s http://nico.ms/%s #nicolive #%s",
        $word, $com, $part, $title, $user_name, $request_id, $co;

    $status =~ s/\@/@ /g;
    return $status;
}

sub log {
    my ($self, $level, $message) = @_;
    $AnyEvent::Log::FILTER->level($self->{log_level});
    AE::log($level, $message);
}

sub participant_count {
    my ($self, $body) = @_;
    $body =~ m!メンバー：<[^>]+>(\d+)!gms ? $1 : 0;
}

sub normalize {
    my ($self, @words) = @_;
    $self->log(debug => Dumper { before => \@words} );

    my @normalized_words;
    for my $word (@words) {
        my $normalized = NFKC $word;
        $normalized =~ tr/ぁ-ん/ァ-ン/;
        push @normalized_words, $normalized;
    }
    
    $self->log(debug => Dumper { after => \@normalized_words } );

    return @normalized_words;
}

1;
__END__
