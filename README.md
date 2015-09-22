# zfsbackup

This is a collection of scripts that together form a solution to make
backups to a zfs server that runs rsyncd. The idea is to have one rsync
module per source filesystem; each of these modules is rooted in a zfs
dataset.

After a backup run is completed, a snapshot is made of the zfs dataset
(triggered from rsyncd.conf, via "post-xfer exec").

Expiry information is stored in an attribute of the snapshot.

## Client side

The client subdir of the current directory contains the script that runs on
the client side, called zfsbackup-client.

It first reads defaults from /etc/zfsbackup/client.conf, then iterates over
the directories in /etc/zfsbackup/sources.d, each of which can contain the
following files and directories:

url		rsync URL to upload to (single line; subsequent lines are ignored)  
username	username to send to rsyncd  
password	password to send to rsyncd  
stdout		if exists, stdout will be redirected into it; could be a
		symlink or a fifo  
		Later versions may check if it's executable and if it is, run
		it and pipe stdout into it that way.  
stderr		like above, but for standard error  
exclude		will be passed to rsync using exclude-from  
include		will be passed to rsync using include-from  
files		will be passed to rsync using files-from  
filter		will be passed to rsync using --filter (one per line)  
options		further options to pass to rsync, one per line
		The last line should not have a trailing newline.  
path		if it's a symlink to a directory, the directory to copy;
		if it's a file or a symlink to a file, the first line is
		taken to be the name of the directory to copy.  
check		a script to run before doing anything else; decides whether
		to upload this directory at this time or not. Upload only
		proceeds if ./check exits successfully. Not even pre-client
		is run otherwise.  
pre-client	a script to run on the client before copying begins;
		if it returns unsuccessfully, rsync is not started,
		but post-client is still run.
		The supplied client/set-path-to-latest-zfs-snapshot script
		can be used to find the latest existing snapshot of a given
		zfs dataset and make the path symlink point to it (in
		.zfs/snapshot).  
pre-client.d/	a directory that will be passed to run-parts (after
		pre-client has been run, if it exists).  
post-client	a script to run on the client after copying finished.
		Its first argument is the exit status of pre-client; the 2nd
		argument is the exit status of rsync (provided it was run).  
post-client.d/	a directory that will be passed to run-parts (after
		post-client has been run, if it exists).  
