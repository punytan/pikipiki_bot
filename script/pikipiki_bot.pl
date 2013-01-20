use strict;
use warnings;

use AE;
use JSON;
use Getopt::Long;
use App::Pikipiki;

my %opts;

GetOptions(\%opts, qw< config=s >)
    or die "Invalid arguments";

die "config file path is required" unless -e $opts{config};

my $config = JSON::decode_json(
    do {
        open my $fh, "<", $opts{config} or die "Can't open config file: $!";
        local $/;
        join "", <$fh>;
    }
);

AE::log(info => "Loaded config: $opts{config}");

my $app = App::Pikipiki->new(
    limit_volumes => $config->{limit_volumes},
    words    => $config->{words},
    over     => $config->{over},
    ng_users => $config->{ng_users},
    token    => {
        consumer_key    => $config->{token}{consumer_key},
        consumer_secret => $config->{token}{consumer_secret},
        token           => $config->{token}{token},
        token_secret    => $config->{token}{token_secret},
    },
);

AE::log(debug => "start run");
my $watcher = $app->run;

AE::log(debug => "start recv");
AE::cv->recv;

exit;

__END__

