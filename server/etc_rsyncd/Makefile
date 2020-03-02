SHELL = /bin/zsh
rsyncd.conf : warningheader $(shell find conf.d -type f)
	( \
		if ! grep -q '^&include.*conf.d' rsyncd.conf; then \
			cat warningheader >rsyncd.conf; \
			cat conf.d/*(.) >>rsyncd.conf; \
			find conf.d/*(/) -type f -exec cat {} + >>rsyncd.conf; \
		else \
			true; \
		fi; \
	)
