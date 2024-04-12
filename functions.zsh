# common functions used by zfsbackup components; sourced by zsh scripts

export PROPPREFIX=${PROPPREFIX:-korn.zfsbackup}				# a hopefully sensible default that configfiles and the invocation environment can override
LOG_LEVEL_NAMES=(emerg alert crit err warning notice info debug)	# we also use these in syslog messages, so we have to use these specific level names
# Both of these can be independently forced to 1 or 0 in config:
if [[ -v TTY ]]; then
	USE_STDERR=${USE_STDERR:-1}					# by default output to stderr if there is a tty
else
	USE_SYSLOG=${USE_SYSLOG:-1}					# by default log to syslog if there is no tty
fi

function start_logger() { # starts a logger coprocess if one doesn't exist already
	if [[ -z "$have_logger" ]]; then
		if logger --help | fgrep -q -- '--id[=<id>]'; then
			coproc logger --stderr --id=$$ --tag "$me" --prio-prefix
		else	# old logger(1) doesn't support id=
			coproc logger --stderr --id --tag "$me" --prio-prefix
		fi
	fi
	have_logger=1
}

function log() { # Usage: log <level> <message>. Consults $USE_SYSLOG.
	# Prints message on stderr and optionally logs it to syslog.
	# Depends on "$me" being set to the name of the script being executed.
	# When logging to syslog, a facility of "daemon" is currently hardcoded.
	local level=$1
	local level_index=${LOG_LEVEL_NAMES[(ie)$level]}
	local LOG_LEVEL=${LOG_LEVEL:-info}	# set a default log level if the caller did not
	shift	# $@ holds the message now
	if ((${LOG_LEVEL_NAMES[(ie)$LOG_LEVEL]}>=level_index)); then	# is the message of high enough priority to be logged?
		# the following possibilities exist:
		#  * the message is either
		#   * an error (err, crit, alert or emerg)
		#   * not an error (warning, notice, info or debug).
		#   * However, we're not making this distinction. If it has sufficient priority, we output it.
		#   * TODO: make default log level "err" if run from cron (should probably go into README).
		#  * stderr is either
		#   * a terminal;
		#   * a file;
		#   * a pipe (likely connected to a logging coprocess).
		#   * Again, we don't care, just output the message.
		if ((USE_SYSLOG)); then
			if ((have_logger)); then	# if we have a logger coprocess, let it handle everything
				local prio="<$[3*8+(level_index-1)]>" # a decimal number within angle brackets that encodes both the facility and the level. The number is constructed by multiplying the facility by 8 and then adding the level. For example, daemon.info, meaning facility=3 and level=6, becomes <30>.
				echo $prio$@ >&p
			else	# we need to call logger ourselves
				if [[ -z $logger_has_id_equals ]]; then
					if logger --help | fgrep -q -- '--id[=<id>]'; then
						logger_has_id_equals=1	# this is a global variable, so we only need to perform this test once; the result will be "cached"
					else
						logger_has_id_equals=0
					fi
				fi
				if ((logger_has_id_equals)); then
					logger --tag "${me:-$0}" --id=$$ --priority daemon.$level -- "$@"
				else
					logger --tag "${me:-$0}" --id --priority daemon.$level -- "$@"
				fi
			fi
		fi
		((USE_STDERR)) && echo "${me:-$0}: $level: $@" >&2
	fi
}
	
function die() { # logs high-priority message, then exits the script with an error
	log emerg "$@"
	exit 111
}

function generate_password() { # Not currently used anywhere
	local length=${1:-16}
	local pwstr='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789;"[]+_-!@#$%^&*()/.,<>?'
	if [[ -x $(which pwgen 2>/dev/null) ]]; then
		pwgen -sy $length 1
	elif [[ -x $(which makepasswd 2>/dev/null) ]]; then
		makepasswd --chars=$length --string "$pwstr"
	else
		log warning "neither pwgen nor makepasswd installed. Generated password will be weak."
		if whence shuf 2>/dev/null; then
			for i in {1..$length}; do echo $pwstr[((RANDOM%$#pwstr+1))]; done | shuf | tr -d '\n'   # not sure how much shuf(1) helps, but it probably doesn't hurt
		else
			for i in {1..$length}; do echo -n $pwstr[((RANDOM%$#pwstr+1))]; done
		fi
	fi
}
