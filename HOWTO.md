# Server side

Copy Makefile and warningheader from server/etc_rsyncd to /etc/rsyncd;
create secrets file (username:password, one per line); create
`/etc/rsyncd.conf` -> `rsyncd/rsyncd.conf` symlink; create `/etc/rsyncd/conf.d`
directory hierarchy (refer to example provided).

Set `/etc/rsyncd` to be owned by `root:root` and mode 0700.
Set `/etc/rsyncd/secrets` to be mode 0600.

Set up ssh so that you can log on as root using public key auth (of course,
only use an encrypted private key).

# Client side

Make sure scripts are installed under /usr/local/share/zfsbackup.

```
mkdir -p /etc/zfsbackup
cd /etc/zfsbackup
ln -s /path/to/zfsbackup/client/mksource.d .
mkdir sources.d
```

In client.conf, if you have only one backup server, specify:

```zsh
REMOTEBACKUPPREFIX=$(hostname) # Path to backups of this host, relative to backup pool root; will be used to generate commands to create necessary zfs instances
CLIENTNAME=$(hostname -f) # Will be placed in rsyncd.conf "hosts allow =" line; can be IP or hostname, or even both (separated by spaces)
SCRIPTS=/usr/local/share/zfsbackup # This is the default that will be used if you don't set this variable
FAKESUPER=true # or false if you want to run the remote rsyncd as root and save time on xattr operations

# These settings are used by the zfsbackup-sv runit service:
SLEEP_IF_NOT_UP_FOR_MORE_THAN=3600	# don't start backups immediately if last boot was less than this many seconds ago; sleep for ONBOOT_SLEEP seconds
ONBOOT_SLEEP=12h			# sleep for this time after reboot before starting first backup
EXIT_ACTION=sleep-and-exit		# can also be stop-service or just exit; see README.md
VERBOSE=1				# setting to 0 suppresses informational messages to stderr
# If the exit delay would result in more than $MAX_RUNTIME
# seconds passing between successive zfsbackup-client invocations, the
# delay is adjusted so that zfsbackup-client can be rerun at most
# $MAX_RUNTIME seconds after the previous run. This places a limit on
# the time spent retrying unsuccessful backups.
MAX_RUNTIME=86400
EXIT_SLEEP_UNTIL=1:00			# on success, wait until 1:00am

USE_SYSLOG=0
```

If you have more than one backup server, use something like:

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
#
# If you want paths of local backups to have a prefix under the root of the
# REMOTEBACKUPPOOL, set it here:
#REMOTEBACKUPPREFIX=
# E.g. if REMOTEBAKCUPPREFIX is "MyOrg/$(hostname)" and a local zfs instance
# is rpool/data, then the backups would by default go into something
# like backup/MyOrg/$(hostname)/rpool_data or
# backup/MyOrg/$(hostname)/rpool/data, depending on how you invoke
# zfsbackup-create-source. Since the name of the pool may already include the
# hostname, it's not added automatically.
#
# Whether to attempt to create remote zfs instance via ssh to hostname portion of url.
# If you have more than one server, you probably don't want to do this manually every
# time. It's best if you can log on to the backup server as root using pubkey auth.
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
# command line; maybe instead of setting them here, you should let them
# be inherited from the parent fs on the server):
#DEFAULT_ZFS_PROPERTIES=(-o exec=off -o suid=off -o devices=off)
# You might want to use something like:
#. /etc/zfsbackup/client.conf${BACKUPSERVER:+.$BACKUPSERVER}
# to override some of the above on a per-server basis.

CLIENTNAME=$(hostname -f) # Will be placed in rsyncd.conf "hosts allow =" line; can be IP or hostname, or even both (separated by spaces)

# These settings are used by the zfsbackup-sv runit service:
SLEEP_IF_NOT_UP_FOR_MORE_THAN=3600	# don't start backups immediately if last boot was less than this many seconds ago; sleep for ONBOOT_SLEEP seconds
ONBOOT_SLEEP=12h			# sleep for this time after reboot before starting first backup
EXIT_ACTION=sleep-and-exit		# can also be stop-service or just exit; see README.md
VERBOSE=1				# setting to 0 suppresses informational messages to stderr
# If the exit delay would result in more than $MAX_RUNTIME
# seconds passing between successive zfsbackup-client invocations, the
# delay is adjusted so that zfsbackup-client can be rerun at most
# $MAX_RUNTIME seconds after the previous run. This places a limit on
# the time spent retrying unsuccessful backups.
MAX_RUNTIME=86400
EXIT_SLEEP_UNTIL=1:00			# on success, wait until 1:00am

