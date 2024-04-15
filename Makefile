prefix = /usr/local

all:
	

install:
	mkdir -p $(DESTDIR)$(prefix)/share/zfsbackup/client
	mkdir -p $(DESTDIR)$(prefix)/share/zfsbackup/client/mksource.d
	mkdir -p $(DESTDIR)$(prefix)/share/zfsbackup/server
	mkdir -p $(DESTDIR)$(prefix)/share/zfsbackup/server/etc_rsyncd
	mkdir -p $(DESTDIR)$(prefix)/share/zfsbackup/server/etc_rsyncd/conf.d
	mkdir -p $(DESTDIR)$(prefix)/sbin

	install functions.zsh $(DESTDIR)$(prefix)/share/zfsbackup/

	install client/zfsbackup-create-source $(DESTDIR)$(prefix)/sbin/
	install client/zfsbackup-client $(DESTDIR)$(prefix)/sbin
	install client/zfsbackup-alert $(DESTDIR)$(prefix)/sbin

	install client/check-if-changed-since-snapshot $(DESTDIR)$(prefix)/share/zfsbackup/client/
	install client/create-and-mount-snapshot $(DESTDIR)$(prefix)/share/zfsbackup/client/
	install client/pre-bindmount $(DESTDIR)$(prefix)/share/zfsbackup/client/
	install client/post-bindmount $(DESTDIR)$(prefix)/share/zfsbackup/client/
	install client/set-path-to-latest-zfs-snapshot $(DESTDIR)$(prefix)/share/zfsbackup/client/
	install client/umount-and-destroy-snapshot $(DESTDIR)$(prefix)/share/zfsbackup/client/
	install client/zfsbackup-sv $(DESTDIR)$(prefix)/share/zfsbackup/client/

	install client/mksource.d/create-remote-zfs.plugin $(DESTDIR)$(prefix)/share/zfsbackup/client/mksource.d/
	install client/mksource.d/create-rsyncd-conf.plugin $(DESTDIR)$(prefix)/share/zfsbackup/client/mksource.d/
	install client/mksource.d/zfs-set-source-props.plugin $(DESTDIR)$(prefix)/share/zfsbackup/client/mksource.d/

	install server/make-snapshot $(DESTDIR)$(prefix)/share/zfsbackup/server/
	install server/pre-xfer-log $(DESTDIR)$(prefix)/share/zfsbackup/server/
	install server/remove-snapshot-if-allowed $(DESTDIR)$(prefix)/share/zfsbackup/server/
	install server/rsyncd.conf.example $(DESTDIR)$(prefix)/share/zfsbackup/server/
	install server/zfsbackup-expire-snapshots $(DESTDIR)$(prefix)/share/zfsbackup/server/
	install server/zfsbackup-restore-postexec $(DESTDIR)$(prefix)/share/zfsbackup/server/
	install server/zfsbackup-restore-preexec $(DESTDIR)$(prefix)/share/zfsbackup/server/

	install server/etc_rsyncd/Makefile $(DESTDIR)$(prefix)/share/zfsbackup/server/etc_rsyncd/
	install server/etc_rsyncd/README $(DESTDIR)$(prefix)/share/zfsbackup/server/etc_rsyncd/
	install server/etc_rsyncd/rsyncd.conf $(DESTDIR)$(prefix)/share/zfsbackup/server/etc_rsyncd/
	install server/etc_rsyncd/secrets $(DESTDIR)$(prefix)/share/zfsbackup/server/etc_rsyncd/
	install server/etc_rsyncd/warningheader $(DESTDIR)$(prefix)/share/zfsbackup/server/etc_rsyncd/

	install server/etc_rsyncd/conf.d/global $(DESTDIR)$(prefix)/share/zfsbackup/server/etc_rsyncd/conf.d/

clean:
	
