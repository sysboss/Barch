Barch - LVM Backup Manager
===========================

## Description ##
An open source LVM backup utility for linux based systems.  
Barch conducts automatic and predefined volume structure recognition. Supports full/incremental backups. Based on duplicity.

Key features:
 * Incremental backups
 * Parallel execution
 * HTTP web interface
 * DRBD clusters compatible
 * Syslog logging
 * Monitoring utility

### Introduction - How it works? ###
Barch conducts LVM incremental backups by discovering entire hierarchy of each logical volume such as partitions, filesystems etc.  

Before backup starts, Barch creates a snapshot of the target LV and mounts it to a temporary mount point. This allows the backup tool to sync changes (increments) between the last backup and the current state.  

Barch is written in Perl and depends on duplicity, rsync and kpartx. Please make sure this tools installed.

For more reference regarding duplicity, check: http://duplicity.nongnu.org/

## Requirements ##
Required Packages:   
```
perl lvm2 rsync kpartx expat libexpat1 libexpat1-dev
```

Required Perl-Moules:
```
AnyEvent POSIX XML::Simple Sys::Syslog Time::Piece Net::OpenSSH Getopt::Long Config::Tiny Twiggy::Server AnyEvent::Util File::Lockfile File::Find::Rule Digest::MD5 Time::HiRes Switch List::Util DDP
```

## Installation ##
Clone files to some temporary folder on target host, then run the INSTALL script provided:  
```
cd /tmp
git clone https://github.com/sysboss/Barch.git
./INSTALL
```

Follow the installer instructions.  

## Usage and maintenance ##
Check wiki for usage and maintenance examples https://github.com/sysboss/Barch/wiki

## Documentation ##
Check wiki for full documentation https://github.com/sysboss/Barch/wiki
