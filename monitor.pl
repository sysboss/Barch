#!/usr/bin/perl
#
# Barch v6.1
# Copyright (c) 2015 Alexey Baikov <sysboss[@]mail.ru>
#
# Barch monitoring utility
#

use strict;
use warnings;

use Switch;
use DateTime;
use Getopt::Long;
use Config::Tiny;
use POSIX       qw(   strftime   );
use Time::HiRes qw( gettimeofday );

####################
# Configuration    #
####################
my $pwd    = '/etc/barch';
my $pref   = '_bsnap';
my $cfg    = "$pwd/barch.conf";
my $conf   = Config::Tiny->read($cfg);
my $cycle  = $conf->{default}{vol_cycle} || '12H';
my %states = (
    OK       => 0,
    WARNING  => 1,
    CRITICAL => 2,
    UNKNOWN  => 3,
);

sub convert_time {
    my $time  = shift;
    return if !$time;

    my $days  = int($time / 86400);
       $time -= ($days * 86400);
    my $hours = int($time / 3600);
       $time -= ($hours * 3600);
    my $minutes = int($time / 60);
    my $seconds = $time % 60;

    $days    = $days    < 1 ? '' : $days  . 'd ';
    $hours   = $hours   < 1 ? '' : $hours . 'h ';
    $minutes = $minutes < 1 ? '' : $minutes.'m ';

    return "$days$hours$minutes${seconds}s";
}

sub parse_period {
    my $string = shift;
    my $cycle_regex = '^(\d+)(M|H|D|W)$';

    # validate period syntax
    $string =~ /$cycle_regex/i;
    return 'invalid' if( !$1 or !$2 );

    switch( uc($2) ){
        case 'M' { return int( $1 * 60     ) }
        case 'H' { return int( $1 * 3600   ) }
        case 'D' { return int( $1 * 86400  ) }
        case 'W' { return int( $1 * 604800 ) }
    }
    return 'invalid';
}

sub exit_status {
    my($msg,$exit_code) = @_;

    print "$msg\n";
    exit $exit_code;
}

# Set default thresholds
$cycle = parse_period($cycle);

my $default_WARN = $cycle + ($cycle / 2);
my $default_CRIT = $cycle * 2;
my $HdefaultWARN = convert_time($default_WARN);
my $HdefaultCRIT = convert_time($default_CRIT);

sub print_help {
    print << "_END_USAGE";
usage: $0 [OPTIONS ...] FROM

Options:
  -h|--help                Help (this info)
  -v|--verbose             Verbose mode
  -e|--erronly             Show only failed backups

  -W|--warn                Warning threshold (default: $HdefaultWARN)
  -C|--crit                Critical threshold (default: $HdefaultCRIT)

_END_USAGE

    exit $states{'OK'};
}

my $not_backedup_CRIT;
my $not_backedup_WARN;
my $verbose;
my $erronly;

GetOptions(
    'h|help'    => sub { print_help },
    'W|warn=s'  => \$not_backedup_WARN,
    'C|crit=s'  => \$not_backedup_CRIT,
    'v|verbose' => \$verbose,
    'e|erronly' => \$erronly,
) or exit_status('Unknown option', $states{'UNKNOWN'});

$default_CRIT = parse_period($not_backedup_CRIT)
    if $not_backedup_CRIT;

$default_WARN = parse_period($not_backedup_WARN)
    if $not_backedup_WARN;

print "Critical threshold should be greater then waring\n" and exit $states{'UNKNOWN'}
    if $default_WARN > $default_CRIT;

print "Critical threshold: $default_CRIT\n" .
      "Warning threshold: $default_WARN\n\n" if $verbose;

# variables
my @timenow    = [gettimeofday];
my $summary    = '';
my $exit_code  = $states{'OK'};
my $reportfile = $conf->{global}->{report} || '/var/cache/barch/status';
my $custom     = Config::Tiny->read($conf->{advanced}{custom}) || '';

# verify config exists
exit_status('Barch config file not found' , $states{'UNKNOWN'})
    if not -e $cfg;

# verify report file exists
exit_status('Barch report file not found' , $states{'UNKNOWN'})
    if not -e $reportfile;

my $report = Config::Tiny->read($reportfile)
    or exit_status("CRITICAL failed to read report file", $states{'CRITICAL'});
my $count  = keys %$report;

# exit if no backups reported
exit_status('WARNING no backups found', $states{'WARNING'} )
    if $count < 1;

sub is_custom {
    my $section = shift;

    if( $conf->{advanced}{custom} && -e $conf->{advanced}{custom} ){
        foreach my $key ( keys %{ $custom } ){
            return 1 if $key eq $section;
        }}
    return 0;
}

foreach my $section ( keys %$report ){
    my $report_status = $report->{$section}{'status'};
    my $report_code   = $report->{$section}{'exit_code'};
    my $report_time   = $report->{$section}{'timestamp'};
    my $fstype        = $report->{$section}{'fstype'} || 'unspecified';

    if( is_custom($section) ){
        if( $custom->{$section}{'backup'} eq 'false' ){
            print "[$section]\n  Disabled in custom.conf. skip\n\n" if $verbose;
            next;
        }
    }

    if( !defined($report_status) || !defined($report_code) || !defined($report_time) ){
        print "[$section]\n  Information is missing. Skip\n\n" if $verbose;
        next;
    }

    my $elapsed_time = $timenow[0][0] - $report_time;
    my $report_as    = 'OK';

    # check exit code
    if( $report_code ne '0' ){
        if( $report_code ne '4' && $report_code ne '5' && $report_code ne '6' ){
            $report_as = 'CRITICAL';
            $exit_code = $states{'CRITICAL'};
            $summary .= $section . "(c) ";
        } else {
            $report_as = 'OK';
        }
    }
    # time passed since last backup
    elsif( $elapsed_time > $default_WARN ){
        if( $elapsed_time > $default_CRIT ){
            $report_as = "CRITICAL-OLD";
            $exit_code = $states{'CRITICAL'};
            $summary .= $section . "(c-old) ";
        } elsif( $elapsed_time > $default_WARN ){
            $report_as = "WARNING-OLD";
            $exit_code = $states{'WARNING'} if ($exit_code != $states{'CRITICAL'});
            $summary .= $section . "(w-old) ";
        }
    }

    print "[$section]\n  Status: $report_status\n  Last backup: $elapsed_time sec ago.\n  Report as: $report_as\n\n"
        if( $verbose && ( $erronly && $report_as ne 'OK' ) );
}

if( $exit_code eq 0 ){
    exit_status( 'Backups: OK', $exit_code );
}elsif( $exit_code eq 1 ){
    exit_status( "WARNING: $summary", $exit_code );
}elsif( $exit_code eq 2 ){
    exit_status( "CRITICAL: $summary", $exit_code );
} else {
    exit_status( "UNKNOWN", $states{'UNKNOWN'} );
}

# vim:sw=4:ts=4:et