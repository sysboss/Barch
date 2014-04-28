Barch - LVM Backups manager
===========================

## Description ##
An open source lvm snapshot and backup utility for linux based systems. Barch conducts automatic and predefined filesystem recognition. Supports full/incremental or hourly,daily,weekly backup formats. Based on dd, rsync, rsnapshot and duplicity.

For more reference regarding duplicity and rsnapshot, check: http://www.rsnapshot.org/ http://duplicity.nongnu.org/

## Requirements ##
Required packages:   
```
perl lvm2 rsnapshot rsync kpartx tree python software-properties-common python-software-properties python-paramiko python-gobject-2 ncftp
```

Required Perl-Moules:
```
Getopt::Long Config::Tiny Log::Dispatchouli POSIX LWP::Simple strictures Time::HiRes File::Lockfile Parallel::ForkManager
```

## Installation ##
Clone files to some temporary folder on target host then run:  
> git clone git@github.com:sysboss/Barch.git
> ./INSTALL
  
Follow the installer instructions.  

## Usage and maintenance ##
After configuration complete, main config file syntax can be verified with:  
> barch --syntax  

However, it's highly recommanded to create a test LV volume to verify correct execution
and prevent data corruptions or any other damage.  

That could be done by running with --only option, to initiate single specified volume backup, as shown:  
> barch --verbose -i hourly -o testLVname  

Verbose mode will help you see the full backup flow. In case of any failure or warning, see problems resolution section below.

## Documentation ##
### Introduction - How it works? ###
Barch conducts LVM incremental backups by discovering entire hierarchy of each logical volume such as partitions, filesystems etc.  

Before backup, Barch creates a snapshot of the target LV and mount it to a temporary mount point. This method allows the backup tool to sync changes (increments) between the last backup and the current state.  

Barch is written in Perl and depends on duplicity, rsnapshot, rsync and kpartx. Please make sure this tools installed.
