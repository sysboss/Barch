# ABSTRACT: LVM backups solution
package Barch;
use strict;
use warnings;

use DDP;
use AnyEvent;
use XML::Simple;
use Time::Piece;
use Sys::Syslog;
use Getopt::Long;
use Net::OpenSSH;
use Config::Tiny;
use AnyEvent::Util;
use File::Lockfile;
use Digest::MD5 'md5_hex';
use Time::HiRes 'gettimeofday';
use List::Util 'first';

our $VERSION = "6.1";

my $welcome = "Barch v$VERSION - LVM backups Solution";

sub usage {
    print << "_END_USAGE";
$welcome
Copyright (c) 2015 Alexey Baikov <sysboss\@mail.ru>

usage: $0 [ options ] FROM

Options:
  -c|--cleanup             Recovery mode
  -o|--only                Single logical volume to backup
  -h|--help                Help (this info)
  -f|--full                Force full backup
  --version                Show version
  --syntax                 Verify config file syntax

Debug Options:
  -v|--verbose             Log to stdout
  -d|--debug               Debug mode (very verbose)
  --dry-run                Discover only mode

_END_USAGE

    exit 0;
}

# TODO: some of these are not used (vgs, mount, etc.)
# TODO: remove as many of these as possible
# (e.g., "rm")
# TODO: replace all the rest with System::Command or something
my @required_commands = qw<
    lvm lvs vgs rsync rm tr ssh mount umount file
    kpartx duplicity nice ionice gzip gpg parted touch
>;

# required tools
my %commands = map {
    my $location = `which $_`
        or die "[ERR] Command not found: $_\n";

    $_ => $location;
} @required_commands;

