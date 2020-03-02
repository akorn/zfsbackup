# zfsbackup

## Blurb

This is a collection of scripts that together form a solution to make
backups to one or more zfs servers that run rsyncd. The idea is to have
one rsync module per source filesystem; each of these modules is rooted
in a zfs dataset.

After a backup run is completed, a snapshot is made of the zfs dataset
(triggered from `rsyncd.conf`, via `post-xfer exec`).

Expiry information is stored in an attribute of the snapshot.

### Why not just use `zfs send`/`zfs receive`?

Using `zfs send` to push snapshots to a backup server is a valid backup
approach in many cases; perhaps even most cases where the client uses zfs.
I chose to still write `zfsbackup` for the following reasons:

 * I wanted to support clients that don't exclusively use zfs (heck, even Windows clients).
 * Historically, `zfs send` hasn't always been bug-free; some of the bugs threatened stability and/or data integrity. (As of zfsonlinux 0.8.1, I know of no such bugs.)
 * I wanted it to be possible to exclude files from the backup (very large files, or tempfiles, or coredumps etc.).
 * I wanted to be able to be flexible about the mapping of client side filesystems to server side filesystems (for example, to back up several client filesystems into a single server-side filesystem).
 * I wanted to support client clusters where only the currently active member is backed up, to the same server directory.
 * With `rsync`, only very limited trust has to exist between the client and the server; certainly neither needs root access on the other. (Although a malicious backup server could gain root on the client by trojaning the backups.)
 * With `rsync` clients (who can even be non-root users) can be enabled to autonomously restore their own files from backup with arbitrary granularity (from a single file to everything) without needing shell access on the backup server.
 * When I began working on `zfsbackup`, it wasn't possible (at least with zfsonlinux) to override zfs properties while receiving a stream; this meant, for example, that if the fs being received had a mountpoint of `/`, it would be mounted over the root directory of the receiving box, or not at all.
 * With `zfsbackup`, every backup is both full and incremental:
   * full in the sense that you don't need to keep any previous backup in order to be able to recover the most recent state (or any particular past state);
   * incremental in the sense that a new backup only needs to transfer as much data as has changed since the last backup, and will only need this amount of storage space.
 * Achieving the above with `zfs send` requires tight coupling between the client and the server:
   * The client needs to make sure it keeps (a `zfs bookmark` of) the last snapshot it transferred to the server, so that it can produce an incremental stream relative to it on the next backup. (This can be done with `zfs hold`/`zfs release`.)
   * The server must also keep the last snapshot it received so it can serve as a basis for the next incremental stream.
   * Some of the snapshot logic pertaining to backups would have to live on the client; that is, it would need to be the client that creates "yearly", "monthly", "weekly" and "daily" snapshots which it then sends to the backup server. This isn't objectively good or bad, but it's not what I prefer: I want the client to just push its backups to the server automatically, preferably daily, and for the retention policy to be configurable centrally on the backup server.
 * Initially, I thought the entire solution could be kept simple. :) While I try not to succumb to feeping creaturism, I admit I had to abandon this idea; both the client and the server are shaping up to be more complex than initially anticipated.

## Reference Manual

See `HOWTO.md` for quick start instructions; the information presented below
is intended more as a reference.

The `zfsbackup` system consists of the following macroscopic components:

 1. A client (`zfsbackup-client`) with a bunch of support scripts. These support scripts can create snapshots before running a backup, for example; `zfsbackup-create-source` helps automate initial backup configuration.
 2. Client-side configuration. There are some global config items, and each backup job has its own configuration. Typically you'd have one backup job per origin filesystem and backup server; e.g. "back up `/home` to `server1`" would be one job. `zfsbackup` calls these jobs "sources".
 3. An `rsync` server with zfs storage.
 4. Server side scripts:
   * `make-snapshot`, to be called by `rsync`, creates a snapshot when a backup transfer completes, setting various zfs properties.
   * `zfsbackup-expire-snapshots` looks for expired snapshots of backups and removes them.
   * `zfsbackup-restore-preexec` provides a client with a virtual view of all existing backup snaphots, which can be downloaded from via `rsync`.
 5. Some client-side mechanism that schedules backups (two solutions are provided: one for `cron`, one for `runit` or similar service supervisors).

### Client side

The `client` subdir of the project contains the script that runs on
the client side, called `zfsbackup-client`.

In the simplest case where you only have one backup server, it first reads
defaults from `/etc/zfsbackup/client.conf`, then iterates over the
directories in `/etc/zfsbackup/sources.d`, each of which pertains to a
directory tree to be backed up.

Normally, `sources.d` directories aren't created manually but by the
`zfsbackup-create-source` script.

