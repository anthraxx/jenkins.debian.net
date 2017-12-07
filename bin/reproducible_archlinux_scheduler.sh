#!/bin/bash

# Copyright 2015-2017 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

DEBUG=true
. /srv/jenkins/bin/common-functions.sh
common_init "$@"

# common code
. /srv/jenkins/bin/reproducible_common.sh

set -e

update_archlinux_repositories() {
	echo "$(date -u) - currently $(find $BASE/archlinux/ -name pkg.needs_build | wc -l ) packages scheduled."
	UPDATED=$(mktemp -t archlinuxrb-scheduler-XXXXXXXX)
	NEW=$(mktemp -t archlinuxrb-scheduler-XXXXXXXX)
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
		done | sort -u -R > "$ARCHLINUX_PKGS"_full_pkgbase_list
	TOTAL=$(cat ${ARCHLINUX_PKGS}_full_pkgbase_list | wc -l)
	echo "$(date -u ) - $TOTAL Arch Linux packages are known in total to us."

	for REPO in $ARCHLINUX_REPOS ; do
		TMPPKGLIST=$(mktemp -t archlinuxrb-scheduler-XXXXXXXX)
		echo "$(date -u ) - updating list of available packages in repository '$REPO'."
		grep "^$REPO" "$ARCHLINUX_PKGS"_full_pkgbase_list | \
			while read repo pkgbase version; do
				if [ ! -d $BASE/archlinux/$REPO/$pkgbase ] ; then
					# schedule (all) entirely new packages
					echo $REPO/$pkgbase >> $NEW
					echo "$(date -u ) - scheduling new package $REPO/$pkgbase... "
					mkdir -p $BASE/archlinux/$REPO/$pkgbase
					touch $BASE/archlinux/$REPO/$pkgbase/pkg.needs_build
				elif [ ! -f $BASE/archlinux/$REPO/$pkgbase/pkg.needs_build ] ; then
					if [ -f $BASE/archlinux/$REPO/$pkgbase/pkg.version ] ; then
						VERSION=$(cat $BASE/archlinux/$REPO/$pkgbase/pkg.version 2>/dev/null)
						if [ "$(schroot --run-session -c $SESSION --directory /var/tmp -- vercmp $version $VERSION)" = "1" ] ; then
							# schedule packages where an updated version is availble
							echo $REPO/$pkgbase >> $UPDATED
							echo "$(date -u ) - we know about $REPO/$pkgbase $VERSION, but the repo has $version, so rescheduling... "
							touch $BASE/archlinux/$REPO/$pkgbase/pkg.needs_build
						else
							# schedule packages we already know about
							# (but only until 300 packages are scheduled in total)
							if [ $(find $BASE/archlinux/ -name pkg.needs_build | wc -l ) -le 300 ] ; then
								touch $BASE/archlinux/$REPO/$pkgbase/pkg.needs_build
							fi
						fi
					else
						echo "$(date -u ) - scheduling new package $REPO/$pkgbase... though this is strange and should not really happen…"
						touch $BASE/archlinux/$REPO/$pkgbase/pkg.needs_build
					fi
				fi
				printf '%s %s\n' "$pkgbase" "$version" >> $TMPPKGLIST
			done
		mv $TMPPKGLIST "$ARCHLINUX_PKGS"_"$REPO"
		echo "$(date -u ) - $(cat ${ARCHLINUX_PKGS}_$REPO | wc -l) packages in repository '$REPO' are known to us."
		new=$(grep -c ^$REPO $NEW || true)
		updated=$(grep -c ^$REPO $UPDATED || true)
		echo "$(date -u ) - scheduled $new/$updated packages in repository '$REPO'."
	done
	total=$(find $BASE/archlinux/ -name pkg.needs_build | wc -l )
	rm "$ARCHLINUX_PKGS"_full_pkgbase_list
	schroot --end-session -c $SESSION
	new=$(cat $NEW | wc -l 2>/dev/null|| true)
	updated=$(cat $UPDATED 2>/dev/null| wc -l || true)
	if [ $new -ne 0 ] || [ $updated -ne 0 ] ; then
		irc_message archlinux-reproducible "scheduled $new entirely new packages and $updated packages with newer versions, for $total scheduled out of $TOTAL."
	fi
	echo "$(date -u ) - scheduled $new/$updated packages."
	rm $NEW $UPDATED > /dev/null
}

echo "$(date -u ) - Updating Arch Linux repositories."
update_archlinux_repositories
echo "$(date -u ) - Done updating Arch Linux repositories."

# vim: set sw=0 noet :