sub run {
    # signals handler
    $SIG{TERM} = 'sigHandler';
    $SIG{INT}  = 'sigHandler';

    # options
    my $verbose ;
    my $cleanup ;
    my $debug   ;
    my $chconfig;
    my $singleLV;
    my $showhelp;
    my $showV   ;
    my $dry_run ;
    my $full_now;

    GetOptions(
        'v|verbose'    => \$verbose,
        'version'      => \$showV,
        'h|help'       => \$showhelp,
        'c|cleanup'    => \$cleanup,
        'd|debug'      => \$debug,
        'f|full'       => \$full_now,
        'o|only=s'     => \$singleLV,
        'syntax'       => \$chconfig,
        'dry-run'      => \$dry_run,
    ) || usage( "bad option" );

    ####################
    # Variables        #
    ####################
    my %lvs     = ();
    my $cv      = AE::cv;
    my %backups = ();

    ####################
    # Configuration    #
    ####################
    my $pwd  = '/etc/barch';
    my $pref = '_bsnap';
    my $conf = Config::Tiny->read( "$pwd/barchd.conf" );

    sub check_config {
        die "$pwd/barch.conf file not found"
            if not -e "$pwd/barch.conf";

        # required sections
        my @sections = ( 'default', 'global', 'snapshots', 'duplicity', 'dd', 'advanced' );
        my $conf_ok  = 0;

        foreach my $section (@sections){
            if ( ! first { $section eq $_ } keys %{$conf} ) {
                print "$section section is missing.\nCheck you configuration file\n";
                exit 2;
            }
        }

        foreach my $section ( keys %{$conf} ) {
            foreach my $parameter ( keys %{ $conf->{$section} } ) {
                if(
                    $parameter =~ /[\@#\-%&\$*+()]/ ||
                    $conf->{$section}->{$parameter} =~ /[#\-%&\$*+()]/
                ){
                    print "[$section]\n";
                    print "\t$parameter = $conf->{$section}->{$parameter}\n";
                    $conf_ok = 1;
                }
            }
        }

        print "[WARN] Custom config file $conf->{advanced}->{custom} not found\n"
            if( $conf->{advanced}->{custom} && !-e "$conf->{advanced}->{custom}" );

        if( $conf_ok != 0 ){
            print "Config [ERROR]\n";
            exit 2;
        }else{
            print "Config [OK]\n" and exit 0
                if( $chconfig );
        }

        return 0;
    }

    ####################
    # Special params   #
    ####################
    # check config
    check_config();

    # display help
    usage() if $showhelp;

    # run cleanup
    cleanup() and exit 0
        if $cleanup;

    # Global config
    my $logfacility = $conf->{global}->{facility} || 'deamon';
    my $lock_dir    = $conf->{global}->{lock_dir} || '/var/lock/barch';
    my $pidfile     = $conf->{global}->{pidfile}  || 'barch.pid';
    my $work_dir    = $conf->{global}->{work_dir} || '/var/cache/barch';
    my $reportfile  = $conf->{global}->{report}   || '/var/cache/barch/status';
    my $mount_dir   = "$work_dir/mounts";

    # Defaults
    my $check_drbd  = $conf->{default}->{check_drbd}  || 'false';
    my $backup_lvm  = $conf->{default}->{backup_lvm}  || 'false';
    my $skip_always = $conf->{default}->{skip_always} || 'swap';
    my $instance    = $conf->{default}->{instance}    || `hostname`;
    my $vol_grace   = $conf->{default}->{vol_grace}   || 600;

    # DRBD
    my $drbd_state  = $conf->{drbd}->{drbd_state}     || 'any';
    my $drbd_conn   = $conf->{drbd}->{drbd_conn}      || 'Connected';
    my $drbd_status = $conf->{drbd}->{drbd_status}    || 'UpToDate';

    # Snapshots
    my $snap_size   = $conf->{snapshots}->{snap_size} || '10G';
    my $snap_dir    = $conf->{snapshots}->{snap_dir}  || '/usr/local/backup';
    my %mount_opt   = ( 'default' => '-o acl -o noatime -r',
                        'xfs'     => '-o noatime -o ro',
                        'ntfs'    => '-o noatime -o ro'                    );

    # Nice and IONice configs
    my $cpu_nice    = $conf->{advanced}->{cpu_nice}   || '19';
    my $io_nice     = $conf->{advanced}->{io_nice}    || '7' ;
    my $max_forks   = $conf->{advanced}->{max_forks}  || '1' ;

    # Duplicity
    my $full_backup = $conf->{duplicity}->{full}              || '1W';
    my $retries     = $conf->{duplicity}->{retries}           || '6' ;
    my $keep_last   = $conf->{duplicity}->{remove_older_than} || '2W';
    my $encrypt_key = $conf->{duplicity}->{encrypt_key};
    my $encrypt_pass= $conf->{duplicity}->{encrypt_pass};
    my $rem_snapdir = $conf->{duplicity}->{remote_snap_dir};
    my $volsize     = $conf->{duplicity}->{volsize}           || '25'  ;
    my $src_mismatch= $conf->{duplicity}->{source_mismatch}   || 'deny';
    my $notif_less  = $conf->{duplicity}->{not_if_less_than}  || 43200 ;
    my $StrictHostKey=$conf->{duplicity}->{StrictHostKey};

    # dd
    my $dd_over_ssh = $conf->{dd}->{dd_over_ssh}              || 'true';
    my $dd_snapdir  = '';
    my $dd_rem_serv = '';

    if( $dd_over_ssh eq 'true' ){
        $dd_rem_serv= $conf->{dd}->{remote_server}   ;
        $dd_snapdir = $conf->{dd}->{remote_snap_dir} ;
    } else {
        $dd_snapdir = $conf->{dd}->{local_dd_snapdir};
    }

    # target server SSH credentials
    my $ssh_user    = $conf->{ssh}->{user} || 'root';
    my $ssh_pass    = $conf->{ssh}->{password};
    my $ssh_path    = $conf->{ssh}->{path} || '/usr/local/backup';
    my $ssh_server  = $conf->{ssh}->{server};

    # DRBD Params
    my @drbd_view = ();
    my $drbd_dump = ();
    chomp(my $localhost = `hostname`);

    # DEBUG parameters
    my $silent      = ' 1>/dev/null 2>/dev/null';
       $silent      = '' if $debug;

    ####################
    # Logging          #
    ####################
    # Initialize logging
    sub logger {
        my( $msg, $ident, $priority ) = @_;

        # defaults
        $priority = $priority || "info";
        $ident = $ident || 'Main';
        $ident = "Barch-$ident";

        return if !$msg;
        return if( $priority eq 'debug' && !$debug );

        $msg = "[$ident] [" . uc($priority) . "] $msg";

        # start log
        openlog $ident, "pid,cons", $logfacility;

        # write to log
        syslog( $priority, $msg );
        print "$msg\n" if $verbose;

        closelog();
    }

    sub exit_fatal {
        my( $msg, $ident ) = @_;
        $ident = 'Main' if !$ident;

        # write log
        logger("FATAL: $msg",$ident,'crit')
            if $msg;

        # cleanup
        cleanup();
        exit 2;
    }

    ####################
    # Verification     #
    ####################
    # verify required files/dirs exist
    mkdir $snap_dir   if not -e $snap_dir  ;
    mkdir $lock_dir if not -e $lock_dir;
    `touch $reportfile`;

    # Create lock file
    my $lockfile = File::Lockfile->new(
        $pidfile, $lock_dir
    );

    if( my $pid = $lockfile->check ){
        print "Barch is already running with PID: $pid\n"; exit;
    }

    ####################
    # Cleanup          #
    ####################
    # remove old lockfiles
    opendir my $dir, "$lock_dir";
    my @lock_files = readdir $dir;
    closedir $dir;

    foreach my $file ( @lock_files ){
        next if $file =~ /^\./;

        unlink "$lock_dir/$file";
    }

    $lockfile->write;

    # cleanup procedure
    sub cleanup {
        my $running = shift;

        # umount all
        `$commands{'umount'} -r $mount_dir/* $silent`;

        # destroy any possible snapshots
        chomp( my @snaps = `$commands{'lvs'} | grep _bsnap` );

        if( @snaps ){
            foreach my $sn (@snaps){
                # get info
                my( $vgname, $lvname, $lvsize, $lvunit, $lvsnap, $uid ) = parse_lvs($sn);

                if( !$lvname || !$vgname ){
                    logger("[EXC] cleanup failed to parse snapshots",'Main','warning');
                    return 2;
                }

                # remove partitions, if any
                `$commands{'kpartx'} -s -d /dev/$vgname/$lvname`;

                # umount
                `$commands{'umount'} $mount_dir/$lvname $silent`;

                # remove snapshot
                `$commands{'lvm'} lvremove -f /dev/$vgname/$lvname $silent`;

                if( $? eq 0 ){
                    logger(" - $vgname/$lvname snapshot removed.",$lvname);
                }else{
                    logger("failed to remove $vgname/$lvname.",$lvname,'err');
                }
            }
        }else{
            logger( "no snapshots to remove" );
        }

        # remove temporary folders
        `$commands{'rm'} -fr $mount_dir/* $silent` if !$running;

        # remove lock files
        `$commands{'rm'} -f $lock_dir/* $silent` if !$running;
        `find /root/.cache/duplicity/ -name *.lock | xargs $commands{'rm'}` if !$running;

        #unlink $lockfile if !$running;
        $lockfile->remove if !$running;
    }

    ####################
    # Subroutines      #
    ####################
    sub parse_lvs {
        shift =~ /^\s+(\w+|[aA-zZ0-9\-\_\.\+]*)\s+(\w+)\s+[^ ]+\s+([0-9\.]+)(\w)\s+(\w+\s+([0-9\.]+))?/;

        return {
            uid      => md5_hex("$1\@$2"),
            lvname   => $1,
            vgname   => $2,
            size     => $3,
            unit     => lc($4),
            snapsize => $6,
        };
    }

    sub is_disabled_volume {
        my $lvname = shift;

        if( $conf->{advanced}->{custom} && -e $conf->{advanced}->{custom} ){
            my $custom = Config::Tiny->read( $conf->{advanced}->{custom} );

            if( $custom->{$lvname}->{backup} ){
                return 0 if $custom->{$lvname}->{backup} eq 'false';
            }
            return 1;
        }else{
            return 1;
        }
    }

    sub check_drbd_state {
        my( $vgname, $lvname ) = @_;
        my $disk      = "/dev/$vgname/$lvname";
        my $drbd_dev  = '';
        my $drbd_disk = '';

        foreach my $resurce ( keys $drbd_dump->{'resource'} ){
            my $k = $drbd_dump->{'resource'}{$resurce}{'host'}{$localhost}{'volume'};
            my $d = $k->{'disk'};

            next if not $d;

            if( $d eq $disk ){
                $drbd_disk = $d;
                $drbd_dev  = $k->{'device'}{'content'};
                last;
            }
        }

        if( $drbd_disk ne '' ){
            my $drbd_name = ( split /\//, $drbd_disk )[-1];

            foreach my $dev ( @drbd_view ){
            $dev =~ /^\s+\d+\:(\w+|[aA-zZ0-9\-\_\.\+]*)\/\d+\s+(\w+)\s+(\w+)\/\w+\s+(\w+)\/.*/;

            if( $1 eq $drbd_name && $2 && $3 && 4 ){
                return {
                    dev    => $drbd_dev,
                    disk   => $drbd_disk,
                    state  => $3,
                    conn   => $2,
                    status => $4,
                };
            }}
        }

        return {dev => 'undefined'};
    }

    sub backup {
        my %hash   = @_;
        my $report = Config::Tiny->read( $reportfile );
        my $start  = time;
        my $path   = "$mount_dir/$hash{'lvname'}";
        my $device = "/dev/$hash{'vgname'}/$hash{'lvname'}";

        # skip if volume is disabled
        # in custom.conf file
        if( is_disabled_volume( $hash{'lvname'} ) eq 0 ){
            logger("$hash{'lvname'} backup is disabled by custom.conf");
            return;
        }

        # verify other instance
        # not running
        logger("Volume is locked by other instance", $hash{'lvname'}, 'alert') and return
            if -e "$lock_dir/$hash{'lvname'}.lock";

        # check last backup time
        $hash{'timestamp'} = $report->{$hash{'vgname'}.".".$hash{'lvname'}}->{'timestamp'};

        if( $hash{'timestamp'} ){
            my @timenow = [gettimeofday];
            my $passed  = $timenow[0][0] - $hash{'timestamp'};

            if( $passed < $notif_less && !$dry_run ){
                logger("$hash{'lvname'} was backed up $passed sec ago. Skip.");
                return;
            }
        } else {
            # never backed up
            # apparently, a new volume
            # fork_call {
            #     chomp(my $creation = `lvdisplay $device | grep -i 'creation'`);
            #     return $creation;
            # } sub {
            #     my $creation = shift;

            #     if( $creation ){
            #         $creation =~ /(\d+-\d+-\d+\s+\d+:\d+:\d+)/i;
            #         return if ! $1;

            #         my $t1 = Time::Piece->strptime($1 => '%Y-%m-%d %H:%M:%S');
            #         my $t2 = gmtime;
            #         my $diff = $t2 - $t1;

            #         # grace period
            #         if( $diff < $vol_grace ){
            #             logger("Volume was never backed up. Created: $1. ".
            #                "Delaying for grace period", $hash{'lvname'}, 'alert');
            #         }
            #     }
            # };
        }

        # check DRBD state if exist
        # and enabled in config
        if( @drbd_view && lc($check_drbd) eq 'true' ){
            $hash{'drbd'} = check_drbd_state($hash{'vgname'}, $hash{'lvname'});

            if( $hash{'drbd'}->{'dev'} ne 'undefined' ){
                # check DRBD state
                if( lc($drbd_state) ne 'any' &&
                    lc($drbd_state) ne lc( $hash{'drbd'}->{'state'} )
                ){
                    logger("[EXC] $hash{'lvname'} is a DRBD device. $hash{'drbd'}->{'state'}, skip",$hash{'lvname'});
                    return;
                }

                # check DRBD connection
                if( lc($drbd_conn) ne 'any' &&
                    lc($drbd_conn) ne lc( $hash{'drbd'}->{'conn'} )
                ){
                    logger("[EXC] $hash{'lvname'} is a DRBD device. $hash{'drbd'}->{'conn'}, skip",$hash{'lvname'});
                    return;
                }

                # check DRBD status
                if( lc($drbd_status) ne 'any' &&
                    lc($drbd_status) ne lc( $hash{'drbd'}->{'status'} )
                ){
                    logger("[EXC] $hash{'lvname'} is a DRBD device. $hash{'drbd'}->{'status'}, skip",$hash{'lvname'});
                    return;
                }
            }

            logger("DRBD detected", $hash{'lvname'}, 'debug');
        }

        ### Backup process START
        logger('Starting backup...',$hash{'lvname'});

        # create lock file
        my $lv_lock = File::Lockfile->new(
            $hash{'lvname'}.".lock", "$lock_dir",
        );
        $lv_lock->write;

        # create snapshot
        # my $lvcreate = `$commands{'lvm'} lvcreate -L${snap_size} -n $hash{'lvname'}${pref} -s $device`;

        # if( $? eq 0 ){
        #     logger("Snapshot created", $hash{'lvname'});
        # }else{
        #     logger("failed to create snapshot (code: $?). Skip.",$hash{'lvname'},'err');
        #     return;
        # }

        # create temporary mount point
        mkdir $path;

        # Start duplicity
        my $backup = run_cmd "/usr/bin/perl simulation.pl",
            # STDOUT
            '1>' => '/dev/null',
            # STDERR
            '2>' => sub {
                return if not @_;
                logger("duplicity error trace: @_",$hash{'lvname'},'err');
            },
            # PID
            '$$' => \$backups{$hash{'lvname'}}{'pid'};

        $backup->cb( sub {
            if( shift->recv ){
                logger("Duplicity backup failed", $hash{'lvname'}, 'err');
            } else {
                logger("Duplicity backup succeeded", $hash{'lvname'});
            }

            my $www = run_cmd 'w',
                '1' => sub { p @_ },
                '2' => sub { p @_ };

            # remove instance PID
            undef $backups{ $hash{'lvname'} }{'pid'};
        });
    }

    ####################
    # Pre-backup       #
    ####################
    # start
    logger("Starting pre-backup procedures");

    # create DRBD watcher
    my $wdr = AE::timer 3600, 3600, sub {
        if( $check_drbd eq 'true' ){
            fork_call {
                my @info = ();

                chomp($info[0] = `drbd-overview`);
                chomp($info[1] = `drbdadm dump-xml`);

                return @info;
            } sub {
                my $xml    = XML::Simple->new();
                $drbd_dump = $xml->XMLin($_[1]);
                @drbd_view = $_[0];
            };
        }
    };

    if( $check_drbd eq 'true' ){
        chomp(@drbd_view = `drbd-overview`);
        chomp($drbd_dump = `drbdadm dump-xml`);

        my $xml    = XML::Simple->new();
        $drbd_dump = $xml->XMLin($drbd_dump);
    } else {
        undef $wdr;
    }

    logger("Barch $VERSION started");

    # create logical volumes watcher
    my $wlv = AE::timer 0, 300, sub {
        fork_call {
            chomp( my @cmd = `$commands{'lvs'}` );
            return @cmd;
        } sub {
            return if not @_;
            my @volumes = @_;

            splice( @volumes, 0, 1 );
            my $length = scalar @volumes;

            for(my $i = $length -1; $i>0; $i-- ){
                my %hash = %{
                    parse_lvs( $volumes[$i] )
                };

                $lvs{ $hash{'lvname'} } = \%hash;

                # find snapshots
                if( $hash{'snapsize'} ){
                    # monitor self-created snapshots
                    if( $volumes[$i] =~ /$pref/ ){
                        # verify snapshot is not full
                        if( $hash{'snapsize'} > 90 ){
                            # TODO abort backup
                            # remove snapshot
                            print "WARNING $hash{'lvname'} snapshot running out of space. Aborting backup.\n";
                        }
                    }
                } else {
                    # backup volume
                    backup( %hash );
                    last; #<------------------------------ debug
                }

                # remove snapshot from list
                splice( @volumes, $i, 1 );
            }
        }
    };

    sub sigHandler {
        print "ABORT!\n";
        $lockfile->remove;
        $cv->send;
    }

    $cv->recv;
    $lockfile->remove;

    exit 0;
}

# vim:sw=4:ts=4:et
