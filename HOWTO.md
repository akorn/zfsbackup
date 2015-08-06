# Client side

Make sure scritps are installed under /usr/local/share/zfsbackup

```
mkdir -p /etc/zfsbackup
cd /etc/zfsbackup
```

In client.conf, specify:

```
REMOTEBACKUPPATH=$(hostname) # Path to backups of this host, relative to backup pool root; will be used to generate commands to create necessary zfs instances
CLIENTNAME=$(hostname -f) # Will be placed in rsyncd.conf "hosts allow =" line; can be IP or hostname, or even both (separated by spaces)
SCRIPTS=/usr/local/share/zfsbackup # This is the default that will be used if you don't set this variable
FAKESUPER=true # or false if you want to run the remote rsyncd as root and save time on xattr operations
```

```
ln -s /path/to/zfsbackup/mksource.d .
mkdir sources.d
```

```
mkdir client-defaults
cd client-defaults
touch no-acls # Speeds things up if you don't have ACLs; can be disabled on a per-source basis later
ln no-acls no-xattrs # Ditto if you don't use xattrs
touch password
chmod 400 password
echo "sKrit!" >password # Password the client will use to authenticate itself to server when sending backups
echo "rsync://backup.hostname.or.ip/__PATH__" >url-template # __PATH__ will be automatically substituted
echo "client-writer-username" >username # Username to use when sending backups (should be different from username used to restore them; $(hostname)-writer is not a bad choice)
```

## Creating sources.d directories

### Rootfs

now let's set up backups of the root filesystem:

```
zfsbackup-create-source -p / -b -d rootfs -A

# explanation:
# -p /	Path to directory tree to back up
# -b	bind mount the fs somewhere else and back up the bind mounted mountpoint, so that files and directories hidden by stuff mounted over them can be backed up too
# -d	name of directory under sources.d to create
# -A	enable transfer of ACLs for this fs; maybe you don't need this
```

The output will look like this:

```
run-parts: executing /etc/zfsbackup/mksource.d/create-remote-zfs
Run the following command on your backup server to create the zfs instance we'll back /etc/zfsbackup/sources.d/rootfs up to:
zfs create backup/REMOTEBACKUPPATH/rootfs
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

[restore_thunderbolt_rootfs]
path = /backup/REMOTEBACKUPPATH/rootfs
hosts allow = CLIENTNAME
read only = true
write only = false
auth users = client-writer-username
```

You can now copy and paste these to the appropriate locations on the backup server. The lines to copy and paste are helpfully highlighted in yellow.

At this point you may want to adjust some properties on the server end, e.g.

```
zfs set dedup=on backup/REMOTEBACKUPPATH/rootfs
zfs set korn.zfsbackup:minsize=$[300*1024*1024] backup/REMOTEBACKUPPATH/rootfs
zfs set korn.zfsbackup:mininodes=100000 backup/REMOTEBACKUPPATH/rootfs
```

Then, try whether it works: just start zfsbackup-client. When it's done, look at what it copied to the server.

## /boot

```
zfsbackup-create-source -p /boot
```

## /var

Similarly,

```
zfsbackup-create-source -p /var -b

# You may want to exclude some stuff from being backed up, like this:
cat >/etc/zfsbackup/sources.d/var/exclude <<EOF
/cache/apt/archives/*.deb
/cache/apt/archives/partial/*
/cache/apt/*.bin
/cache/man/**
/lib/apt/lists/**
/backups/*.[0-9]*
/tmp/**
*.bak
/spool/qmail/*/*/[0-9]*
/log/*.[0-9]*
/log/**/*.[0-9]*
*~
core
EOF
```

At this point you may want to adjust some properties on the server end, e.g.

```
zfs set korn.zfsbackup:minsize=$[300*1024*1024] backup/REMOTEBACKUPPATH/var
zfs set korn.zfsbackup:mininodes=100000 backup/REMOTEBACKUPPATH/var
```

## /var/log/sv

(This is where I put runit/svlogd logs)

```
zfsbackup-create-source -p /var/log/sv
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

# Server side

Copy Makefile and warningheader from server/etc_rsyncd to /etc/rsyncd;
create secrets file (username:password, one per line); create
/etc/rsyncd.conf -> rsyncd/rsyncd.conf symlink; create /etc/rsyncd/conf.d
directory hierarchy (refer to example provided).
