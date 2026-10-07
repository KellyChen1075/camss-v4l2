#!/bin/sh
# Push build outputs from the Ubuntu build host to the RB3 over SSH.
#
# Usage:
#   rb3-deploy.sh push <remote_dir> <file>...     copy files into <remote_dir> on the RB3
#   rb3-deploy.sh modules <kernel_build_dir>      install ov9282.ko / qcom-camss.ko and reload them
#   rb3-deploy.sh ssh [cmd...]                    open a shell (or run cmd) on the RB3
#
# Env: RB3_HOST (default 192.168.137.57), RB3_USER (default root)
set -eu

RB3_HOST=${RB3_HOST:-192.168.137.57}
RB3_USER=${RB3_USER:-root}
TARGET="$RB3_USER@$RB3_HOST"

# Reuse one SSH connection for all ssh/scp calls (one password prompt).
CTL="${XDG_RUNTIME_DIR:-/tmp}/rb3-ssh-%r@%h:%p"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=10m -o ConnectTimeout=5"

rb3() {
	# shellcheck disable=SC2086
	ssh $SSH_OPTS "$TARGET" "$@"
}

rb3_cp() {
	# shellcheck disable=SC2086
	scp $SSH_OPTS "$@"
}

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

newest() {
	# newest file named $2 under $1
	find "$1" -name "$2" -type f -printf '%T@ %p\n' 2>/dev/null |
		sort -n | tail -n1 | cut -d' ' -f2-
}

cmd_push() {
	[ $# -ge 2 ] || usage
	dest=$1
	shift
	rb3 "mount -o remount,rw / 2>/dev/null || true; mkdir -p '$dest'"
	rb3_cp "$@" "$TARGET:$dest/"
	echo "copied $# file(s) to $TARGET:$dest"
}

cmd_modules() {
	[ $# -eq 1 ] || usage
	build=$1
	mods=""
	for m in ov9282.ko qcom-camss.ko; do
		f=$(newest "$build" "$m")
		if [ -z "$f" ]; then
			echo "warning: $m not found under $build (built-in or not enabled?)" >&2
			continue
		fi
		echo "found $f"
		mods="$mods $f"
	done
	[ -n "$mods" ] || exit 1

	# Modules in updates/ take precedence over the stock ones for modprobe.
	krel=$(rb3 uname -r)
	dest="/lib/modules/$krel/updates"
	# shellcheck disable=SC2086
	cmd_push "$dest" $mods

	rb3 "set -x
		depmod -a
		rmmod qcom_camss 2>/dev/null; rmmod ov9282 2>/dev/null
		modprobe ov9282 && modprobe qcom-camss
		dmesg | grep -iE 'ov9282|camss' | tail -n 20"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
	push)    cmd_push "$@" ;;
	modules) cmd_modules "$@" ;;
	ssh)     rb3 "$@" ;;
	*)       usage ;;
esac
