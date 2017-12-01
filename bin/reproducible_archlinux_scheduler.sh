#!/bin/bash

# Copyright 2015-2017 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

DEBUG=false
. /srv/jenkins/bin/common-functions.sh
common_init "$@"

# common code
. /srv/jenkins/bin/reproducible_common.sh

set -e

update_archlinux_repositories() {
	# every day we check for new archlinux packages in all tested repositories
	DUMMY=$(mktemp -t archlinux-dummy-XXXXXXXX)
	touch -d "$(date -d '1 day ago' '+%Y-%m-%d') 00:00 UTC" $DUMMY
	local NEED_UPDATE=false
	local REPO
	for REPO in $ARCHLINUX_REPOS ; do
		if [ ! -f ${ARCHLINUX_PKGS}_$REPO ] || [ $DUMMY -nt ${ARCHLINUX_PKGS}_$REPO ] ; then
			NEED_UPDATE=true
		fi
	done
	if $NEED_UPDATE ; then
		local SESSION="archlinux-scheduler-$RANDOM"
		schroot --begin-session --session-name=$SESSION -c jenkins-reproducible-archlinux
		schroot --run-session -c $SESSION --directory /var/tmp -- sudo pacman -Syu --noconfirm
		# Get a list of unique package bases.  Non-split packages don't have a pkgbase set
		# so we need to use the pkgname for them instead.
		schroot --run-session -c $SESSION --directory /var/tmp -- expac -S '%r %e %n %v' | \
			while read repo pkgbase pkgname version; do
				if [[ "$pkgbase" = "(null)" ]]; then
					printf '%s %s %s\n' "$repo" "$pkgname" "$version"
				else
					printf '%s %s %s\n' "$repo" "$pkgbase" "$version"
				fi
			done | sort -u > "$ARCHLINUX_PKGS"_full_pkgbase_list

		for REPO in $ARCHLINUX_REPOS ; do
			echo "$(date -u ) - updating list of available packages in repository '$REPO'."
			grep "^$REPO" "$ARCHLINUX_PKGS"_full_pkgbase_list | \
				while read repo pkgbase version; do
					printf '%s %s\n' "$pkgbase" "$version"
				done > "$ARCHLINUX_PKGS"_"$REPO"
			echo "$(date -u ) - these packages in repository '$REPO' are known to us:"
			cat ${ARCHLINUX_PKGS}_$REPO
		done
		rm "$ARCHLINUX_PKGS"_full_pkgbase_list
		schroot --end-session -c $SESSION
	else
		echo "$(date -u ) - repositories recent enough, no update needed."
	fi
	rm $DUMMY > /dev/null
}

echo "$(date -u ) - Updating Arch Linux repositories."
update_archlinux_repositories

# vim: set sw=0 noet :
