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
REMOTEBACKUPPATH=$(hostname) # Path to backups of this host, relative to backup pool root; will be used to generate commands to create necessary zfs instances
CLIENTNAME=$(hostname -f) # Will be placed in rsyncd.conf "hosts allow =" line; can be IP or hostname, or even both (separated by spaces)
SCRIPTS=/usr/local/share/zfsbackup # This is the default that will be used if you don't set this variable
FAKESUPER=true # or false if you want to run the remote rsyncd as root and save time on xattr operations
```

If you have more than one backup server, use something like:

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
BINDROOT=/mnt${BACKUPSERVER:+/$BACKUPSERVER}
# An array of zfs properties you want set on newly created zfs instances,
# if any (note that currently there is no way to override these from the
# command line; maybe instead of setting them here, you should let them
# be inherited from the parent fs on the server):
#DEFAULT_ZFS_PROPERTIES=(-o exec=off -o suid=off -o devices=off)
# You might want to use something like:
#. /etc/zfsbackup/client.conf${BACKUPSERVER:+.$BACKUPSERVER}
# to override some of the above on a per-server basis.
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
