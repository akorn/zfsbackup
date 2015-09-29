# zfsbackup

This is a collection of scripts that together form a solution to make
backups to one or more zfs servers that run rsyncd. The idea is to have
one rsync module per source filesystem; each of these modules is rooted
in a zfs dataset.

After a backup run is completed, a snapshot is made of the zfs dataset
(triggered from `rsyncd.conf`, via `post-xfer exec`).

Expiry information is stored in an attribute of the snapshot.

## Client side

The `client` subdir of the current directory contains the script that runs on
the client side, called `zfsbackup-client`.

In the simplest case where you only have one backup server, it first reads
defaults from `/etc/zfsbackup/client.conf`, then iterates over the directories
in `/etc/zfsbackup/sources.d`, each of which pertain to a directory tree to be
backed up, and each of which can contain the following files and directories:

 * `url` -- rsync URL to upload to (single line; subsequent lines are ignored)
 * `username` -- username to send to rsyncd
 * `password` -- password to send to rsyncd
 * `stdout` -- if exists, stdout will be redirected into it; could be a symlink or a fifo. Later versions may check if it's executable and if it is, run it and pipe stdout into it that way (TODO).
 * `stderr` -- like above, but for standard error.
 * `exclude` -- will be passed to `rsync` using `--exclude-from`
 * `include` -- will be passed to `rsync` using `--include-from`
 * `files` -- will be passed to `rsync` using `--files-from`
 * `filter` -- will be passed to `rsync` using `--filter` (one per line)
 * `options` -- further options to pass to `rsync`, one per line. The last line should not have a trailing newline.
 * `path` -- if it's a symlink to a directory, the directory to copy (back up); if it's a file or a symlink to a file, the first line is taken to be the name of the directory to copy. If it's neither, the results are undefined.
 * `realpath` -- used by `pre-bindmount` helper script; it bind mounts `realpath` to `path` before backing up `path`.
 * `zfs-dataset` -- used by `set-path-to-latest-zfs-snapshot` helper script; it finds the latest snapshot of the ZFS dataset named in `zfs-dataset`, then makes `path` a symlink to it before invoking `rsync` on `path`. TODO: support zvols.
 * `check` -- a script to run before doing anything else; decides whether to upload this directory at this time or not. Upload only proceeds if ./check exits successfully. Not even pre-client is run otherwise.
 * `pre-client` -- a script to run on the client before copying begins; if it returns unsuccessfully, `rsync` is not started, but `post-client` is still run. The supplied `client/set-path-to-latest-zfs-snapshot` script can be used as a `pre-client` script to find the latest existing snapshot of a given zfs dataset and make the path symlink point to it (in `.zfs/snapshot`).
 * `pre-client.d/` -- a directory that will be passed to `run-parts` (after `pre-client` has been run, if it exists).
 * `post-client` -- a script to run on the client after copying finished (or immediately after `pre-client`, if `pre-client` fails). Its first argument is the exit status of `pre-client`; the 2nd argument is the exit status of `rsync` (provided it was run).
 * `post-client.d/` -- a directory that will be passed to run-parts (after post-client has been run, if it exists). The scripts in this directory will receive the same arguments as `post-client`.
 * `no-sparse` -- if it exists, `-S` will not be passed to `rsync` (except if it occurs in `options`). `-S` is the default if `no-inplace` exists (rsync doesn't support inplace and sparse simultaneously.) 
 * `no-xattrs` -- if it exists, `-X` will not be passed to `rsync` (except if it occurs in `options`). The default is to copy xattrs.
 * `no-acls` -- if it exists, `-A` will not be passed to `rsync` (except if it occurs in `options`). The default is to copy POSIX ACLs.
 * `no-hard-links` -- if it exists, `-H` will not be passed to `rsync` (except if it occurs in `options`). The default is to reproduce hardlinks.
 * `no-delete` -- if it exists, `--delete` will not be passed to `rsync` (except if it occurs in `options`). The default is to delete remote files that are no longer present locally; however, you need to pass `--delete-excluded` explicitly via `options` for now.
 * `no-partial` -- if it exists, `--partial` will not be passed to `rsync` (except if it occurs in `options`). The default is to use partial transfers.
 * `no-xdev` -- if it exists, `-x` will not be passed to `rsync` (except if it occurs in `options`). The default is *not* to cross mountpoint boundaries.
 * `no-inplace` -- if it exists, `--inplace` will not be passed to `rsync` (except if it occurs in `options`). In-place updates are probably more space efficient with zfs snapshots unless dedup is also used, and thus are turned on by default.
 * `compress` -- if it exists, rsync will be called with `-z`. The default is not to use compression in rsync.
 * `compress-level` -- if it exists, contents will be appended to `--compress-level=`. The file should contain only a number, no trailing newline.
 * `bwlimit` -- if it exists, contents will be appended to `--bwlimit=`. The file should contain only a number, no trailing newline.
 * `timeout` -- Tell rsync to exit if no data is transferred for this many seconds (`--timeout`). No trailing newline, just the number. Defaults to 3600.
 * `fsuuid` -- if it exists, its contents will be included in log messages and the backup inventory. Currently not very useful.
 * `snapuuid` -- if it exists, its contents will be included in log messages and the backup inventory. pre-client scripts are expected to update this file. Currently not very useful.
 * `fstype` -- if it exists, its contents will be included in log messages and the backup inventory. Currently not very useful.

Other specific `rsync` options may be supported explicitly in future versions.

You may place other files in `sources.d` directories (needed by custom pre- or
post-client scripts, for example).

The defaults try to accommodate expected usage so that as little
configuration as possible is necessary.

Note that even without using the explicit multi-server support it's possible
to upload the same source directory to several servers; just create separate
sources.d directories for each remote instance.

`check`, `pre-client` and `post-client` are started with the current working
directory set to the sources.d directory being processed.

Currently, sources.d directories are processed sequentially, in unspecified
order. Future versions may support concurrency (also see "Scheduling backups"
below).

If you invoke `zfsbackup-client` with command line arguments, each is taken to
be the path to a source.d style directory; absolute paths are processed as
is, relative ones are interpreted relative to `/etc/zfsbackup/sources.d` (or
whatever `SOURCES` is set to in the config).

### exit status

The client script runs all jobs related to each source in a subshell and
accumulates the exit statuses of all such subshells, then sets its own exit
status to that.

The accumulation is currently not capped, so I suppose it can overflow.

### client.conf

The `client.conf` file can currently contain the following settings (with
their current defaults):

#### single-server case

This is a minimal, simple configuration.

```zsh
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
CREATEREMOTEZFS=false
# Whether to attempt to create remote rsyncd.conf stanza
# (currently assumes a conf.d style directory hierarchy with a top-level Makefile):
REMOTE_APPEND_RSYNCD_CONF=false
# username:group to chown remote zfs instance to if fakesuper = true
BACKUPOWNER=nobody:nogroup
# Set this to false to disable global fake super setting on per-module basis
# by default (increases performance by avoiding costly xattr operations;
# decreases security):
FAKESUPER=true
# Where to create mountpoints for, and mount, directories to backup if we're using
# bind mounts to back them up including stuff hidden under mountpoints. This setting
# is used at zfs-create-source time.
BINDROOT=/mnt
# An array of zfs properties you want set on newly created zfs instances,
# if any (note that currently there is no way to override these from the
# command line; maybe  instead of setting them here, you should let them
# be inherited from the parent fs on the server):
#DEFAULT_ZFS_PROPERTIES=(-o exec=off -o suid=off -o devices=off)
```

#### multi-server case

This configuration should work for the single-server as well as for the
multi-server case.

```zsh
# if a server tag is set via the command line, $BACKUPSERVER will contain it,
# so that the client.conf file can reference it:
#
# An array we'll put the names of the servers we're asked to back up to in.
# zfsbackup-create-source and zfsbackup-client use this.
BACKUPSERVERS=(server1 [ server2 [ server3 [ ... ] ] ])	
# Path to sources.d directories:
SOURCES=/etc/zfsbackup/sources.d${BACKUPSERVER:+/$BACKUPSERVER}
# Path to scripts shipped with zfsbackup:
SCRIPTS=/usr/local/share/zfsbackup
# Path to default settings for new sources.d directories:
DEFAULTDIR=/etc/zfsbackup/client-defaults${BACKUPSERVER:+/$BACKUPSERVER}
# Path to directory with script to run after zfsbackup-create-source:
MKSOURCE_D=/etc/zfsbackup/mksource.d
# Used by mksource.d/create-remote-zfs:
REMOTEBACKUPPOOL=backup
REMOTEBACKUPPATH="$(hostname)"
# Whether to attempt to create remote zfs instance via ssh to hostname portion of url:
CREATEREMOTEZFS=false
# Whether to attempt to create remote rsyncd.conf stanza
# (currently assumes a conf.d style directory hierarchy with a top-level Makefile):
REMOTE_APPEND_RSYNCD_CONF=false
# Set this to false to disable global fake super setting on per-module basis
# by default (increases performance by avoiding costly xattr operations;
# decreases security):
FAKESUPER=true
# Where to create mountpoints for, and mount, directories to backup if we're using
# bind mounts to back them up including stuff hidden under mountpoints. This setting
# is used at zfs-create-source time.
BINDROOT=/mnt
# An array of zfs properties you want set on newly created zfs instances,
# if any (note that currently there is no way to override these from the
# command line; maybe  instead of setting them here, you should let them
# be inherited from the parent fs on the server):
#DEFAULT_ZFS_PROPERTIES=(-o exec=off -o suid=off -o devices=off)
# You might want to use something like:
#. /etc/zfsbackup/client.conf${BACKUPSERVER:+.$BACKUPSERVER}
# to override some of the above on a per-server basis.
```

### Mass creation of sources.d directories

In reality you'll want one sources.d directory for every filesystem you have
(per backupserver), and in many cases these will be backed up using the same
username and password and to the same server(s), but to a different rsync
module.

A mechanism is provided to make creating these sources.d directories
easier/more efficient.

In `/etc/zfsbackup/client-defaults[/$BACKSERVER]`, you can create defaults for
the following files:

```
username password exclude include files filter options check pre-client
post-client no-sparse no-xattrs no-acls no-hard-links no-delete no-partial
no-xdev no-inplace compress compress-level bwlimit timeout
```

Additionally, a `zfsbackup-create-source` script is provided that creates a new
sources.d directory. It hardlinks the above files into the new sources.d dir,
with the expection of:

```
exclude include files filter check pre-client post-client options
```

These files, if they exist in /etc/zfsbackup/client-defaults, will be copied
into the new sources.d dir, not hardlinked. Existing files will not be
overwritten with defaults, but will be overwritten with values explicitly
given on the command line.

If `/etc/zfsbackup/client-defaults[/$BACKUPSERVER]` contains a file
called `url-template`, it will be used to generate the url file of
the new sources.d dir as follows:

`__PATH__` in the url-template will be replaced by the basename of the
sources.d directory (so that the pathname of the remote directory will
contain the basename of the sources.d directory, not the name of the
directory being backed up).

`zfsbackup-create-source` takes the following arguments:

```
--server	Comma and/or space separated list of the names ("tags") of the
		backup servers to use. See the HOWTO for details.
-p, --path	Path to the directory to be backed up. If not specified,
		a path symlink will not be created.  
--pre[@]	Pre-client script to run. Will be copied into the sources.d
		dir unless --pre@ is used, in which case a symlink will be
		created.  
--post[@]	Post-client script; see --pre for details.  
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
-s, --snap	NOT IMPLEMENTED, TODO. Reserved for LVM snapshot support.  
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
--fake-super	Explicitly sets zbFAKESUPER=1 and exports it for mksource.d
--no-fake-super	Explicitly sets zbFAKESUPER=0 and exports it for mksource.d
-o prop=val	Set zfs property "prop" to value "val" on remote zfs dataset we create.
```

The precedence between contradicting options (e.g. `--no-xdev` and `--xdev`)
is intentionally not defined. Avoid passing contradicting options.

If `/etc/zfsbackup/mksource.d` exists, the scripts in it will be run with
run-parts(8). The scripts will inherit the following environment variables:

 * `BACKUPSERVER` -- set to the tag of a backup server. This is not necessarily a hostname, but it can be -- it's up to you. See the HOWTO for an example.
 * `zbFAKESUPER` -- set to 1 if `--fake-super` was specified; set to 0 if `--no-fake-super` was specified; unset otherwise (in which case the default from `client.conf` will be used).
 * `zbFORCEACLS` -- set to 1 if `--acls` was specified.
 * `zbFORCEXATTRS` -- set to 1 if `--xattrs` was specified.
 * `zbNOACLS` -- set to 1 if `--no-acls` was specified.
 * `zbNOXATTRS` -- set to 1 if `--no-xattrs` was specified.
 * `zbPATH` -- path as specified on the zfsbackup-create-source command line, or read from the pre-existing sources.d directory. It's always either the name of a zfs dataset or the location of the files to be backed up, even if `-b` was passed (i.e. it will not be the path to the bind mount, but the path to the directory to be bind mounted before backing it up).
 * `zbPATH_IS_ZFS` -- set to 1 if `--zsnap` was specified.
 * `zbSOURCENAME` -- Absolute path to new sources.d directory.
 * `zbURL` -- URL being backed up to, if available.
 * `zbUSERNAME` -- username that will be used for uploads.
 * `zbZFSPROPS` -- a space separated list of zfs properties, including the `-o` switch, to pass to `zfs create`. Embedded whitespace is shell-escaped.

Such scripts can be used to output commands that will create the necessary zfs
instance and rsyncd.conf entries on the backup server (or even run them via
ssh).

Some examples are provided.

### Scheduling backups

There are two supported ways of scheduling backups: via `cron(8)` and via
`runit(8)`.

Running as a `runit` service is my preferred solution, but using `cron`
should work fine too.

When using cron, you can either just invoke `zfsbackup-client` as a cronjob;
it will iterate over all sources.d directories (and all backupservers named
in `client.conf`), and try to back up each directory exactly once. If you
have `/usr/bin/chpst`, the script will use it to create lockfiles and ensure
that the same sources.d directory is not being processed by two or more
concurrent instances simultaneously.

#### The zfsbackup-sv script

The purpose of the `zfsbackup-sv` script is to run all backup jobs (by
invoking `zfsbackup-client`), then keep retrying failed backups until they
succeed or until the off-peak time window closes.

If all sources.d directories are processed successfully, the service stops
itself or sleeps a configurable amount of time (default until 22:00) and
exits, presumably to be restarted by `runit`. If the exit delay would
result in more than `$MAX_RUNTIME` (see below) seconds passing between
successive `zfsbackup-client` invocations, the delay is adjusted so that
`zfsbackup-client` can be rerun at most `$MAX_RUNTIME` seconds after the
previous run.

If some backups are unsuccessful (indicated by the presence of a
`stamp-failure` file in the `sources.d/sourcename` directory), the script
retries all failed backups in random order until they all succeed, or
until a configurable amount of time (by default, 24 hours -- `$MAX_RUNTIME`)
has passed since the last time `zfsbackup-client` was run.  Once this time
is reached, the script exits. (At this point it will either be restarted
by `runit`, causing `zfsbackup-client` to be run again, or it can be started
again by `cron`.)

The script will sleep for a random amount of [1;30] seconds between retry
attempts.

It uses the following configuration variables:

 * `EXIT_SLEEP_UNTIL` -- If `EXIT_ACTION` is set to `sleep-and-exit`, the script will try to sleep until this time (defaults to 22:00).
 * `EXIT_SLEEP_FIXED` -- If `EXIT_ACTION` is set to `sleep-and-exit`, and `EXIT_SLEEP_UNTIL` is unset, sleep this amount of time (defaults to 18h).
 * `MAX_RUNTIME` -- The maximum number of seconds the script is allowed to run. It won't abort a running `zfsbackup-client` if this time is exceeded, but will exit at the first opportunity. Defaults to 86400 (one day).
 * `SLEEP_IF_NOT_UP_FOR_MORE_THAN` -- Don't start backing up anything if uptime is less than this (after all, if we just rebooted, we may reboot again shortly; also, it may be preferable to avoid creating an immediate load spike after a boot). Defaults to 3600 (seconds); set to 0 to disable.
 * `ONBOOT_SLEEP` -- How long to sleep if uptime is less than SLEEP_IF_NOT_UP_FOR_MORE_THAN seconds. Defaults to 12h.
 * `EXIT_ACTION` -- What to do once finished:
   * `exit` -- Just exit the script. This is probably the most useful setting when running from cron(8).
   * `stop-service` -- Exit and avoid being restarted by runit. This is useful if you want some independent scheduling mechanism to start backups occasionally.
   * `sleep-and-exit` -- If `EXIT_SLEEP_UNTIL` is set, sleep until either `MAX_RUNTIME` would be exceeded or until the next occurrence of `EXIT_SLEEP_UNTIL`. If `EXIT_SLEEP_UNTIL` is unset, sleep `EXIT_SLEEP_FIXED` unconditionally.
 * `VERBOSE` -- Whether to print informational messages to stderr; defaults to 1, set to 0 to disable.
 * `SOURCES` -- Location of sources.d directory (set to a server-specific directory in the instance-specific config to only process one server).
 * `ZFSBACKUP_CLIENT_ARGS` -- An array of arguments to pass to `zfsbackup-client` -- e.g. `--server server1`.

The variables can be set in `/etc/zfsbackup/client.conf` or in
`/etc/default/name-of-runit-service` (e.g. `/etc/default/zfsbackup-server1`).
Using several differently named instances of the runit service you can easily run
backups to different servers in parallel.

##### Running it as a cron job

The other cron-based option is to invoke the `zfsbackup-sv` script as a
cronjob (make sure only one instance is running at any given time, or make
sure you have `/usr/bin/chpst`, or set `$lockprog` to some other similar
program in the config and override the `with_lock()` function; patches to
support other lockprogs welcome).

While this should work, it is untested.

##### Running it as a runit service (preferred)

Create /etc/default/zfsbackup-server1:

```zsh
SOURCES=/etc/zfsbackup/sources.d/server1
ZFSBACKUP_CLIENT_ARGS=(--server server1)
```

Create /etc/default/zfsbackup-server2:

```zsh
SOURCES=/etc/zfsbackup/sources.d/server2
ZFSBACKUP_CLIENT_ARGS=(--server server2)
```

Create `/etc/sv/zfsbackup-{server1,server2}`; symlink `zfsbackup-sv` to these
directories under the name `run`; set up `svlogd`-based logging for them;
then symlink them to `/service` (or whatever directory your `runsvdir` watches).

### Backup inventory (TODO)

It is desirable for the client to keep logs of which source was backed up
when to where, and whether the backup completed successfully.

Currently, the client produces syslog-style messages to this effect; however,
it would be preferable to have a client-wide inventory of backups: what was
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
   * If a snapshot was used, the UUID of the origin fs should be listed; the UUID of the snapshot is less interesting but should be included for completeness.
   * The zfsbackup-client script itself doesn't and shouldn't care whether it's backing up a snapshot or not; this should be handled by pre/post-client scripts.
 * The data has to be structured, with a fixed number of fields.
   * (It could even be stored in a database.)
   * When stored as a plain file, each record must be on a single line, with fields separated by, I guess, spaces (or TABs).
     * Spaces can occur in fs names and elsewhere, but should not (it's bad practice). If absolutely necessary, I guess backslash escapes can be added to deal with embedded spaces (and, consequently, also embedded backslashes).

Possible record structure:

```
timestamp success/failure sources.d-entry originuuid snapshotuuid destination-url fstype preclientstatus postclientstatus starttime
```

In addition to appending records to the inventory, the following tools
should be written:

 * A tool to remove old records (of expired backups) from the inventory.
   * Problem: expiry is handled by the server; inventory by the client.
 * A tool to inventory all local filesystems and report which ones don't have recent enough backups.
   * It must be possible to set expectations on a per-fs basis (and to ignore certain filesystems completely).
     * This could be handled with zfs properties.
   * Preferably, while the tools would use UUIDs internally, they should use human readable identifiers in their interface.

### Client side zfs properties

The supplied `mksource.d/zfs-set-korn-zfsbackup-config` scriptlet sets the
following property on client filesystems, if they're zfs and you passed `-z`
to `zfsbackup-create-source`:

```
korn.zfsbackup:config[:$BACKUPSERVER]
```

This can be either /path/to/source.d/dir or "none". In the former case, this
points to the zfsbackup source.d style directory that causes this fs to be
backed up (to $BACKUPSERVER if there are several servers).

"none" means that this fs is not backed up. I set this property explicitly
on all filesystems that don't need to be backed up; so whenever it is
inherited I can see that something that should get backed up is not. A list
of suspcious filesystems can be obtained with

```
zfs get -o name,property all -t filesystem,volume -s inherited | fgrep korn.zfsbackup:config | sed 's/[[:space:]]*korn.zfsbackup:config.*//'
```

If the same fs is being backed up to several destinations, multiple config
locations can be given by setting korn.zfsbackup:config:tag0,
korn.zfsbackup:config:tag1 etc. (as in the examples above).

TODO: for clients that use mostly zfs, much of the configuration could in
fact reside in zfs properties. I should give this some thought.

As a matter of convention, you can store the date and time of the last backup
audit in a zfs property for example like this:

```
zfs set korn.zfsbackup:last-audit="$(date)" poolname
```

Then, using `zfs list -s creation -o name,creation` you can check whether
there are any filesystems that were created after the last audit (which
may thus not have backups configured).

## Server side

On the server side, for a minimal setup, you only need to run rsyncd. An
example configuration is included.

If you want snapshots and auto-expiry, you'll want to include something like

```
post-xfer exec = /path/to/zfsbackup/make-snapshot
```

in `rsyncd.conf`. This script runs
`/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME` if it exists. The script will be
passed the word "expires" as the first and only argument. This script is
expected to output a date in unix epoch seconds (`date +%s`). The snapshot
will be kept until this time and an `at(1)` job scheduled to remove it if
`at(1)` is available. The snapshot will have its `korn.zfsbackup:expires`
property set to the expiry date. If no
`/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME` script is provided, internal
defaults are used (heuristics based on day of week, day of month, day of
year). These can be overridden in
`/etc/zfsbackup/server.conf` (see the `make-snapshot` script to get an idea
how). Expiry can be set to "never" to never expire a snapshot.

Because the `at` job may not be run (for example, if the server is off), the
cronjob `zfsbackup-expire-snapshots` is provided. It looks for zfs snapshots
that have the `korn.zfsbackup:expires` property and removes any that are
expired. Future versions may support scoping (only expire snapshots under a
specific zpool or subtree).

No expiry takes place if the only or the latest successful backup would be
removed.

The `/etc/zfsbackup/server.conf` and the `/etc/zfsbackup/client.conf` file can
be used to override the `korn.zfsbackup` property prefix to something else,
by setting `PROPPREFIX=something.else`; this allows derivative scripts to
easily have their own property namespace.

### Origin properties

The origin dataset can have a number of properties in the `korn.zfsbackup`
namespace (but see `PROPPREFIX` above) that influence the snapshot process
(these intentionally mimic dirvish options):

`korn.zfsbackup:minsize`	
	If the dataset's reported size (in bytes) is smaller than this, the
	backup is considered partial and korn.zfsbackup:partial is set to
	true on the snapshot. The default is 262144 (256k); set to 0 to
	disable. Future versions may support human-readable sizes.  

`korn.zfsbackup:mininodes`	
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

`korn.zfsbackup:expire-default`	
	If set, has to be a string date(1) understands. The expiry date of
	the snapshot will be set by this property instead of the internal
	heuristics. The /etc/zfsbackup/server.d/$RSYNC_MODULE_NAME overrides
	this value.  

`korn.zfsbackup:expire-rule`	
	Can currently be the absolute path to a script that will output the
	date of expiry (instead of /etc/zfsbackup/server.d/$RSYNC_MODULE_NAME).
	Future versions may support dirvish-like expire rules.  

`korn.zfsbackup:index`	
	* NOT IMPLEMENTED YET *
	Once implemented, will cause an index of the dataset to be generated
	and saved in its root directory before the snapshot is taken. The
	property should be set to the name of the index file. If it ends in
	.gz, it will be gzipped; if it ends in .bz2, it will be compressed
	using bzip2.  

`korn.zfsbackup:image-default`	
	A string parseable by date(1) that will be used to set the name of
	the snapshot. Defaults to zfsbackup-NAMEPREFIX-%Y-%m-%d-%H%M, where
	nameprefix is yearly, monthly, weekly-isoweekyear-week, daily or
	extra and is set either by the overridable expire_rule() shell
	function or by running "/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME
	nameprefix" if the script exists. The string NAMEPREFIX will be
	replaced by the current value of $nameprefix.  

`korn.zfsbackup:min-successful`	
	* NOT IMPLEMENTED YET *
	The minimum number of successful backups that must exist for one to
	be expired. Will default to 2 (leaving 1 after the expiry).  

### Snapshot properties

The following properties are set on snapshots:

`korn.zfsbackup:partial`	
	Set to true if the backup doesn't appear to contain enough files, or
	be big enough, to be complete. See origin properties.  

`korn.zfsbackup:successful`	
	Set to true if partial is not true AND $RSYNC_EXIT_STATUS is 0. Set
	to false otherwise.  

`korn.zfsbackup:rsync_exit_status`	
	Set to $RSYNC_EXIT_STATUS (passed from rsyncd).  

`korn.zfsbackup:rsync_host_addr`	
	Set to $RSYNC_HOST_ADDR (passed from rsyncd).  

`korn.zfsbackup:rsync_host_name`	
	Set to $RSYNC_HOST_NAME (passed from rsyncd).  

`korn.zfsbackup:rsync_user_name`	
	Set to $RSYNC_USER_NAME (passed from rsyncd).  

`korn.zfsbackup:expires`	
	Set to the expiry date (in epoch seconds).  

`korn.zfsbackup:expires-readable`	
	Set to the expiry date in human readable form. The format is
	currently hardcoded: "%Y%m%d %H:%M:%S". This is only provided
	for convenience; the scripts don't use it.  

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

`rsyncd` doesn't care whether the client uploads or downloads data (or both);
the post-xfer script is run regardless. This means that even if you download
(i.e. "restore") data from backup, a snapshot will be created. To avoid
this, have two rsync modules for all backup directories: one for uploads and
one of downloads. The one for downloads shouldn't have the post-xfer exec
directive.

### GNUisms, zsh

The scripts were written to be run on Linux, with zsh. I have no interest in
making them portable; if someone else wants to, go ahead.

### root privileges

Currently the client-side scripts assume they're being run as root.
This affects the `mksource.d` scripts in that they'll try to ssh to the
backupserver (if so configured) and to set local zfs properties.

TODO: It would be easy to support running as a non-root user (e.g. to back up
your homedir to a remote zfsbackup server provided to you by an administrator).

The `rsyncd` process on the server must run as root in order to be able to
create zfs snapshots (unless you use some funky delegation or sudo to work
around this). The transfers themselves don't need to use root; just be sure to
enable `fake super` and xattr support on the destination fs if you use a
non-root user to store files as. Performance will degrade somewhat and space
usage will increase due to the need to store a lot of metadata in xattrs.

## License

Currently, zfsbackup is licensed under the GPL, version 3.

I'm open to dual licensing it under the GPLv3 and other open source licenses
if there is a compelling case to do so. Obviously this is only practical as
long as there are few contributors.

## Copyright

zfsbackup was written by András Korn <korn-zfsbackup @AT@ elan.rulez.org> in
2012. Development continued through 2015.
