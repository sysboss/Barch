Barch - LVM Backup Manager
===========================

## Description ##
An open source LVM backup utility for linux based systems.  
Barch conducts automatic and predefined volume structure recognition. Supports full/incremental backups. Based on duplicity.

Key features:
 * Full/Incremental backups (rdiff)
 * Encrypted
 * Bandwidth-efficient
 * Parallel execution
 * HTTP interface
 * DRBD clusters compatible
 * Syslog logging
 * Monitoring utility

## Introduction ##
LVM provides a convenient snapshot feature. This allows you to create an identical clone of a logical volume and store only the blocks that differ from it.

Barch is a robust automation daemon which provides LVM incremental backups, has an automatic recursive discovering algorithm to explore the entire hierarchy of each logical volume (such as partitions, filesystems etc).  

## How it works? ##
After Barch is configured, it runs through the following steps:
  * Creates a temporary snapshot of the volume
  * Barch discovers the volume structure (eg. internal partitions)
  * Mounts the snapshot on a temporary directory
  * Using duplicity to sync changes (increments) since the last backup
  * Rotates the backups
  * Unmounts and removes the snapshot

Barch is an Open Source free product written in Perl and depends on duplicity, rsync and kpartx. Please make sure this tools installed.

For more reference regarding duplicity, check: http://duplicity.nongnu.org/

## Requirements ##
Required Packages:   
```
perl lvm2 rsync kpartx expat libexpat1 libexpat1-dev
```

Required Perl-Moules:
```
AnyEvent POSIX XML::Simple Sys::Syslog Time::Piece Net::OpenSSH Getopt::Long Config::Tiny Twiggy::Server AnyEvent::Util File::Lockfile File::Find::Rule Digest::MD5 Time::HiRes Switch List::Util JSON LWP::UserAgent
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