USE_SYSLOG=0
```

If you have only one server:

```
mkdir client-defaults
cd client-defaults
touch no-acls # Speeds things up if you don't have ACLs; can be disabled on a per-source basis later
# ln no-acls no-xattrs # Ditto if you don't use xattrs; but don't assume you don't, because e.g. file capabilities are stored in xattrs
touch password
chmod 400 password
echo "sKrit!" >password # Password the client will use to authenticate itself to server when sending backups
echo "rsync://backup.hostname.or.ip/__PATH__" >url-template # __PATH__ will be automatically substituted
echo "client-writer-username" >username # Username to use when sending backups (should be different from username used to restore them; $(hostname)-writer is not a bad choice)
```

If you have more than one server, create `client-defaults`, with one subdir per backup server, then proceed as above in each subdir.
You can name the subdirectories whatever you want; their names will be the "tags" of your backup servers, which you can specify as arguments to `--server` when invoking `zfsbackup-create-source`.
These names will also appear in korn.zfsbackup:config:servername client-side properties.

## Creating sources.d directories

### Rootfs

now let's set up backups of the root filesystem:

```
zfsbackup-create-source -p / -b -A -X -o dedup=on -o korn.zfsbackup:minsize=$[300*1024*1024] -o korn.zfsbackup:mininodes=30000

# explanation:
# -p /	Path to directory tree to back up
# -b	bind mount the fs somewhere else and back up the bind mounted mountpoint, so that files and directories hidden by stuff mounted over them can be backed up too
# -A	enable transfer of ACLs for this fs; maybe you don't need this
# -X	enable transfer of xattrs; you probably want this for the rootfs due to selinux labels, file-based capabilities and such
# -o dedup=on	enable dedup on the zfs instance to be created for this backup (makes sense if you back up many similar root filesystems)
# -o korn.zfsbackup:minsize=$[300*1024*1024]	assume that the backup was unsuccessful if the target fs uses less than 300Mbytes (heuristics only)
# -o korn.zfsbackup:mininodes=100000	assume that the backup was unsuccessful if the target fs has less than 100k inodes (heuristics only)
```

The output will look like this:

```
run-parts: executing /etc/zfsbackup/mksource.d/create-remote-zfs
Run the following command on your backup server to create the zfs instance we'll back /etc/zfsbackup/sources.d/rootfs up to:
zfs create -o dedup=on -o korn.zfsbackup:minsize=314572800 -o korn.zfsbackup:mininodes=100000 backup/REMOTEBACKUPPATH/rootfs
chown nobody:nogroup '/backup/REMOTEBACKUPPATH/rootfs'

run-parts: executing /etc/zfsbackup/mksource.d/create-rsyncd-conf
Please append something like the following to the rsyncd.conf on backup.hostname:

[backup_REMOTEBACKUPPATH_rootfs]
path = /backup/REMOTEBACKUPPATH/rootfs
hosts allow = CLIENTNAME
read only = false
write only = true
post-xfer exec = /var/lib/svn-checkout/misc-scripts/zfsbackup/server/make-snapshot
auth users = client-writer-username

[restore_REMOTEBACKUPPATH_rootfs]
path = /backup/REMOTEBACKUPPATH/rootfs
hosts allow = CLIENTNAME
read only = true
write only = false
auth users = client-writer-username