no-sparse	if it exists, -S will not be passed to rsync (but "options"
		can override). -S is the default if no-inplace exists.
		(rsync doesn't support inplace and sparse simultaneously.)  
no-xattrs	like no-sparse, but for -X  
no-acls		like no-sparse, but for -A  
no-hard-links	like no-sparse, but for -H  
no-delete	like no-sparse, but for --delete  
no-partial	like no-sparse, but for --partial  
no-xdev		like no-sparse, but for -x (the default is to *not* cross
		filesystems)  
no-inplace	like no-sparse, but for --inplace (in-place updates are more
		space efficient with zfs snapshots unless dedup is also used)  
compress	if it exists, rsync will be called with -z  
compress-level	if it exists, contents will be appended to --compress-level=
		Warning: the file should contain only a number, no trailing
		newline  
bwlimit		if it exists, contents will be appended to --bwlimit=
		Warning: the file should contain only a number, no trailing
		newline.  
timeout		Tell rsync to exit if no data is transferred for this many
		seconds (--timeout). No trailing newline, just the number.
		Defaults to 3600.  
fsuuid		if it exists, its contents will be included in log messages and
		the backup inventory. pre-client scripts are expected to
		maintain it.  
snapuuid	if it exists, its contents will be included in log messages and
		the backup inventory. pre-client scripts are expected to
		maintain it.  
fstype		if it exists, its contents will be included in log messages and
		the backup inventory. pre-client scripts are expected to
		maintain it.  

Other specific rsync options may be supported explicitly in future versions.

You may place other files in sources.d directories (needed by custom pre- or
post-client scripts, for example).

The defaults try to accommodate expected usage so that as little
configuration is necessary as possible.

Note that it's possible to upload the same source directory to several
servers; just create separate sources.d directories for each remote
instance. Future versions may provide a different mechanism for this; e.g.
subdirs under each sources.d directory.

check, pre-client and post-client are started with the current working
directory set to the sources.d directory being processed.

Currently, sources.d directories are processed sequentially, in unspecified
order. Future versions may support concurrency.

If you invoke zfsbackup-client with command line arguments, each is taken to
be the path to a source.d style directory; absolute paths are processed as
is, relative ones are interpreted relative to /etc/zfsbackup/sources.d (or
whatever SOURCES is set to in the config).

### exit status

The client script runs all jobs related to each source in a subshell and
accumulates the exit statuses of all such subshells, then sets its own exit
status to that.

The accumulation is currently not capped, so I suppose it can overflow.

### client.conf

The client.conf file can currently contain the following settings (with
their current defaults):

```
# Path to sources.d directory:
SOURCES=/etc/zfsbackup/sources.d
# Path to scripts shipped with zfsbackup:
SCRIPTS=/usr/local/share/zfsbackup
# Path to default settings for new sources.d directories:
DEFAULTDIR=/etc/zfsbackup/client-defaults
# Path to directory with script to run after zfsbackup-create-source:
MKSOURCE_D=/etc/zfsbackup/mksource.d
# Used by mksource.d/create-remote-zfs:
REMOTEBACKUPPOOL=backup
REMOTEBACKUPPATH="$(hostname)"
# Whether to attempt to create remote zfs instance via ssh to hostname portion of url:
CREATEREMOTEZFS=0
# Set this to false to disable global fake super setting on per-module basis
# by default (increases performance by avoiding costly xattr operations;
# decreases security):
FAKESUPER=true
# You might want to use something like:
#coproc logger
#exec >&p
#exec 2>&p
```

### Mass creation of sources.d directories

In reality you'll want one sources.d directory for every filesystem you have,
and in many cases these will be backed up using the same username and password
and to the same server, but to a different rsync module.

A mechanism is provided to make this easier/more efficient.

In /etc/zfsbackup/client-defaults, you can create defaults for the following
files:

```
username password exclude include files filter options check pre-client
post-client no-sparse no-xattrs no-acls no-hard-links no-delete no-partial
no-xdev no-inplace compress compress-level bwlimit timeout
```

Additionally, a zfsbackup-create-source script is provided that creates a new
sources.d directory. It hardlinks the above files into the new sources.d dir,
with the expection of:

```
exclude include files filter check pre-client post-client options
```

These files, if they exist in /etc/zfsbackup/client-defaults, will be copied
into the new sources.d dir, not hardlinked. Existing files will not be
overwritten with defaults, but will be overwritten with values explicitly given
on the command line.

If /etc/zfsbackup/client-defaults contains a file called url-template, it will
be used to generate the url file of the new sources.d dir as follows:

__PATH__ in the url-template will be replaced by the name of the sources.d dir.

zfsbackup-create-source takes the following arguments (which are evaluated in
the below order):

-p, --path	Path to the directory to be backed up. If not specified,
		a path symlink will not be created.  
-r, --pre[@]	Pre-client script to run. Will be copied into the sources.d
		dir unless --pre@ is used, in which case a symlink will be
		created.  
-o, --post[@]	Post-client script; see --pre for details.  
-c, --check[@]	Check script; see --pre for details.  
-b, --bind	Use shipped pre-bindmount and post-bindmount script as
		pre-client and post-client script, respectively.
		These will bind mount the source fs to a temporary directory
		and upload that, then unmount the directory. Useful if you
		want to copy files that may be under mountpoints.  
-z, --zsnap	The path specified in --path refers to a zfs dataset that will
		have been mounted when the backup is performed. Use a
		pre-client script that sets the path to the latest snapshot of
		this zfs dataset and mounts it (via .zfs/snapshot).  
-s, --snap	NOT IMPLEMENTED. Reserved for LVM snapshot support.  
-d, --dir	Name of sources.d directory to create. Will try to autogenerate
		based on --path (so one of the two must be specified).  
-u, --username	Override remote username.  
-e, --exclude	Override exclude file.  
-i, --include	Override include file.  
--files		Override "files" file (for --files-from).  
-f, --filter	Override filter file.  
--no-sparse	Create no-sparse flag file.  
-S, --sparse	Remove no-sparse flag file.  
--no-xattrs	Create no-xattrs flag file.  
-X, --xattrs	Remove no-xattrs flag file.  
--no-acls	Create no-acls flag file.  
-A, --acls	Remove no-acls flag file.  
--no-hard-links Create no-hard-links flag file.  
-H, --hard-links Remove no-hard-links flag file.  
--no-delete	Create no-delete flag file.  
--delete	Remove no-delete flag file.  
--no-partial	Create no-partial flag file.  
-P, --partial	Remove no-partial flag file.  
--no-xdev	Create no-xdev flag file.  
-x, --xdev	Remove no-xdev flag file.  
--no-inplace	Create no-inplace flag file.  
--inplace	Remove no-inplace flag file.  
--compress	Create compress flag file.  
--no-compress	Remove compress flag file.  
--compress-level Override compress level.  
--bwlimit	Override bwlimit.  
--url		Provide specific URL to back up to.  

If /etc/zfsbackup/mksource.d exists, the scripts in it will be run with
run-parts(8). The scripts will be passed the following environment variables:

zbSOURCENAME	Absolute path to new sources.d directory.  
zbURL		URL being backed up to, if available.  
zbPATH		path as specified on the zfsbackup-create-source command line.  
zbUSERNAME	username that will be used for uploads.  

Such scripts can be used to output commands that will create the necessary zfs
instance and rsyncd.conf entries on the backup server (or even run them via
ssh).

Some examples are provided.

TODO: support creating several sources.d directories, pertaining to
different backup servers, simultaneously. Ideally it'd be possible to
enumerate backup servers somewhere and then refer to them by some tag or
number; zfsbackup-create-source should include the tag of the server in the
sources.d directory it creates (or maybe there should be a separate
hierarchy, one per tag). The backups to the different servers should be
scheduled independently.

### Backup inventory

It is desirable for the client to keep logs of which source was backed up
when to where, and whether the backup completed successfully.

At the very least, syslog-style messages to this effect must be added to the
client (TODO).

It would be preferable to have a client-wide inventory of backups: what was
backed up when to where (with "what" including not just the source name, but
the actual path as well). Success/failure and so on should also be
indicated.

If the origin fs is zfs, it might be tempting to keep some of this data in
zfs properties; however, this is impractical because properties are
inherited by sub-filesystems. While this would be possible to workaround
(for example by including the name of the fs in the name of the property or
only considering the property to be valid if it's not inherited), it would
still be ugly.

The backup inventory has to have the following properties:

 * It has to reference the specific filesystem backed up, not just the name
   of the sources.d directory.
  * Preferably by UUID.
  * If a snapshot was used, the UUID of the origin fs should be listed; the
    UUID of the snapshot is less interesting but should be included for
    completeness.
  * The zfsbackup-client script itself doesn't and shouldn't care whether it's
    backing up a snapshot or not; this should be handled by pre/post-client
    scripts.
 * The data has to be structured, with a fixed number of fields.
  * (It could even be stored in a database.)
  * When stored as a plain file, each record must be on a single line, with
    fields separated by, I guess, spaces (or TABs).
   * Spaces can occur in fs names and elsewhere, but should not (it's bad
     practice). If absolutely necessary, I guess backslash escapes can be
     added to deal with embedded spaces (and, consequently, also embedded
     backslashes).

Possible record structure:

```
timestamp success/failure sources.d-entry originuuid snapshotuuid destination-url fstype preclientstatus postclientstatus starttime
```

In addition to appending records to the inventory, the following tools
should be written:

 * A tool to remove old records (of expired backups) from the inventory.
  * Problem: expiry is handled by the server; inventory by the client.
 * A tool to inventory all local filesystems and report which ones don't
   have recent enough backups.
  * It must be possible to set expectations on a per-fs basis (and to
    ignore certain filesystems completely).
   * This could be handled with zfs properties.
  * Preferably, while the tools would use UUIDs internally, they should
    use human readable identifiers in their interface.

### Client side zfs properties

While these are not used by the scripts in any way, I set the following
property on client filesystems as a matter of convention:

```
korn.zfsbackup:config
```

This can be either /path/to/source.d/dir (several dirs may be specified,
with colons between them) or "none". In the former case, this lists the
zfsbackup source.d style directories that cause this fs to be backed up.

"none" means that this fs is not backed up. I set this property explicitly
on all filesystems that don't need to be backed up; so whenever it is
inherited I can see that something that should get backed up is not. A list
of suspcious filesystems can be obtained with

```
zfs get -t filesystem,volume -s inherited korn.zfsbackup:config
```

If the same fs is being backed up to several destinations, multiple config
locations can be given by setting korn.zfsbackup:config:tag0,
korn.zfsbackup:config:tag1 etc.

TODO: for clients that use mostly zfs, much of the configuration could in
fact reside in zfs properties. I should give this some thought.

## Server side

On the server side, for a minimal setup, you only need to run rsyncd. An
example configuration is included.

If you want snapshots and auto-expiry, you'll want to include something like

post-xfer exec = /path/to/zfsbackup/make-snapshot 

in rsyncd.conf. This script runs
/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME if it exists. The script will be
passed the word "expires" as the first and only argument. This script is
expected to output a date in unix epoch seconds (date +%s). The snapshot
will be kept until this time and an at(1) job scheduled to remove it if
at(1) is available. The snapshot will have its korn.zfsbackup:expires
property set to the expiry date. If no
/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME script is provided, internal
defaults are used (heuristics based on day of week, day of month, day of
year). These can be overridden in
/etc/zfsbackup/server.conf. Expiry can be set to "never" to never expire a
snapshot.

Because the `at` job may not be run (for example, if the server is off), the
cronjob zfsbackup-expire-snapshots is provided. It looks for zfs snapshots
that have the korn.zfsbackup:expires property and removes any that are
expired. Future versions may support scoping (only expire snapshots under a
specific zpool or subtree).

No expiry takes place if the only or the latest successful backup would be
removed.

The /etc/zfsbackup/server.conf file can be used to override the
korn.zfsbackup property prefix to something else, by setting
PROPPREFIX=something.else; this allows derivative scripts to easily have
their own property namespace.

### Origin properties

The origin dataset can have a number of properties in the korn.zfsbackup
namespace (but see PROPPREFIX above) that influence the snapshot process
(these intentionally mimic dirvish options):

korn.zfsbackup:minsize	
	If the dataset's reported size (in bytes) is smaller than this, the
	backup is considered partial and korn.zfsbackup:partial is set to
	true on the snapshot. The default is 262144 (256k); set to 0 to
	disable. Future versions may support human-readable sizes.  

korn.zfsbackup:mininodes  
	If the number of inodes used by the dataset (as reported by df -i)
	is smaller than this, the backup is considered partial; see above.
	The default is 7 (6 inodes are in use in an empty zfs dataset). Set
	to 0 to disable.

	Note that these heuristics only work for initial backups; if a
	subsequent backup somehow fails midway but rsyncd reports success,
	there is no way to detect a partial transfer on the server side.

	Future versions may support checking how big the difference between
	the current upload and the last snapshot is; that may be a more
	useful heuristic.  

korn.zfsbackup:expire-default  
	If set, has to be a string date(1) understands. The expiry date of
	the snapshot will be set by this property instead of the internal
	heuristics. The /etc/zfsbackup/server.d/$RSYNC_MODULE_NAME overrides
	this value.  

korn.zfsbackup:expire-rule  
	Can currently be the absolute path to a script that will output the
	date of expiry (instead of /etc/zfsbackup/server.d/$RSYNC_MODULE_NAME).
	Future versions may support dirvish-like expire rules.  

korn.zfsbackup:index  
	* NOT IMPLEMENTED YET *
	Once implemented, will cause an index of the dataset to be generated
	and saved in its root directory before the snapshot is taken. The
	property should be set to the name of the index file. If it ends in
	.gz, it will be gzipped; if it ends in .bz2, it will be compressed
	using bzip2.  

korn.zfsbackup:image-default  
	A string parseable by date(1) that will be used to set the name of
	the snapshot. Defaults to zfsbackup-NAMEPREFIX-%Y-%m-%d-%H%M, where
	nameprefix is yearly, monthly, weekly-isoweekyear-week, daily or
	extra and is set either by the overridable expire_rule() shell
	function or by running "/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME
	nameprefix" if the script exists. The string NAMEPREFIX will be
	replaced by the current value of $nameprefix.  

korn.zfsbackup:min-successful  
	* NOT IMPLEMENTED YET *
	The minimum number of successful backups that must exist for one to
	be expired. Will default to 2 (leaving 1 after the expiry).  

### Snapshot properties

The following properties are set on snapshots:

korn.zfsbackup:partial  
	Set to true if the backup doesn't appear to contain enough files, or
	be big enough, to be complete. See origin properties.  

korn.zfsbackup:successful  
	Set to true if partial is not true AND $RSYNC_EXIT_STATUS is 0. Set
	to false otherwise.  

korn.zfsbackup:rsync_exit_status  
	Set to $RSYNC_EXIT_STATUS (passed from rsyncd).  

korn.zfsbackup:rsync_host_addr  
	Set to $RSYNC_HOST_ADDR (passed from rsyncd).  

korn.zfsbackup:rsync_host_name  
	Set to $RSYNC_HOST_NAME (passed from rsyncd).  

korn.zfsbackup:rsync_user_name  
	Set to $RSYNC_USER_NAME (passed from rsyncd).  

korn.zfsbackup:expires  
	Set to the expiry date (in epoch seconds).  

korn.zfsbackup:expires-readable  
	Set to the expiry date in human readable form. The format is
	currently hardcoded: "%Y%m%d %H:%M:%S".  

## Limitations

### Out of band metadata

The rsync protocol doesn't permit passing out-of-band metadata from the
client to the server. Thus, the server can't determine whether the client
thinks the transfer was successful, and other client-specific details such
as labels can't be passed to the server either, even though it would be
useful to store them in properties.

A possible mechanism to do it anyway would be to upload a .zfsbackup or
similar directory that contains the metadata. I may implement this later.

Another possible approach would be to have metadata rsync modules for all
backup directories... Messy.

### post-xfer exec and restores

rsyncd doesn't care whether the client uploads or downloads data (or both);
the post-xfer script is run regardless. This means that even if you download
(i.e. "restore") data from backup, a snapshot will be created. To avoid
this, have two rsync modules for all backup directories: one for uploads and
one of downloads. The one for downloads shouldn't have the post-xfer exec
directive.

### GNUisms, zsh

The scripts were written to be run on Linux, with zsh. I have no interest in
making them portable; if someone else wants to, go ahead.

## License

Currently, zfsbackup is licensed under the GPL, version 3.

I'm open to dual licensing it under the GPLv3 and other open source licenses
if there is a compelling case to do so. Obviously this is only practical as
long as there are few contributors.

## Copyright

zfsbackup was written by Andras Korn <korn-zfsbackup @AT@ elan.rulez.org> in
2012. Development continued through 2015.
