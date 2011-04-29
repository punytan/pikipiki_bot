use practical;
use Data::Dumper;
use AnyEvent;
use AnyEvent::Twitter;
use File::Basename;
our $BASEDIR = dirname(__FILE__);

&main;
exit;

sub main {
    my $OAuth = do "$BASEDIR/config/nms/oauth.pl" or die $!;
    my $ua = AnyEvent::Twitter->new(%$OAuth);
    my $relation = {
        following => [],
        followers => [],
    };

    my $cv = AE::cv;
    $cv->begin;
    $ua->get('followers/ids', sub {
        $_[1] ? $relation->{followers} = $_[1] : die $_[2];
        $cv->end;
    });

    $cv->begin;
    $ua->get('friends/ids', sub {
        $_[1] ? $relation->{following} = $_[1] : die $_[2];
        $cv->end;
    });
    $cv->recv;

    my $task = mark($relation);

    my $cv2 = AE::cv;
    for my $type (keys %$task) {
        for my $uid (@{$task->{$type}}) {
            $cv2->begin;
            if ($type eq 'remove') {
                $ua->post('friendships/destroy', {user_id => $uid}, sub {
                    $cv2->end;
                });
            } else {
                $ua->post('friendships/create', {user_id => $uid}, sub {
                    $cv2->end;
                });
            }
        }
    }
    $cv2->recv;
}

sub mark {
    my $relation = shift;

    my @followers = @{$relation->{followers}};
    my @following = @{$relation->{following}};

    my %table;
    $table{$_} .= 'followers' for @followers;
    $table{$_} .= 'following' for @following;

    my $task = {
        follow => [],
        remove => [],
    };

    for my $uid (keys %table) {
        if ($table{$uid} eq 'followers') {
            push @{$task->{follow}}, $uid;
        } elsif ($table{$uid} eq 'following') {
            push @{$task->{remove}}, $uid;
        } else {
            # mutually following
        }
    }

    return $task;
}

__END__


