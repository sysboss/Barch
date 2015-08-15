package Barch::Monitor::HTTP;
use Moo;
use JSON;
use Twiggy::Server;

has [ qw<bind_addr bind_port> ] => (
    is       => 'ro',
    required => 1,
);

has httpd => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_httpd',
);

# variables we need from barch main
has [ qw<backups max_forks q_order queue lvs_array report> ] => (
    is       => 'ro',
    required => 1,
);

sub _build_httpd {
    my $self = shift;

    return Twiggy::Server->new(
        host => $self->bind_addr,
        port => $self->bind_port,
    );
}

# Start HTTP server

sub run {
    my $self      = shift;
    my $backups   = $self->backups;
    my $max_forks = $self->max_forks;
    my $q_order   = $self->q_order;
    my $queue     = $self->queue;
    my $lvs_array = $self->lvs_array;
    my $report    = $self->report;

    $self->httpd->register_service( sub {
        my $env  = shift;
        my $path = $env->{'PATH_INFO'} || '/';
        my $time = time;

        if( $path eq '/queue' ){
            my $forks   = scalar keys %{$backups};
            my $index   = 0 ;
            my @running = ();
            my @jobs    = ();
            my $is_late = '';

            # generate response
            my $page = "| LV" . " "x25 .
                       "| Since Last backup" . " "x2 .
                       "| Queue" . " "x25 .
                       "| Running ($forks/$max_forks forks):\n".
                       "="x117 . "\n";

            foreach my $q ( keys %{$backups} ){
                my $remsize = $backups->{$q}{'remsize'} || '';
                my $drbddev = '';

                if( $backups->{$q}{'drbd'}->{'dev'} ){
                    $drbddev = '[DRBD] '
                        if $backups->{$q}{'drbd'}->{'dev'} ne 'undefined';
                }
                push @running, "${drbddev}$backups->{$q}{'lvname'} $remsize";
            }

            foreach my $j ( @{$q_order} ){
                $is_late = '[!]' if $queue->{$j}{'late'};
                push @jobs, "$queue->{$j}{'lvname'} $is_late";
            }

            foreach my $lv ( @{$lvs_array} ){
                my $date     = '';
                my $runqueue = '|' . ' 'x30;
                my $queuejob = '|' . ' 'x30;
                my @section  = @{ $lv };

                $runqueue = "├ $running[$index]"
                    if defined $running[$index];

                $queuejob = sprintf("|%2.0f├ %-26s", ($index+1), $jobs[$index])
                    if defined $jobs[$index];

                if( $report->{"$section[0].$section[1]"}{timestamp} ){
                    $date = $report->{"$section[0].$section[1]"}{timestamp};
                    $date = convert_time( $time - $date );
                }

                $date  = $date || '-';
                $page .= sprintf("├ %-26s | %-18s $queuejob $runqueue\n",
                    $section[1], $date );
                $index++;
            }

            return [
                200,
                [ 'Content-type' => 'text/plain' ],
                [ $page ],
            ];
        } elsif( $path eq '/backups' ){
            my $json = encode_json $backups;
            return [
                200,
                [ 'Content-type' => 'text/plain' ],
                [ $json ],
            ];
        } elsif( $path eq '/status' ){
            my %status = %{ $report };
            my $json   = encode_json \%status;
            return [
                200,
                [ 'Content-type' => 'text/plain' ],
                [ $json ],
            ];
        } elsif( $path eq '/queue' ){
            my $json = encode_json $queue;
            return [
                200,
                [ 'Content-type' => 'text/plain' ],
                [ $json ],
            ];
        } else {
            return [
                403,
                [ 'Content-Type' => 'text/plain' ],
                [ "" ],
            ];
        }
    } );
}

1;
