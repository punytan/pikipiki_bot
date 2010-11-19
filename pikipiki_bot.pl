use common::sense;
use Encode;
use Data::Dumper;

use AnyEvent::HTTP;
use AnyEvent::Handle;
use AnyEvent::Twitter;

use XML::Simple;
use Web::Scraper;
use Unicode::Normalize qw/NFKC/;

local $AnyEvent::HTTP::USERAGENT = 'pikipiki_bot http://twitter.com/pikipiki_bot';

my $config   = do "oauth.pl" or die $!;
my @ng_users = do 'ng.pl'    or die $!;

my $twitty = AnyEvent::Twitter->new(%$config);
my $server = {};

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

my $server_cv = AE::cv;
http_get 'http://live.nicovideo.jp/api/getalertinfo', sub {
    my ($body, $hdr) = @_;
    
    warn time, " $hdr->{Status}: $hdr->{Reason} ";
    die "Failed to getalertinfo" unless ($hdr->{Status} =~ /^2/);

    my $xml = XMLin($body);
    die "Server status is not OK" unless ($xml->{status} eq 'ok');

    $server = $xml->{ms};
    $server->{tag} = XMLout({
        thread   => $xml->{ms}{thread},
        res_from => '-1',
        version  => '20061206',
    }, RootName  => 'thread') . "\0";

    $server_cv->send;
};
$server_cv->recv;

while (1) {
my $cv = AE::cv;
my $handle; $handle = AnyEvent::Handle->new(
    connect    => [$server->{addr}, $server->{port}],
    on_error   => sub { warn "Error $_[2]"; $_[0]->destroy; $cv->send },
    on_eof     => sub { $handle->destroy; warn "Done."; $cv->send },
    on_connect => sub { $handle->push_write($server->{tag}) },
    on_connect_error => sub { warn "Connect Error"; $cv->send },
);
$handle->push_read(line => "\0", \&reader);
$cv->recv;
}

exit;

sub reader {
    my ($handle, $tag) = @_;

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

    return sprintf "[%s] %s (%s人) - %s / %s http://nico.ms/%s #nicolive [%s]",
            $word, $com, $part, $title, $user->{name}, $xml->{request_id}, $stream->{co};
}

__END__