A `sources.d` directory can contain the following files and directories, most
of which are optional, and most of which control the behaviour of `rsync`:

 * `bwlimit` -- if it exists, contents will be appended to `--bwlimit=` when calling `rsync`. The file should contain only a number, no trailing newline.
 * `check` -- a script to run before doing anything else; decides whether to upload this directory at this time or not. Upload only proceeds if ./check exits successfully. Not even pre-client is run otherwise.
 * `compress` -- if it exists, `rsync` will be called with `-z`. The default is not to use compression in `rsync`.
 * `compress-level` -- if it exists, contents will be appended to `--compress-level=`. The file should contain only a number, no trailing newline.
 * `exclude` -- will be passed to `rsync` using `--exclude-from`
 * `files` -- will be passed to `rsync` using `--files-from`
 * `filter` -- will be passed to `rsync` using `--filter` (one per line)
 * `fstype` -- if it exists, its contents will be included in log messages and the backup inventory. Currently not very useful.
 * `fsuuid` -- if it exists, its contents will be included in log messages and the backup inventory. Currently not very useful.
 * `include` -- will be passed to `rsync` using `--include-from`
 * `log-file` -- if it exists, will be passed to `rsync` as `--log-file=$(readlink -f log)`. If `log` doesn't exist, `--log-file-format` won't be passed to `rsync` either.
 * `log-file-format` -- if it exists, its contents will be passed as `--log-file-format=FORMAT`. The default format is "%B %U:%G %M %l %o %i %C	%f%L".
 * `logicalvolume` -- can either be a symlink of the form `/dev/vgname/lvname` or a file that contains a string of this form. Points to an LVM logical volume whose snapshot the `create-and-mount-snapshot` helper script should create and mount before rsync is run. This feature is untested, and the file has no effect unless the `create-and-mount-snapshot` is set up as a pre-client script.
 * `no-acls` -- if it exists, `-A` will not be passed to `rsync` (except if it occurs in `options`). The default is to copy POSIX ACLs.
 * `no-delete` -- if it exists, `--delete` will not be passed to `rsync` (except if it occurs in `options`). The default is to delete remote files that are no longer present locally. By default, this includes excluded files; see `no-delete-excluded` to turn that off.
 * `no-delete-excluded` -- if it exists, `--delete-excluded` will not be passed to rsync (except if it occurs in `options`). The default is to delete excluded files from the backup.
 * `no-hard-links` -- if it exists, `-H` will not be passed to `rsync` (except if it occurs in `options`). The default is to reproduce hardlinks.
 * `no-inplace` -- if it exists, `--inplace` will not be passed to `rsync` (except if it occurs in `options`). In-place updates are probably more space efficient with zfs snapshots unless dedup is also used, and thus are turned on by default.
 * `no-partial` -- if it exists, `--partial` will not be passed to `rsync` (except if it occurs in `options`). The default is to use partial transfers.
 * `no-recursive` -- if it exists, the arguments to `rsync` won't include `--recursive` (so that only the attributes of the `.` directory will be actually transferred). This is useful to force server-side snapshots to be created as if a backup had taken place, without calling `stat()` on all files and directories in the source filesystem. The `check-if-changed-since-snapshot` pre-client script can create and remove the `no-recursive` flag file as needed.
 * `no-snapshot` -- can contain a list of zfs datasets that should be excluded from recursive snapshotting and mounting by the `create-and-mount-snapshot` pre-client script.
 * `no-sparse` -- if it exists, `-S` will not be passed to `rsync` (except if it occurs in `options`). `-S` is the default if `no-inplace` exists (rsync doesn't support inplace and sparse simultaneously.)
 * `no-xattrs` -- if it exists, `-X` will not be passed to `rsync` (except if it occurs in `options`). The default is to copy xattrs.
 * `no-xdev` -- if it exists, `-x` will not be passed to `rsync` (except if it occurs in `options`). The default is *not* to cross mountpoint boundaries. (The "xdev" name was inspired by the `--xdev` option to `find(1)`.)
 * `options` -- further options to pass to `rsync`, one per line. The last line should not have a trailing newline.
 * `password` -- this file contains the password to send to `rsyncd`, via `--password-file=`.
 * `path` -- if it's a symlink to a directory, the directory to copy (back up); if it's a file or a symlink to a file, the first line is taken to be the name of the directory to copy. If it's neither, the results are undefined.
 * `post-client` -- a script to run on the client after copying finished (or immediately after `pre-client`, if `pre-client` fails). Its first two arguments are the exit status of `pre-client` and `pre-client.d` (or 0); the 3rd argument is the exit status of `rsync` (provided it was run -- empty string if it wasn't). The 4th argument is the sum of exit codes of processing all sub-sources (if any), or an empty string. Consider using `post-client.d/` instead.
 * `post-client.d/` -- a directory that will be passed to run-parts (after post-client has been run, if it exists). The scripts in this directory will receive the same arguments as `post-client`.
 * `pre-client` -- a script to run on the client before copying begins; if it returns unsuccessfully, `rsync` is not started, but `post-client` is still run. A number of pre-client scripts are supplied with zfsbackup; for example, `set-path-to-latest-zfs-snapshot` can be used to find the latest existing snapshot of a given zfs dataset and make the `path` symlink point to it (to its location under `.zfs/snapshot`); `create-and-mount-snapshot` can create a snapshot itself and mount it under `path/` or point `path/` to it. It's better to use `pre-client.d` than a single `pre-client` script.
 * `pre-client.d/` -- a directory that will be passed to `run-parts` (after `pre-client` has been run, if it exists).
 * `realpath` -- used by `pre-bindmount` helper script; it bind mounts `realpath` to `path` before backing up `path`.
 * `recursive-snapshot` -- used by the `create-and-mount-snapshot` helper script; if it exists, and `create-and-mount-snapshot` is set up as a pre-client script, it creates a recursive snapshot of the zfs dataset specified in `zfs-dataset`, then mounts the snapshots under `path/`.
 * `snapmountoptions` -- Currently not implemented. Will be used by the the `create-and-mount-snapshot` helper script; specifies the mount options to use when mounting a snapshot volume. The defaults should be safe and fine.
 * `snapsize` -- used by the the `create-and-mount-snapshot` helper script; specifies the size (as passed to `lvcreate`) of the LVM snapshot volume to create. The default is 100M.
 * `stderr` -- if it exists, stderr will be redirected into it; could be a symlink or a fifo. Later versions may check if it's executable and if it is, run it and pipe stderr into it that way (TODO).
 * `stdout` -- like above, but for standard output.
 * `subsources.d` -- a subdirectory that can contain further backup source definitions like this one (there is no arbitrary depth limit). Sub-sources are processed with the lock on the parent source held, *before* the `rsync` pertaining to the parent directory is called; this way a recursive snapshot can be taken on the server side once all transfers complete. See below for how this is useful.
 * `timelimit` -- If present, kill the rsync process after this many seconds. Depends on `timeout(1)` from coreutils.
 * `timeout` -- Tell rsync to exit if no data is transferred for this many seconds (`--timeout`). No trailing newline, just the number. Defaults to 3600. The implementation within `rsync` doesn't seem to be very robust as of 2019; `rsync` can hang for much longer without exiting.
 * `url` -- rsync URL to upload to (single line; subsequent lines are ignored). `zfsbackup-client` obtains an exclusive lock on this file before processing the directory, ensuring that no two instances can work on the same source simultaneously. If you remove and re-create the url file while a backup is in progress, mutual exclusion can't be guaranteed.
 * `username` -- username to send to `rsyncd`
 * `zfs-dataset` -- used by the `set-path-to-latest-zfs-snapshot` pre-client script; it finds the latest snapshot of the ZFS dataset named in `zfs-dataset`, then makes `path` a symlink to it before invoking `rsync` on `path`. The `create-and-mount-snapshot` script uses it as well to find out what zfs dataset to snapshot.
 * `zvol` -- used by `create-and-mount-snapshot` helper script; should contain the name of a zvol whose snapshot should be created and mounted under `path/` before rsync is run. This functionality isn't completely implemented yet and thus can't be used.

Other specific `rsync` options may be supported explicitly in future versions.

Additionally, the `zfsbackup` scripts can create the following files:

 * `check-exit-status` -- the exit status of the `./check` script when it was last run.
 * `last-backed-up-snapshot-creation` -- the creation date (in epoch seconds) of the snapshot we last tried to back up. Currently only supported/created for zfs. The mtime of this file is set to the date it contains.
 * `last-backed-up-snapshot-name` -- the name of the snapshot we last tried to back up. Currently only supported/created for zfs.
 * `last-successfully-backed-up-snapshot-creation` -- the creation date (in epoch seconds) of the zfs snapshot we last backed up successfully. Currently only supported/created for zfs. The mtime of this file is set to the date it contains.
 * `last-successfully-backed-up-snapshot-name` -- the name of the zfs snapshot we last backed up successfully. Currently only supported/created for zfs.
 * `post-client-exit-status` -- the exit status of the `./post-client` script when it was last run.
 * `post-client.d-exit-status` -- the exit status of `run-parts --report ./post-client.d` when it was last run.
 * `pre-client-exit-status` -- the exit status of the `./pre-client` script when it was last run.
 * `pre-client.d-exit-status` -- the exit status of `run-parts --report ./pre-client.d` when it was last run.
 * `rsync-exit-status` -- the exit status of the rsync process itself, from when it last completed (if rsync is currently running, the file may exist but will contain the exit status of the previous instance).
 * `stamp-failure` -- created and its timestamp updated whenever a backup is attempted but fails. Removed when a backup succeeds. Can be used to find datasets that weren't backed up successfully. Contains a brief message that indicates why the client thinks the backup failed.
 * `stamp-success` -- created and its timestamp updated whenever a backup completes successfully. Can be used to check when the last successful backup has taken place.
 * `zfsbackup-client-exit-status` -- the exit status of the entire `zfsbackup-client` subshell that processed this data source. Currently, this is the sum of the exit statuses of `rsync` and all post-client processes.

You may place other files in `sources.d` directories (needed by custom pre- or
post-client scripts, for example); they will be ignored by all scripts that
don't know what they are.

The defaults try to accommodate expected usage so that as little
configuration as possible is necessary (but it can still be a lot).

Note that even without using the explicit multi-server support it's possible
to upload the same source directory to several servers; just create separate
sources.d directories for each remote instance (e.g. `home_server1`,
`home_server2` etc.).

`check`, `pre-client` and `post-client` are started with the current working
directory set to the sources.d directory being processed.

Currently, sources.d directories are processed sequentially, in unspecified
order. It's not clear that zfsbackup itself needs to support concurrency
(also see "Scheduling backups" below). Since mutual exclusion is implemented
(you can't have two instances process the same source directory at the same
time), it's easy to have whatever mechanism you use to schedule
`zfsbackup-client` executions to run several instances in parallel. You can
even just start `n` copies in the background to run `n` parallel backups and
rely on the built-in locking for mutual exclusion.

If you invoke `zfsbackup-client` with command line arguments, each is taken to
be the path to a source.d style directory; absolute paths are processed as
is, relative ones are interpreted relative to `/etc/zfsbackup/sources.d` (or
whatever `SOURCES` is set to in the config). If you have several backup servers
configured, relative arguments are matched against the SOURCES directory of
each server.

#### exit status

The client script runs all jobs related to each source in a subshell and
accumulates the exit statuses of all such subshells, then sets its own exit
status to that.

The accumulation is currently not capped, so I suppose it can overflow.

#### client.conf

The `client.conf` file can currently contain the following settings (with
their current defaults):

##### single-server case

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
BINDROOT=/mnt/zfsbackup
# An array of zfs properties you want set on newly created zfs instances,
# if any (note that currently there is no way to override these from the
# command line; maybe  instead of setting them here, you should let them
# be inherited from the parent fs on the server):
#DEFAULT_ZFS_PROPERTIES=(-o exec=off -o suid=off -o devices=off)
```

##### multi-server case

This configuration should work for the single-server as well as for the
multi-server case.

```zsh
# This array contains the nicknames (not necessarily hostnames) of the backup
# servers we back up to. Scripts that source this configuration will, if
# necessary, iterate over its elements and re-source this configfile with
# $BACKUPSERVER set to the current element.
BACKUPSERVERS=(server1 [ server2 [ server3 [ ... ] ] ])
# One way of having per-server configuration is to rely on the $BACKUPSERVER
# variable, like this:
[[ -r /etc/zfsbackup/client-$BACKUPSERVER.conf ]] && . /etc/zfsbackup/client-$BACKUPSERVER.conf
# Another way is to reference $BACKUPSERVER in variable assignments, like in
# the examples below:
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
CREATEREMOTEZFS=true
# Whether to attempt to create remote rsyncd.conf stanza
# (currently assumes a conf.d style directory hierarchy with a top-level Makefile):
REMOTE_APPEND_RSYNCD_CONF=true
# Set this to false to disable global fake super setting on per-module basis
# by default (increases performance by avoiding costly xattr operations;
# decreases security):
FAKESUPER=true
# Where to create mountpoints for, and mount, directories to backup if we're using
# bind mounts to back them up including stuff hidden under mountpoints. This setting
# is used at zfs-create-source time.
BINDROOT=/mnt/zfsbackup${BACKUPSERVER:+/$BACKUPSERVER}
# An array of zfs properties you want set on newly created zfs instances,
# if any (note that currently there is no way to override these from the
# command line; maybe  instead of setting them here, you should let them
# be inherited from the parent fs on the server):
#DEFAULT_ZFS_PROPERTIES=(-o exec=off -o suid=off -o devices=off)
```

#### Semi-automatic creation of sources.d directories

In reality you'll want one sources.d directory for every filesystem you have
(per backupserver), and in many cases these will be backed up using the same
username and password and to the same server(s), but to a different rsync
module.

A mechanism is provided to make creating these sources.d directories
easier/more efficient.

In `/etc/zfsbackup/client-defaults[/$BACKSERVER]`, you can create defaults for
the following files:

```
bwlimit check compress compress-level exclude files filter include
log-file-format no-acls no-delete no-delete-excluded no-hard-links
no-inplace no-partial no-sparse no-xattrs no-xdev options password
post-client pre-client timeout username
```

The `zfsbackup-create-source` script creates a new sources.d directory. It
hardlinks the above files into the new sources.d dir, with the exception of:

```
exclude include files filter check pre-client post-client options stdout stderr
```

These files, if they exist in /etc/zfsbackup/client-defaults, will be copied
into the new sources.d dir, not hardlinked. Existing files will not be
overwritten with defaults, but will be overwritten with values explicitly
given on the command line.

If `/etc/zfsbackup/client-defaults[/$BACKUPSERVER]` contains a file
called `url-template`, it will be used to generate the `url` file of
the new sources.d dir as follows:

`__PATH__` in the `url-template` will be replaced by the basename of the
`sources.d` directory (so that the pathname of the remote directory will
contain the basename of the `sources.d` directory, not the name of the
directory being backed up).

`zfsbackup-create-source` takes the following arguments:

```
--server	Comma and/or space separated list of the names ("tags") of the
		backup servers to use. See the HOWTO for details.
-p, --path	Path to the directory to be backed up. If not specified,
		a path symlink will not be created.
--pre[@]	Pre-client script to run. Will be copied into the pre-client.d
		dir unless --pre@ is used, in which case a symlink will be
		created. Can be given multiple times.
--post[@]	Post-client script; works like --pre.
-c, --check[@]	Check script; works like --pre (except there is no check.d,
		so currently only a single check script can exist).
-b, --bind	Use shipped pre-bindmount and post-bindmount script as
		pre-client and post-client script, respectively.
		These will bind mount the source fs to a temporary directory
		and upload that, then unmount the directory. Useful if you
		want to copy files that may be under mountpoints.
-z, --zsnap	The path specified in --path refers to a zfs dataset that will
		have been mounted when the backup is performed. Use a
		pre-client script that sets the path to the latest snapshot of
		this zfs dataset and mounts it (via .zfs/snapshot).
-s, --snap	PARTIALLY IMPLEMENTED. Install create-and-mount-snapshot as
		pre-client script. Can be used with --zsnap. Works with zfs;
		currently requires manual steps for LVM. Installs appropriate
		post-client script too.
-rs --rsnap	Install create-and-mount-snapshot as a pre-client script;
		create recursive snapshot of the zfs instance given in -p.
		Implies --no-xdev. Installs appropriate post-client script too.
		As of now, recursive snapshot support is most useful for
		backups with no-xdev, where an entire client-side zfs subtree is
		backed up to a single server-side filesystem.
-d, --dir	Name of sources.d directory to create. Will try to autogenerate
		based on --path (so one of the two must be specified).
		Use only -d if you're reconfiguring an existing sources.d dir.
-A, --acls	Remove no-acls flag file.
--bwlimit	Override bwlimit.
--compress	Create compress flag file.
--compress-level Override compress level.
--delete	Remove no-delete flag file.
--delete-excluded Remove no-delete-excluded flag file.
-e, --exclude	Override exclude file.
--fake-super	Explicitly sets zbFAKESUPER=1 and exports it for mksource.d
-f, --filter	Override filter file.
--files		Override "files" file (for --files-from).
-H, --hard-links Remove no-hard-links flag file.
-i, --include	Override include file.
--inplace	Remove no-inplace flag file.
--no-acls	Create no-acls flag file.
--no-compress	Remove compress flag file.
--no-delete	Create no-delete flag file.
--no-delete-excluded Create no-delete-excluded flag file.
--no-fake-super	Explicitly sets zbFAKESUPER=0 and exports it for mksource.d
--no-hard-links Create no-hard-links flag file.
--no-inplace	Create no-inplace flag file.
--no-partial	Create no-partial flag file.
--no-sparse	Create no-sparse flag file.
--no-xattrs	Create no-xattrs flag file.
--no-xdev	Create no-xdev flag file (will cross filesystem boundaries).
-o prop=val	Set zfs property "prop" to value "val" on remote zfs dataset we create.
-P, --partial	Remove no-partial flag file.
-S, --sparse	Remove no-sparse flag file.
--url		Provide specific URL to back up to. Normally this would be generated
		from a template in $DEFAULTDIR/url-template.
-u, --username	Override remote username.
-X, --xattrs	Remove no-xattrs flag file.
-x, --xdev	Remove no-xdev flag file (won't cross filesystem boundaries;
		this is the default).
```

The precedence between contradicting options (e.g. `--no-xdev` and `--xdev`)
is intentionally not defined. Avoid passing contradicting options.

If `/etc/zfsbackup/mksource.d` exists, the scripts in it will be run with
run-parts(8). The scripts will inherit the following environment variables:

 * `BACKUPSERVER` -- set to the tag of a backup server. This is not necessarily a hostname, but it can be -- it's up to you. See the HOWTO for an example.
 * `zbFAKESUPER` -- set to 1 if `--fake-super` was specified; set to 0 if `--no-fake-super` was specified; unset otherwise (indicating that the default from `client.conf` should be used).
 * `zbFORCEACLS` -- set to 1 if `--acls` was specified.
 * `zbFORCEXATTRS` -- set to 1 if `--xattrs` was specified.
 * `zbNOACLS` -- set to 1 if `--no-acls` was specified.
 * `zbNOXATTRS` -- set to 1 if `--no-xattrs` was specified.
 * `zbPATH_IS_ZFS` -- set to 1 if `--zsnap` was specified or if the directory to be backed up is the root of a zfs instance.
 * `zbPATH` -- path as specified on the zfsbackup-create-source command line, or read from the pre-existing sources.d directory. It's always either the name of a zfs dataset or the location of the files to be backed up, even if `-b` was passed (i.e. it will not be the path to the bind mount, but the path to the directory to be bind mounted before backing it up).
 * `zbSOURCENAME` -- Absolute path to new sources.d directory.
 * `zbRECURSIVESNAPSHOT` -- set to 1 if `--rsnap` was specified.
 * `zbURL` -- URL being backed up to, if available.
 * `zbUSERNAME` -- username that will be used for uploads.
 * `zbZFSPROPS` -- a space separated list of zfs properties, including the `-o` switch, to pass to `zfs create`. Embedded whitespace is shell-escaped.
 * `zbZFSDATASET` -- the name of the zfs dataset being backed up (if the directory to be backed up is the root of a zfs instance).

Such scripts can be used to output commands that will create the necessary
zfs instance and rsyncd.conf entries on the backup server, or even run these
commands via ssh.

Some examples are provided.

#### Using sub-sources

On zfs boxes it often happens that there is a directory tree that forms a
single logical unit in some sense, but consists of several filesystems; for
example:

 * `/lxc` is a small filesystem to inherit properties from;
 * `/lxc/guest1` is a separate filesystem;
 * `/lxc/guest1/rootfs` is a separate filesystem with deduplication enabled;
 * `/lxc/guest1/rootfs/var` is a separate filesystem with no dedup;
 * `/lxc/guest1/rootfs/tmp` is a separate filesystem with `sync=disabled`. We don't want to back it up.

When backing something like this up, the following features are desirable:

 * Since the sub-filesystems can be interdependent, they might only be meaningfully consistent when snapshotted together, atomically.
 * Ideally, what's a separate fs on the client would be a separate fs on the server (to have the appropriate property set, especially concerning compression and dedup).
 * The filesystem layout on the server should be similar to the one on the client (i.e. if `bar` is a mounted under `/foo/bar` on the client, its backup should be mounted under something like `/backup/box/foo/bar`). This makes browsing the backups manually more natural and intuitive.
 * The server should take a recursive snapshot of the entire zfs subtree when the backup is complete, not (or not only) separate snapshots of each sub-filesystem.
 * It should be possible to restore the client to a specific backup with a single recursive rsync operation; that is, the server should be able to provide a hierarchical view of the snapshots of `foo` and `bar` such that `bar@snapshot` is mounted under `foo@snapshot/bar`. (This is implemented by the `zfsbackup-restore-preexec` and `zfsbackup-restore-postexec` scripts shipped with `zfsbackup`.)
 * Ideally, it should still be possible to take a separate ad-hoc backup of e.g. `/lxc/guest1/rootfs/home`, but for the purposes of scheduled backups, this fs shouldn't be backed up separately, only as part of its hierarchy.
 * Ideally, it should be possible to skip backups of individual sub-filesystems if they didn't change since the last backup.
   * Even more ideally, a new server-side snapshot should still be created of them even in this case.

Without sub-sources you could go about it this way:

 * Have a single `sources.d` directory on the client for the entire subtree.
   * Create the `recursive-snapshot` flag file and use `create-and-mount-snapshot` as a pre-client script to create a recursive snapshot before the backup.
   * Don't set up separate write-only rsync modules for the lower elements of the hierarchy on the server; use `no-xdev` on the client to traverse the entire subtree.
 * Create separate filesystems on the backup server and arrange them in the same hierarchy they're in on the client (TODO: write a helper script for this.)
 * Make sure the backupserver creates a recursive snapshot when the backup of the topmost directory is finished (add `-r` to the `make-snapshot` command line in `post-xfer exec`).
   * Make sure the topmost directory is backed up last (there is currently no mechanism for this, but one could be invented).
 * Symlink the `check-if-changed-since-snapshot` pre-client script into all your pertinent `sources.d` directories.
 * Set up a separate sources.d-style directory and an accompanying server-side rsync module for `/lxc/guest1/rootfs/home` (and any other filesystems you want to be able to back up separately); in the client-side directory, put a `check` script that returns 1 if it's not run interactively (or if a specific environment variable is not set, or something), so that this backup job is not triggered during the scheduled runs but can be triggered manually.

*With* sub-sources, it's not much simpler, but perhaps more intuitive:

 * Have a single `sources.d` directory on the client for the entire subtree.
   * Create the `recursive-snapshot` flag file and use `create-and-mount-snapshot` as a pre-client script to create a recursive snapshot before the backup.
   * *Do* set up separate write-only rsync modules for the lower elements of the hierarchy on the server; *don't* use `no-xdev` on the client (so that it backs up each fs separately).
   * Create a sub-source for each member fs in a hierarchy that matches the real fs hierarchy. (TODO: write a helper script for this.)
   * Symlink the `check-if-changed-since-snapshot` pre-client script into all your pertinent `sources.d` directories, including the sub-sources.
   * TODO: implement a mechanism to force sub-sources to back up a specific snapshot (one just created recursively from the topmost dataset).
 * Create separate filesystems on the server and arrange them in the same hierarchy they're in on the client (TODO: write a helper script for this).
 * Make sure the backupserver creates a recursive snapshot when the backup is finished (add `-r` to the `make-snapshot` command line in `post-xfer exec`).
 * Set up a separate sources.d-style directory and an accompanying server-side rsync module for `/lxc/guest1/rootfs/home` (and any other filesystems you want to be able to back up separately); in the client-side directory, put a check script that returns 1 if it's not run interactively (or if a specific environment variable is not set, or something), so that this backup job is not triggered during the scheduled runs but can be triggered manually.

On the server, we want to expose the snapshotted hierarchies as a single
hierarchy over rsync. This can be done as follows:

 * Have an empty directory be the root of the restore module.
 * Use the `zfsbackup-restore-preexec` `pre-xfer exec` script that dynamically populates an otherwise empty directory with bind mounts of existing recursive snapshots (mounting whichever the client requested; presenting a root directory with all snapshots that exist shown as subdirectories).
 * In fact, this script takes arbitrary dates, and finds the latest snapshot that predates or postdates them, then mounts it in a dynamically created directory. E.g. `rsync://server/module/after-last\ tuesday` works.
 * Optionally, amend the `remove-snapshot-if-allowed` script so it knows about recursive snapshots and removes all member snapshots at the same time (TODO).
 * Use the `zfsbackup-restore-postexec` `post-xfer exec` script that removes these bind mounts once they're no longer in use. Unfortunately, this can't be made safe for concurrent transfers; you have to set `max connections = 1` in the rsync module config.
   * You'd think that it would be possible to create a separate directory for each client based on `RSYNC_PID`, which `rsyncd` passes to the scripts it calls, but alas, no: the directory `rsyncd` presents to the client is always the one specified in the module definition.

### Client side zfs properties

The supplied `mksource.d/zfs-set-korn-zfsbackup-config` scriptlet sets the
following property on client filesystems, if they're zfs:

```
korn.zfsbackup:config[:$BACKUPSERVER]
```

This can be either /path/to/source.d/dir or "none". In the former case, this
points to the zfsbackup source.d style directory that causes this fs to be
backed up (to $BACKUPSERVER if there are several servers).

"none" means that this fs is not backed up. I set this property explicitly
on all filesystems that don't need to be backed up; so whenever it is
inherited I can see that something that maybe should get backed up is not. A
list of suspicious filesystems that might need backups but don't have any
can be obtained with

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

### Scheduling backups

There are two supported ways of scheduling backups: via `cron(8)` and via
`runit(8)`.

Running as a `runit` service is my preferred solution, but using `cron`
should work fine too.

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
 * `LOADWATCH_HIGH` (default 100), `LOADWATCH_LOW` (default 10) -- if `loadwatch` is installed, the `zfsbackup-sv` script runs `zfsbackup-client` via `loadwatch`, with these arguments. On some systems, the large `stat()` churn of `rsync` can cause huge load spikes (which may or may not be related to suboptimal inode cache behaviour); `loadwatch` won't make the problem go away, but at least it ameliorates it somewhat.
 * `CHRT` (defaults to `(chrt -i 0)`) -- an array that is used as a pre-command modified for `zfsbackup-client`. The default causes the client to run with reduced scheduling priority. Set it to the empty string to disable. You could also change it to `(chrt -i 0 nice -n 19)` to reduce the priority even further.

The variables can be set in `/etc/zfsbackup/client.conf` or in
`/etc/default/name-of-runit-service` (e.g. `/etc/default/zfsbackup-server1`).
Using several differently named instances of the runit service you can easily
run backups to different servers in parallel; this is the intended usage.

The script doesn't support more than one sources.d hierarchy. The recommended
multi-server setup is to run one instance of `zfsbackup-sv` for each
backupserver.

#### Running `zfsbackup-client` as a cron job

When using cron, you can just invoke `zfsbackup-client` as a cronjob; it
will iterate over all sources.d directories (and all backupservers named in
`client.conf`), and try to back up each directory exactly once. It uses
locking to ensure that the same sources.d directory is not being processed
by two or more concurrent instances simultaneously.

You could also have several cronjobs that each invoke `zfsbackup-client`
with some arguments to only process backups to a specific server, or of a
specific fs. If bandwidth is not a concern, starting backups of the same fs
to different servers simultaneously can be a good idea: it reduces read I/O
on the client due to caching.

The other cron-based option is to invoke the `zfsbackup-sv` script as a
cronjob. While this should work, it is untested.

#### Running `zfsbackup-client` as a runit service (preferred)

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

### Server side

On the server side, for a minimal setup, you only need to run `rsyncd`. An
example configuration is included.

If you want snapshots and auto-expiry, you'll want to include something like

```
post-xfer exec = /path/to/zfsbackup/make-snapshot
```

in `rsyncd.conf`. The `make-snapshot` script runs
`/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME` if that exists, allowing its
behaviour to be extended. This `/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME`
per-module script will be passed the word "expires" as the first and only
argument. It is expected to output a date in unix epoch seconds (`date +%s`).

The snapshot of the just-finished backup will be kept until this time and
an `at(1)` job scheduled to remove it if `at(1)` is available. The snapshot
will have its `korn.zfsbackup:expires` property set to the expiry date. If no
`/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME` script is provided, internal
defaults are used (heuristics based on day of week, day of month, day of
year). These can be overridden in `/etc/zfsbackup/server.conf` (see the
`make-snapshot` script to get an idea how). Expiry can be set to "never" to
never expire a snapshot.

Because the `at` job may not be run (for example, if the server is off), the
cronjob `zfsbackup-expire-snapshots` is provided. It looks for zfs snapshots
that have the `korn.zfsbackup:expires` property and removes any that are
expired. Future versions may support scoping (only expire snapshots under a
specific zpool or subtree).

No expiry takes place if a snapshot of the only or of the latest successful
backup would be removed.

The `/etc/zfsbackup/server.conf` and the `/etc/zfsbackup/client.conf` file can
be used to override the `korn.zfsbackup` property prefix to something else,
by setting `PROPPREFIX=something.else`; this allows derivative scripts to
easily have their own property namespace.

#### Origin properties

The server-side origin dataset can have a number of properties in the
`korn.zfsbackup` namespace (but see `PROPPREFIX` above) that influence the
snapshot process (these intentionally mimic dirvish options):

 * `korn.zfsbackup:minsize`: If the dataset's reported size (in bytes) is smaller than this, the backup is considered partial and korn.zfsbackup:partial is set to true on the snapshot. The default is 262144 (256k); set to 0 to disable. Future versions may support human-readable sizes.
 * `korn.zfsbackup:mininodes`: If the number of inodes used by the dataset (as reported by df -i) is smaller than this, the backup is considered partial; see above. The default is 7 (6 inodes are in use in an empty zfs dataset). Set to 0 to disable.

Note that these heuristics only work for initial backups; if a
subsequent backup somehow fails midway but rsyncd reports success,
there is no way to detect a partial transfer on the server side.

Future versions may support checking how big the difference between
the current upload and the last snapshot is; that may be a more
useful heuristic.

 * `korn.zfsbackup:expire-default`: If set, has to be a string `date(1)` understands (such as "`now + 1 year`"). The expiry date of the snapshot will be set by this property instead of the internal heuristics. The `/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME` overrides this value.
 * `korn.zfsbackup:expire-rule`: Can currently be the absolute path to a script that will output the date of expiry (instead of /etc/zfsbackup/server.d/$RSYNC_MODULE_NAME). Future versions may support dirvish-like expire rules.
 * `korn.zfsbackup:image-default`: A string parseable by `strftime(3)` that will be used to set the name of the snapshot. Defaults to `zfsbackup-NAMEPREFIX-%Y-%m-%d-%H%M`, where `NAMEPREFIX` is `yearly`, `monthly`, `weekly-isoweekyear-week`, `daily` or `extra` and is set either by the overridable `expire_rule()` shell function or by running `/etc/zfsbackup/server.d/$RSYNC_MODULE_NAME nameprefix` if the script exists. The string `NAMEPREFIX` will be replaced by the current value of $nameprefix (as determined by `expire_rule()`). This way you could implement your own support for e.g. "hourly" or "biannual" backups without modifying the scripts.
 * `korn.zfsbackup:min-successful`: *NOT IMPLEMENTED YET* The minimum number of successful backups that must exist for one to be expired. Will default to 2 (leaving 1 after the expiry).

#### Snapshot properties

The following properties are set on snapshots:

 * `korn.zfsbackup:partial`: Set to true if the backup doesn't appear to contain enough files, or be big enough, to be complete. See origin properties.
 * `korn.zfsbackup:successful`: Set to true if `partial` is not true *AND* `$RSYNC_EXIT_STATUS` is 0. Set to false otherwise.
 * `korn.zfsbackup:rsync_exit_status`: Set to `$RSYNC_EXIT_STATUS` (passed from `rsyncd`).
 * `korn.zfsbackup:rsync_host_addr`: Set to `$RSYNC_HOST_ADDR` (passed from `rsyncd`).
 * `korn.zfsbackup:rsync_host_name`: Set to `$RSYNC_HOST_NAME` (passed from `rsyncd`).
 * `korn.zfsbackup:rsync_user_name`: Set to `$RSYNC_USER_NAME` (passed from `rsyncd`).
 * `korn.zfsbackup:expires`: Set to the expiry date (in epoch seconds).
 * `korn.zfsbackup:expires-readable`: Set to the expiry date in human readable form. The format is currently hardcoded: `%Y%m%d %H:%M:%S`. This is only provided for convenience; the scripts don't use it.

## Limitations

### Backup inventory (TODO)

It is desirable for the client to keep logs of which source was backed up
when to where, and whether the backup completed successfully.

If the origin fs is zfs, it might be tempting to keep some of this data in
zfs properties; however, this is impractical because properties are
inherited by sub-filesystems. While this would be possible to workaround
(for example by including the name of the fs in the name of the property or
only considering the property to be valid if it's not inherited), it would
still be ugly.

In addition to the syslog-style messages the client produces to this effect,
you can create `log-file`s in the `sorces.d` directories to have rsync write
a log of what files it uploads. The names of unchanged files are not logged.
This logfile grows indefinitely unless you prune it somehow. (TODO: write a
script that prunes the log so that only the last `n` occurrences of each
file are kept, defaulting to 1. It shouldn't be hard: reverse the file using
`tac`, pipe through script that builds hash with filenames as keys, counters
as values etc.)

The default `log-file-format` allows you to keep track of which file was
uploaded when, and what its properties were at the time. It could be used in
automated backup audits: check that all files that are supposed to be backed
up have in fact been uploaded recently enough.

This is almost, but not quite, a backup inventory; the problem is that it
doesn't scale well to filesystems with millions of files and frequent
updates. The backup inventory I have in mind would have one record per fs,
not one per file, and have the following characteristics:

 * It has to reference the specific filesystem backed up, not just the name of the sources.d directory.
   * Preferably by UUID as well as path.
   * If a snapshot was used, the UUID of the origin fs should be listed; the UUID of the snapshot (if it even has one) is less interesting as it's ephemeral.
   * The `zfsbackup-client` script itself doesn't and shouldn't care whether it's backing up a snapshot or not; this should be handled by pre/post-client scripts.
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

### Out of band metadata

The rsync protocol doesn't permit passing out-of-band metadata from the
client to the server. Thus, the server can't determine whether the client
thinks the transfer was successful, and other client-specific details such
as labels can't be passed to the server either, even though it would be
useful to store them in properties.

A possible mechanism to do it anyway would be to upload a .zfsbackup or
similar directory that contains the metadata. I may implement this later
as follows:

 * The main `rsync` modules used for file transfer don't trigger server-side snapshots.
 * Instead, every backup module has a metadata module associated with it. Once the data backup completes, the client syncs to the corresponding metadata module as well, and *this* triggers the server-side snapshot.
   * Alternatively, no separate rsync modules for metadata might be needed; instead, the client would first transfer the real data, then the metadata in a separate transfer. The server would parse the metadata, delete it from the backup fs, then create the snapshot. Advantage: no rsync module pollution. Disadvantage: messes with the backup data, even if only temporarily.
   * Messing with the backup data would be "safe" by default in the sense that the metadata would never make it into a snapshot: if it's uploaded but a snapshot is not taken, the next transfer would delete it by default (since `rsync` would be run with `--delete`). However, unusual configurations could make it unsafe; thus it's not a good idea after all.

Another possibility would be to introduce `pre-server.d` and `post-server.d`
on the client, which could then run commands via `ssh` on the server. The
obvious disadvantage is that the client then needs a shell account on the
server; however, that could also be used to transfer backups (with
`fake super`) over ssh.

Additionally, a regular `post-client` script could also use ssh, or any
other non-rsync mechanism to transmit data to the server, e.g. http;
or commit something to a revision control system; or whatever. Heck, we
could even leverage `finger`. :)

An issue with `post-server.d` is that some scripts might need to run before
`post-client`, others after it; ending up with `post-post-client-server.d`
and `pre-post-client-server.d` would be bad. There really isn't much benefit
to introducing explicit `post-server.d` directories; the scripts could just
as well go in `post-client.d`.

### post-xfer exec and restores

`rsyncd` doesn't care whether the client uploads or downloads data (or both);
the post-xfer script is run regardless. This means that even if you download
(i.e. "restore") data from backup, a snapshot will be created. To avoid
this, have two rsync modules for all backup directories: one for uploads and
one of downloads. The one for downloads shouldn't have the post-xfer exec
directive.

This also allows you to use segregated rsync users: one for uploading, one for
downloading. Only the upload user has access to the backup module, which is
writable but not readable; and only the restore/download user has access to
the restore module, which is read-only.

### Encryption

Can't be reasonably supported at this layer; if you need encrypted backups,
use something like Borg or Attic.

A VPN (like OpenVPN or wireguard or IPSec) can protect the rsync traffic in
transit.

### GNUisms, zsh

The scripts were written to be run on Linux, with zsh, and assume you're
running a fairly recent (as of mid-2019) version of zfsonlinux. I have no
interest in making them more portable; if someone else wants to, go ahead.
I'll accept pull requests that don't make it much harder to maintain the
code.

### root privileges

Currently the client-side scripts assume they're being run as root.
This is relevant in the case of the `mksource.d` scripts (which assume they
can ssh to the backupserver as root, and that they can set zfs properties
locally on the client). Most of the supplied pre/post-client scripts will
attempt privileged operations like mounting filesystems, creating and/or
deleting snapshots and so on.

Other than that, the `zfsbackup-client` itself should run just fine as a
non-root user (e.g. to back up your homedir to a remote zfsbackup server
provided to you by an administrator).

The `rsyncd` process on the server must run as root in order to be able to
create zfs snapshots (unless you use some funky delegation or sudo to work
around this). The transfers themselves don't need to use root; just be sure to
enable `fake super` and xattr support on the destination fs if you use a
non-root user to store files as. Performance will degrade somewhat and space
usage will increase due to the need to store a lot of metadata in xattrs.

## License

Currently, zfsbackup is licensed under the GPL, version 3.

I'm open to dual licensing it under the GPLv3 and other open source licenses
if there is a compelling reason to do so. Obviously this is only practical
as long as there are few contributors.

## Copyright

`zfsbackup` was originally written by András Korn
<korn-zfsbackup @AT@ elan.rulez.org> in 2012. Development continued
in small bursts through 2020 and possibly beyond (see git changelog).