run-parts: executing /etc/zfsbackup/mksource.d/zfs-set-korn-zfsbackup-config
```

You can now copy and paste these to the appropriate locations on the backup server. The lines to copy and paste are helpfully highlighted in yellow.

Then, try whether it works: just start `zfsbackup-client`. When it's done,
look at what it copied to the server; and check whether snapshots of the
target fs exist, and their properties.

If you have more than one server, just include `--server server1,server2` on
the `zfsbackup-create-source` command line (or if you want to back everything
up to all servers, enumerate the servers in client.conf and all scripts will
default to using all servers).

If copying and pasting configuration and commands is too much of a bother (it
will be, after the first dozen), set

```zfs
CREATEREMOTEZFS=true
REMOTE_APPEND_RSYNCD_CONF=true
```

in `client.conf` and it will be done for you automatically.

## /boot

```
zfsbackup-create-source -p /boot --no-xattrs --no-acls -o korn.zfsbackup:minsize=$[10*1024*1024] -o korn.zfsbackup:mininodes=10
```

## /var

Similarly,

```
zfsbackup-create-source -p /var -b -o korn.zfsbackup:minsize=$[30*1024*1024] -o korn.zfsbackup:mininodes=5000
```

Or, if your `/var` is on zfs

```
zfsbackup-create-source -z -p rpool/var -o korn.zfsbackup:minsize=$[30*1024*1024] -o korn.zfsbackup:mininodes=5000
```

You may want to exclude some stuff from being backed up, like this:

```
cat >/etc/zfsbackup/sources.d/var/exclude <<EOF
/cache/apt/archives/*.deb
/cache/apt/archives/partial/*
/cache/apt/*.bin
/cache/man/**
/lib/apt/lists/**
/backups/*.[1-9]*
/tmp/**
*.bak
/spool/qmail/*/*/[0-9]*
/log/*.[0-9]*
/log/**/*.[0-9]*
*~
core
EOF
```

## /var/log/sv

(This is where I put runit/svlogd logs)

```
zfsbackup-create-source -p /var/log/sv -o korn.zfsbackup:mininodes=15
cat >/etc/zfsbackup/sources.d/var_log_sv/exclude <<EOF
@*.[sut]
current
previous
state
lines
rotations
lock
*.bak
*~
core
EOF
```

## Other filesystems

Obtain a list of (zfs) filesystems that don't have backups configured:

```
zfs get -o name,property all -t filesystem,volume -s inherited | fgrep korn.zfsbackup:config | sed 's/[[:space:]]*korn.zfsbackup:config.*//'
```

## Backing up servers that run LXC containers

I set up LXC containers in a very specific way and will write a script to set up backups for all of them.

Assumptions:

 * All the lxc stuff lives under a somepool/path zfs dataset.
 * All lxc guests have filesystems like `somepool/path/guest`, `somepool/path/guest/rootfs`, `somepool/path/guest/rootfs/{tmp,var}`, `somepool/path/guest/rootfs/{srv,srv/somedata}`.
 * You want to back up an LXC guest in a single go, using a recursive ZFS snapshot to obtain a consistent state.
 * You want similar sub-filesystems to be created on the backup server (separate `rootfs`, `rootfs/var` mounted under it, and os on).
  * This makes restoring from the latest backup very straightforward but still allows e.g. different dedup settings for `rootfs` and `rootfs/var`.
  * Note that restoring from earlier backup snapshots will only be possible either on a per-filesystem basis, or by using bind mounts to create the appropriate hierarchy of mountpoints, constructed from the snapshots, on the backup server (as facilitated by the `zfsbackup-restore-preexec` script).

## Setting up a backup with sub-sources

Example 1: a laptop called luna

Assume we have the following filesystems on the client:

```
NAME                    CANMOUNT  MOUNTPOINT
bpool                   off       /
bpool/BOOT              off       none
bpool/BOOT/debian-1     noauto    legacy
luna                    off       /
luna/ROOT               off       /ROOT
luna/ROOT/debian-1      noauto    /
luna/ROOT/debian-1/var  on        /var
luna/fscache            -         -
luna/home               on        /home
luna/swap1              -         -
luna/tmp                on        /tmp
luna/var                off       /var
luna/var/cache          on        /var/cache
luna/var/log            on        /var/log
luna/var/log/sv         on        /var/log/sv
luna/var/spool          on        /var/spool
luna/var/tmp            on        /var/tmp
```

The bpool is straightforward; it only contains a single mounted filesystem, which is small and changes rarely. It doesn't need special attention.

 1. Create the requisite filesystems for the `luna` pool on the server:

```
zfs create -o dedup=on	backup/luna 		# This will be where we back up luna/ROOT/debian-1 to
zfs create -o dedup=off backup/luna/home	# dedup=off because otherwise it would inherit the dedup property
zfs create -o dedup=off backup/luna/var		# This is for luna/ROOT/debian-1/var; luna/var is not mountable
zfs create		backup/luna/var/cache
zfs create		backup/luna/var/log
zfs create		backup/luna/var/log/sv
zfs create		backup/luna/var/spool
```

### Using zfsbackup-create-source

(The script would also create the remote filesystems, but it wouldn't be able
to set `dedup=on` on some while also setting `dedup=off` on others. One way
to do this would be to introduce additional `korn.zfsbackup` properties that
contain hints for the properties to set on remote zfs instances used to store
backups. TODO.)

 2. Run `zfsbackup-create-source -p luna/ROOT/debian-1 --zroot luna --subsources -z -d /etc/zfsbackup/sources.d/BACKUPSERVER/luna`
   * Add individual, site-specific configuration like `exclude` files.

That's it. NOTE: this hasn't been heavily tested yet; there may still be bugs. Review the generated configuration manually.

### Manually

Before scripted support for this was introduced, the only way to set it up was manually, as follows:

 2. Create and populate the top-level sources.d directory on the client:

   * `mkdir -p /etc/zfsbackup/sources.d/BACKUPSERVER/luna`
   * Create `username`, `password`, `url`, `recursive-snapshot`; other configfiles (e.g. `exclude`) as needed.
   * Create zfs-dataset-root: `echo luna >/etc/zfsbackup/BACKUPSERVER/sources.d/luna/zfs-dataset-root`
   * Don't create `no-xdev`.
   * Create `path`: mkdir /etc/zfsbackup/sources.d/BACKUPSERVER/luna/path
   * `echo luna > /etc/zfsbackup/sources.d/BACKUPSERVER/luna/zfs-dataset`
   * `mkdir -p /etc/zfsbackup/sources.d/BACKUPSERVER/luna/subsources.d`
   * `zfsbackup-create-source -p luna/ROOT/debian-1/var -z -d luna/subsources.d/var` etc.
   * Make sure `set-path-to-latest-zfs-snapshot` is not enabled for any sub-source; check-if-changed-since-snapshot should be, though.
   * Make sure that on the server side, the rsync stanza for the rootfs will invoke `make-snapshot` with `-r`.
    * You probably also want to make sure that the other stanzas don't invoke it at all; otherwise, all backups of the hirearchy will create multiple snapshots of destination filesystems of sub-sources.
    * TODO: make sure somehow that even with client-side parallelism, no backups started later than the one that created the initial recursive snapshot can mess up the server-side data, so that the recursive snapshot we create on the server side after the backup is really consistent.
    * TODO: provide a mechanism for make-snapshot to be invoked if a subsource is backed up separately.

TODO: test if these instructions still work correctly.

## Scheduling backups

### Using `zfsbackup-sv` as a runit service

We'll assume you have two backupservers, named `server1` and `server2`.

```zsh
mkdir -p /etc/sv/zfsbackup-{server1,server2}/log
# put some svlogd based logging script in /etc/sv/zfsbackup-{server1,server2}/log/run and make it executable
for sv in /etc/sv/zfsbackup-{server1,server2}; do
	ln -s /path/to/zfsbackup-sv $sv/run
