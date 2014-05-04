#!/usr/bin/perl

use strict;
use warnings;

use Config::Tiny;
use DateTime;
use POSIX qw/strftime/;
use Time::HiRes qw( gettimeofday );
use Getopt::Long;
use Switch;

my %states = (
    OK       => 0,
    WARNING  => 1,
    CRITICAL => 2,
    UNKNOWN  => 3,
);

my $default_WARN = 86400;
my $default_CRIT = 108000;

sub print_help {
    print <<"__END";
$0 [OPTIONS ...]

Options:
    -h | --help         shows this help menu
    -v | --verbose      verbose mode
    -u | --unit         set default unit to 1 day (24H)

    -W | --warn         sets warning level since last backup in seconds  (default: $default_WARN)
    -C | --crit         sets critical level since last backup in seconds (default: $default_CRIT)

__END

    exit $states{'OK'};
}
sub exit_status {
    my($msg,$exit_code) = @_;

    print "$msg\n";
    exit $exit_code;
}

my $not_backedup_CRIT;
my $not_backedup_WARN;
my $verbose;
my $unit;

GetOptions(
    'h|help'    => sub { print_help },
    'W|warn=i'  => \$not_backedup_WARN,
    'C|crit=i'  => \$not_backedup_CRIT,
    'v|verbose' => \$verbose,
    'u|unit'    => \$unit,
) or exit_status( 'Problem parsing options', $states{'UNKNOWN'} );

if( $not_backedup_CRIT ){
    $not_backedup_CRIT = $not_backedup_CRIT * 86400 if $unit;
}else{
    $not_backedup_CRIT = $default_CRIT;
}

if( $not_backedup_WARN ){
    $not_backedup_WARN = $not_backedup_WARN * 86400 if $unit;
}else{
    $not_backedup_WARN = $default_WARN;
}

print "CRIT: $not_backedup_CRIT : WARN: $not_backedup_WARN\n" if $verbose;

my @timenow    = [gettimeofday];
my $barch_conf = '/etc/barch/barch.conf';
my $summary    = '';
my $exit_code  = $states{'OK'};

if( !-e $barch_conf ){
    exit_status( 'Barch config file not found' , $states{'UNKNOWN'} );
}

# read config
my $config     = Config::Tiny->read($barch_conf);
my $reportfile = $config->{global}->{report} || '/var/cache/barch/status';

# cycles
my $bc_ntfs    = $config->{dd}->{bc_ntfs}  || 'weekly';
my $bc_unkwn   = $config->{dd}->{bc_unkwn} || 'weekly';

if( !-e $reportfile ){
    exit_status( 'Barch report file not found' , $states{'UNKNOWN'} );
}else{
    my $report = Config::Tiny->read($reportfile)
        or exit_status("CRITICAL can't read report file", $states{'CRITICAL'});
    my $count  = keys %$report;

    if( $count < 1 ){
        exit_status('WARNING no backups found', $states{'WARNING'} );
    }

    foreach my $section ( keys %$report ){
        my $report_status = $report->{$section}->{'status'};
        my $report_code   = $report->{$section}->{'exit_code'};
        my $report_time   = $report->{$section}->{'timestamp'};
        my $fstype        = $report->{$section}->{'fstype'} || 'unspecified';

        if( !defined($report_status) || !defined($report_code) || !defined($report_time) ){
            print "#$section:\n  Information is missing. skip\n" if $verbose;
            next;
        }

        my $elapsed_time  = $timenow[0][0] - $report_time;

        print "#$section\n  Status: $report_status\n  Last backup: $elapsed_time sec ago.\n  Report as: " if $verbose;

        # check exit code
        if( $report_code ne '0' ){
            if( $report_code ne '4' && $report_code ne '5' && $report_code ne '6' ){
                print "CRITICAL\n\n" if $verbose;
                $exit_code = $states{'CRITICAL'};
                $summary .= $section . "(c) ";
                next;
            }else{
                print "OK\n\n" if $verbose;
                next;
            }
        }
        # ntfs/unknown cycles
        elsif( $fstype =~ m/ntfs|unknown/ ){
            my $WARN;
            my $CRIT;
            my $CYCLE;

            if( $fstype eq 'ntfs' ){
                $CYCLE = $bc_ntfs;
            }else{
                $CYCLE = $bc_unkwn;
            }

            print "-> NTFS ($CYCLE) - " if $verbose;
            switch ($CYCLE){
              case 'daily' {
                $WARN = $not_backedup_WARN;
                $CRIT = $not_backedup_CRIT;
                }
              case 'weekly' {
                $WARN = 2678400;
                $CRIT = 2750400;
                }
              else {
                $WARN = $not_backedup_WARN;
                $CRIT = $not_backedup_CRIT;
                }
            }

            if( $elapsed_time > $WARN ){
                if( $elapsed_time > $CRIT ){
                    print "CRITICAL-OLD\n\n" if $verbose;
                    $exit_code = $states{'CRITICAL'};
                    $summary .= $section . "(c-old) ";
                    next;
                }elsif( $elapsed_time > $WARN ){
                    print "WARNING-OLD\n" if $verbose;
                    $exit_code = $states{'WARNING'} if ($exit_code != $states{'CRITICAL'});
                    $summary .= $section . "(w-old) ";
                    next;
                }
            }else{
                print "OK\n" if $verbose;
            }
        }
        # time passed since last backup
        elsif( $elapsed_time > $not_backedup_WARN ){
            if( $elapsed_time > $not_backedup_CRIT ){
                print "CRITICAL-OLD\n" if $verbose;
                $exit_code = $states{'CRITICAL'};
                $summary .= $section . "(c-old) ";
                next;
            }elsif( $elapsed_time > $not_backedup_WARN ){
                print "WARNING-OLD\n" if $verbose;
                $exit_code = $states{'WARNING'} if ($exit_code != $states{'CRITICAL'});
                $summary .= $section . "(w-old) ";
                next;
            }
        }else{
            print "OK\n" if $verbose;
        }
        print "\n" if $verbose;
    }
}

if( $exit_code eq 0 ){
    exit_status( 'Backups: OK', $exit_code );
}elsif( $exit_code eq 1 ){
    exit_status( "WARNING: $summary", $exit_code );
}elsif( $exit_code eq 2 ){
    exit_status( "CRITICAL: $summary", $exit_code );
}else{
    exit_status( "UNKNOWN", $states{'UNKNOWN'} );
}