done
```

Now let's configure these services before we enable them:

```zsh
cat <<EOF >>/etc/zfsbackup/client.conf
SLEEP_IF_NOT_UP_FOR_MORE_THAN=3600	# seconds
ONBOOT_SLEEP=12h			# sleep for this time after reboot before starting first backup
EXIT_ACTION=sleep-and-exit		# can also be stop-service or just exit; see README.md
VERBOSE=1				# setting to 0 suppresses informational messages to stderr
MAX_RUNTIME=86400			# maximum number of seconds since zfsbackup-client run;
# if we exceed this, the script aborts
EOF
```

```zsh
cat <<EOF >/etc/default/zfsbackup-server1
# Either:
# SOURCES=/etc/zfsbackup/sources.d/server1
# or:
BACKUPSERVER=server1
EXIT_SLEEP_UNTIL=22:00			# if set, sleep until this time before exiting; this
					# is when the next backup run (to this server) will start
ZFSBACKUP_CLIENT_ARGS=(--server $BACKUPSERVER)
EOF

cat <<EOF >/etc/default/zfsbackup-server2
# Either:
# SOURCES=/etc/zfsbackup/sources.d/server2
# or:
BACKUPSERVER=server2
EXIT_SLEEP_UNTIL=01:00			# if set, sleep until this time before exiting; this
					# is when the next backup run (to this server) will start
ZFSBACKUP_CLIENT_ARGS=(--server $BACKUPSERVER)
EOF
```

Now let's enable the services:

```zsh
ln -s /etc/sv/zfsbackup-{server1,server2} /service/
```
