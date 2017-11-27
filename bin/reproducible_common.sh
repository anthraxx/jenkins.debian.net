#!/bin/bash

# Copyright 2014-2017 Holger Levsen <holger@layer-acht.org>
#              © 2015 Mattia Rizzolo <mattia@mapreri.org>
# released under the GPLv=2
#
# included by all reproducible_*.sh scripts, so be quiet
set +x

# postgres database definitions
export PGDATABASE=reproducibledb

# query reproducible database
query_db() {
	psql -t --no-align -c "$@"
}

# query reproducible database, output to csv format
query_to_csv() {
	psql -c "COPY ($@) to STDOUT with csv DELIMITER ','"
}

# common variables
REPRODUCIBLE_URL=https://tests.reproducible-builds.org
DEBIAN_URL=https://tests.reproducible-builds.org/debian
DEBIAN_DASHBOARD_URI=/debian/reproducible.html
REPRODUCIBLE_DOT_ORG_URL=https://reproducible-builds.org
# shop trailing slash
JENKINS_URL=${JENKINS_URL:0:-1}
DBDSUITE="unstable"
BIN_PATH=/srv/jenkins/bin
TEMPLATE_PATH=/srv/jenkins/mustache-templates/reproducible

# Debian suites being tested
SUITES="stretch buster unstable experimental"
# Debian architectures being tested
ARCHS="amd64 i386 arm64 armhf"

# define Debian build nodes in use
. /srv/jenkins/bin/jenkins_node_definitions.sh
MAINNODE="jenkins" # used by reproducible_maintenance.sh only

# variables on the nodes we are interested in
BUILD_ENV_VARS="ARCH NUM_CPU CPU_MODEL DATETIME KERNEL" # these also needs to be defined in bin/reproducible_info.sh

# existing usertags in the Debian BTS
USERTAGS="toolchain infrastructure timestamps fileordering buildpath username hostname uname randomness buildinfo cpu signatures environment umask ftbfs locale"

# common settings for testing Arch Linux
ARCHLINUX_REPOS="core extra multilib community"
ARCHLINUX_PKGS=/srv/reproducible-results/archlinux_pkgs

# common settings for testing rpm based distros
RPM_BUILD_NODE=profitbricks-build3-amd64
RPM_PKGS=/srv/reproducible-results/rpm_pkgs

# number of cores to be used
NUM_CPU=$(grep -c '^processor' /proc/cpuinfo)

# diffoscope memory limit in kilobytes
DIFFOSCOPE_VIRT_LIMIT=$((10*1024*1024))

# we only this array for html creation but we cannot declare them in a function
declare -A SPOKENTARGET

BASE="/var/lib/jenkins/userContent/reproducible"
DEBIAN_BASE="/var/lib/jenkins/userContent/reproducible/debian"
mkdir -p "$DEBIAN_BASE"

# to hold reproducible temporary files/directories without polluting /tmp
TEMPDIR="/tmp/reproducible"
mkdir -p "$TEMPDIR"

# create subdirs for suites
for i in $SUITES ; do
	mkdir -p "$DEBIAN_BASE/$i"
done

# table names and image names
TABLE[0]=stats_pkg_state
TABLE[1]=stats_builds_per_day
TABLE[2]=stats_builds_age
TABLE[3]=stats_bugs
TABLE[4]=stats_notes
TABLE[5]=stats_issues
TABLE[6]=stats_meta_pkg_state
TABLE[7]=stats_bugs_state
TABLE[8]=stats_bugs_sin_ftbfs
TABLE[9]=stats_bugs_sin_ftbfs_state

# package sets defined in meta_pkgsets.csv
# csv file columns: (pkgset_group, pkgset_name)
colindex=0
while IFS=, read col1 col2
do
	let colindex+=1
	META_PKGSET[$colindex]=$col2
done < $BIN_PATH/reproducible_pkgsets.csv

# mustache templates
PAGE_FOOTER_TEMPLATE=$TEMPLATE_PATH/default_page_footer.mustache
PROJECT_LINKS_TEMPLATE=$TEMPLATE_PATH/project_links.mustache
MAIN_NAVIGATION_TEMPLATE=$TEMPLATE_PATH/main_navigation.mustache

# be loud again if DEBUG
if $DEBUG ; then
	set -x
fi

# sleep 1-23 secs to randomize start times
delay_start() {
	/bin/sleep $(echo "scale=1 ; $(shuf -i 1-230 -n 1)/10" | bc )
}

schedule_packages() {
	LC_USER="$REQUESTER" \
	LOCAL_CALL="true" \
	/srv/jenkins/bin/reproducible_remote_scheduler.py \
		--message "$REASON" \
		--no-notify \
		--suite "$SUITE" \
		--architecture "$ARCH" \
		$@
}

write_page() {
	echo "$1" >> $PAGE
}

set_icon() {
	# icons taken from tango-icon-theme (0.8.90-5)
	# licenced under http://creativecommons.org/licenses/publicdomain/
	STATE_TARGET_NAME="$1"
	case "$1" in
		reproducible)		ICON=weather-clear.png
					;;
		unreproducible|FTBR)	ICON=weather-showers-scattered.png
					STATE_TARGET_NAME="FTBR"
					;;
		FTBFS)			ICON=weather-storm.png
					;;
		depwait)		ICON=weather-snow.png
					;;
		404)			ICON=weather-severe-alert.png
					;;
		not_for_us|"not for us")	ICON=weather-few-clouds-night.png
					STATE_TARGET_NAME="not_for_us"
					;;
		blacklisted)		ICON=error.png
					;;
		*)			ICON=""
	esac
}

write_icon() {
	# ICON and STATE_TARGET_NAME are set by set_icon()
	write_page "<a href=\"/debian/$SUITE/$ARCH/index_${STATE_TARGET_NAME}.html\" target=\"_parent\"><img src=\"/static/$ICON\" alt=\"${STATE_TARGET_NAME} icon\" /></a>"
}

write_page_header() {
	# this is really quite uncomprehensible and should be killed
	# the solution is to write all HTML pages with python…
	rm -f $PAGE
	MAINVIEW="dashboard"
	write_page "<!DOCTYPE html><html><head>"
	write_page "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />"
	write_page "<meta name=\"viewport\" content=\"width=device-width\" />"
	write_page "<link href=\"/static/style.css\" type=\"text/css\" rel=\"stylesheet\" />"
	write_page "<title>$2</title></head>"
	if [ "$1" != "$MAINVIEW" ] ; then
		write_page "<body class=\"wrapper\">"
	else
		write_page "<body class=\"wrapper\" onload=\"selectSearch()\">"
	fi

	# Build context for the main_navigation mustache template.

	# Do not show package set links for "experimental" pages
	if [ "$SUITE" != "experimental" ] ; then
		# no pkg_sets are tested in experimental
		include_pkgset_link="\"include_pkgset_link\" : \"true\""
	else
		include_pkgset_link=''
	fi

	# Used to highlight the link for the current page
	if [ "$1" = "dashboard" ] \
		|| [ "$1" = "performance" ] \
		|| [ "$1" = "repositories" ] \
		|| [ "$1" = "variations" ] \
		|| [ "$1" = "suite_arch_stats" ] \
		|| [ "$1" = "bugs" ] \
		|| [ "$1" = "nodes_health" ] \
		|| [ "$1" = "nodes_weekly_graphs" ] \
		|| [ "$1" = "nodes_daily_graphs" ] ; then
		displayed_page="\"$1\": \"true\""
	else
		displayed_page=''
	fi

	# Create json for suite links (a list of objects)
	suite_links="\"suite_nav\": { \"suite_list\": ["
	comma=0
	for s in $SUITES ; do
		if [ "$s" = "$SUITE" ] ; then
			class="current"
		else
			class=''
		fi
		uri="/debian/${s}/index_suite_${ARCH}_stats.html"
		if [ $comma == 1 ] ; then
			suite_links+=", {\"s\": \"${s}\", \"class\": \"$class\", \"uri\": \"$uri\"}"
		else
			suite_links+="{\"s\": \"${s}\", \"class\": \"$class\", \"uri\": \"$uri\"}"
			comma=1
		fi
	done
	suite_links+="]}"

	# Create json for arch links (a list of objects)
	arch_links="\"arch_nav\": {\"arch_list\": ["
	comma=0
	for a in ${ARCHS} ; do
		if [ "$a" = "$ARCH" ] ; then
			class="current"
		else
			class=''
		fi
		uri="/debian/$SUITE/index_suite_${a}_stats.html"
		if [ $comma == 1 ] ; then
			arch_links+=", {\"a\": \"${a}\", \"class\": \"$class\", \"uri\": \"$uri\"}"
		else
			arch_links+="{\"a\": \"${a}\", \"class\": \"$class\", \"uri\": \"$uri\"}"
			comma=1
		fi
	done
	arch_links+="]}"

	# finally, the completely formed JSON context
	context=$(printf '{
		"arch" : "%s",
		"suite" : "%s",
		"page_title" : "%s",
		"debian_uri" : "%s",
		%s,
		%s
	' "$ARCH" "$SUITE" "$2" "$DEBIAN_DASHBOARD_URI" "$arch_links" "$suite_links")
	if [[ ! -z $displayed_page ]] ; then
		context+=", $displayed_page"
	fi
	if [[ ! -z $include_pkgset_link ]] ; then
		context+=", $include_pkgset_link"
	fi
	context+="}"

	write_page "<header class=\"head\">"
	write_page "$(pystache3 $MAIN_NAVIGATION_TEMPLATE "$context")"
	write_page "$(pystache3 $PROJECT_LINKS_TEMPLATE "{}")"
	write_page "</header>"

	write_page "<div class=\"mainbody\">"
	write_page "<h2>$2</h2>"
	if [ "$1" = "$MAINVIEW" ] ; then
		write_page "<ul>"
		write_page "   Please also visit the more general website <li><a href=\"https://reproducible-builds.org\">Reproducible-builds.org</a></li> where <em>reproducible builds</em> are explained in more detail than just <em>bit by bit identical rebuilds to enable verifcation of the sources used to build</em>."
		write_page "   We think that reproducible builds should become the norm, so we wrote <li><a href=\"https://reproducible-builds.org/howto\">How to make your software reproducible</a></li>."
		write_page "   Also aimed at the free software world at large, is the first specification we have written: the <li><a href=\"https://reproducible-builds.org/specs/source-date-epoch/\">SOURCE_DATE_EPOCH specification</a></li>."
		write_page "</ul>"
		write_page "<ul>"
		write_page "   These pages are showing the <em>potential</em> of <li><a href=\"https://wiki.debian.org/ReproducibleBuilds\" target=\"_blank\">reproducible builds of Debian packages</a></li>."
		write_page "   The results shown were obtained by <a href=\"$JENKINS_URL/view/reproducible\">several jobs</a> running on"
		write_page "   <a href=\"$JENKINS_URL/userContent/about.html#_reproducible_builds_jobs\">jenkins.debian.net</a>."
		write_page "   Thanks to <a href=\"https://www.profitbricks.co.uk\">Profitbricks</a> for donating the virtual machines this is running on!"
		write_page "</ul>"
		LATEST=$(query_db "SELECT s.name FROM results AS r JOIN sources AS s ON r.package_id = s.id WHERE r.status IN ('unreproducible') AND s.suite = 'unstable' AND s.architecture = 'amd64' AND s.id NOT IN (SELECT package_id FROM notes) ORDER BY build_date DESC LIMIT 23"|sort -R|head -1)
		write_page "<form action=\"$REPRODUCIBLE_URL/redirect\" method=\"GET\">$REPRODUCIBLE_URL/"
		write_page "<input type=\"text\" name=\"SrcPkg\" placeholder=\"Type my friend..\" value=\"$LATEST\" />"
		write_page "<input type=\"submit\" value=\"submit source package name\" />"
		write_page "</form>"
		write_page "<ul>"
		write_page "   We are reachable via IRC (<code>#debian-reproducible</code> and <code>#reproducible-builds</code> on OFTC),"
		write_page "   or <a href="mailto:reproducible-builds@lists.alioth.debian.org">email</a>,"
		write_page "   and we care about free software in general,"
		write_page "   so whether you are an upstream developer or working on another distribution, or have any other feedback - we'd love to hear from you!"
		write_page "   Besides Debian we are also testing "
		write_page "   <li><a href=\"/coreboot/\">coreboot</a></li>,"
		write_page "   <li><a href=\"/openwrt/\">OpenWrt</a></li>, "
		write_page "   <li><a href=\"/netbsd/\">NetBSD</a></li>, "
		write_page "   <li><a href=\"/freebsd/\">FreeBSD</a></li>, "
		write_page "   <li><a href=\"/archlinux/\">Arch Linux</a></li> "
		write_page "   and <li><a href=\"/lede/\">LEDE</a></li>, "
		write_page "   though not as thoroughly as Debian (yet?) - and testing of "
		write_page "   <li><a href=\"/rpms/fedora-23.html\">Fedora</a></li> "
		write_page "   has just begun, and there are plans to test "
		write_page "   <a href=\"https://jenkins.debian.net/userContent/todo.html#_reproducible_fdroid\">F-Droid</a> and "
		write_page "   <a href=\"https://jenkins.debian.net/userContent/todo.html#_reproducible_guix\">GNU Guix</a> too, "
		# link openSUSE here too
		write_page "   and more, if you contribute!"
		write_page "</ul>"
	fi
}

write_page_intro() {
	write_page "       <p><em>Reproducible builds</em> enable anyone to reproduce bit by bit identical binary packages from a given source, so that anyone can verify that a given binary derived from the source it was said to be derived."
	write_page "         There is more information about <a href=\"https://wiki.debian.org/ReproducibleBuilds\">reproducible builds on the Debian wiki</a> and on <a href=\"https://reproducible-builds.org\">https://reproducible-builds.org</a>."
	write_page "         These pages explain in more depth why this is useful, what common issues exist and which workarounds and solutions are known."
	write_page "        </p>"
	local BUILD_ENVIRONMENT=" in a Debian environment"
	local BRANCH="master"
	if [ "$1" = "coreboot" ] ; then
		write_page "        <p><em>Reproducible Coreboot</em> is an effort to apply this to coreboot. Thus each coreboot.rom is build twice (without payloads), with a few variations added and then those two ROMs are compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>. Please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
		local PROJECTNAME="$1"
		local PROJECTURL="https://review.coreboot.org/p/coreboot.git"
	elif [ "$1" = "OpenWrt" ] || [ "$1" = "LEDE" ]; then
		local PROJECTNAME="$1"
		if [ "$PROJECTNAME" = "OpenWrt" ] ; then
			local PROJECTURL="https://github.com/openwrt/openwrt.git"
		else
			local PROJECTURL="https://git.lede-project.org/?p=source.git;a=summary"
		fi
		write_page "        <p><em>Reproducible $PROJECTNAME</em> is an effort to apply this to $PROJECTNAME. Thus each $PROJECTNAME target is build twice, with a few variations added and then the resulting images and packages from the two builds are compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>. $PROJECTNAME generates many different types of raw <code>.bin</code> files, and diffoscope does not know how to parse these. Thus the resulting diffoscope output is not nearly as clear as it could be - hopefully this limitation will be overcome eventually, but in the meanwhile the input components (uImage kernel file, rootfs.tar.gz, and/or rootfs squashfs) can be inspected. Also please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
	elif [ "$1" = "NetBSD" ] ; then
		write_page "        <p><em>Reproducible NetBSD</em> is an effort to apply this to NetBSD. Thus each NetBSD target is build twice, with a few variations added and then the resulting files from the two builds are compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>. Please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
		local PROJECTNAME="netbsd"
		local PROJECTURL="https://github.com/jsonn/src"
	elif [ "$1" = "FreeBSD" ] ; then
		write_page "        <p><em>Reproducible FreeBSD</em> is an effort to apply this to FreeBSD. Thus FreeBSD is build twice, with a few variations added and then the resulting filesystems from the two builds are put into a compressed tar archive, which is finally compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>. Please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
		local PROJECTNAME="freebsd"
		local PROJECTURL="https://github.com/freebsd/freebsd.git"
		local BUILD_ENVIRONMENT=", which via ssh triggers a build on a FreeBSD 10.3 system"
		local BRANCH="release/10.3.0"
	elif [ "$1" = "Arch Linux" ] ; then
		local PROJECTNAME="Arch Linux"
		write_page "        <p><em>Reproducible $PROJECTNAME</em> is an effort to apply this to $PROJECTNAME. Thus $PROJECTNAME packages are build twice, with a few variations added and then the resulting packages from the two builds are compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>."
		write_page "   Please note that this is still at an early stage. Also there are more variations expected to be seen in the wild."
		write_page "Missing bits for <em>testing</em> Arch Linux:<ul>"
		write_page " <li>more variations, see below.</li>"
		write_page " <li>cross references to <a href=\"https://tests.reproducible-builds.org/debian/index_issues.html\">Debian notes</a> - and having Arch Linux specific notes.</li>"
		write_page "</ul></p>"
		write_page "<p>Missing bits for Arch Linux:<ul>"
		write_page " <li>pacman 5.0.2 needs an upload to the official Arch repository, so far the needed changes are only (used here and) in git. Once the pacman upload has happened:<ul>"
		write_page "  <li>we can compare the packages built twice here against the ones from the official Arch Linux repositories.</li>"
		write_page "  <li>all packages need to be rebuild so that then they include .BUILDINFO files.</li>"
		write_page " </ul></li>"
		write_page " <li>user tools, for users to verify all of this easily.</li>"
		write_page "</ul></p>"
	elif [ "$1" = "fedora-23" ] ; then
		local PROJECTNAME="Fedora 23"
		write_page "        <p><em>Reproducible $PROJECTNAME</em> is a (currently somewhat stalled) effort to apply this to $PROJECTNAME, which is rather obvious with 23… <br/> $PROJECTNAME packages are build twice, with a few variations added and then the resulting packages from the two builds are compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>. Please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
	fi
	if [ "$1" != "Arch Linux" ] && [ "$1" != "fedora-23" ] ; then
		local SMALLPROJECTNAME="$(echo $PROJECTNAME|tr '[:upper:]' '[:lower:]')"
		write_page "       <p>There is a weekly run <a href=\"https://jenkins.debian.net/view/reproducible/job/reproducible_$SMALLPROJECTNAME/\">jenkins job</a> to test the <code>$BRANCH</code> branch of <a href=\"$PROJECTURL\">$PROJECTNAME.git</a>. The jenkins job is running <a href=\"https://anonscm.debian.org/git/qa/jenkins.debian.net.git/tree/bin/reproducible_$SMALLPROJECTNAME.sh\">reproducible_$SMALLPROJECTNAME.sh</a>$BUILD_ENVIRONMENT and this script is solely responsible for creating this page. Feel invited to join <code>#debian-reproducible</code> (on irc.oftc.net) to request job runs whenever sensible. Patches and other <a href=\"mailto:reproducible-builds@lists.alioth.debian.org\">feedback</a> are very much appreciated - if you want to help, please start by looking at the <a href=\"https://jenkins.debian.net/userContent/todo.html#_reproducible_$(echo $1|tr '[:upper:]' '[:lower:]')\">ToDo list for $1</a>, you might find something easy to contribute."
		write_page "       <br />Thanks to <a href=\"https://www.profitbricks.co.uk\">Profitbricks</a> for donating the virtual machines this is running on!</p>"
	elif [ "$1" = "fedora-23" ] ; then
		write_page "       <p><img src=\"/userContent/static/weather-storm.png\"> FIXME: explain $PROJECTNAME test setup here.</p>"
	fi
}

write_page_footer() {
	if [ "$1" = "coreboot" ] ; then
		other_distro_details='The <a href=\"http://www.coreboot.org\">Coreboot</a> logo is Copyright © 2008 by Konsult Stuge and coresystems GmbH and can freely be used to refer to the Coreboot project.'
	elif [ "$1" = "NetBSD" ] ; then
		other_distro_details="NetBSD® is a registered trademark of The NetBSD Foundation, Inc."
	elif [ "$1" = "FreeBSD" ] ; then
		other_distro_details="FreeBSD is a registered trademark of The FreeBSD Foundation. The FreeBSD logo and The Power to Serve are trademarks of The FreeBSD Foundation."
	elif [ "$1" = "Arch Linux" ] ; then
		other_distro_details='The <a href=\"https://www.archlinux.org\">Arch Linux</a> name and logo are recognized trademarks. Some rights reserved. The registered trademark Linux® is used pursuant to a sublicense from LMI, the exclusive licensee of Linus Torvalds, owner of the mark on a world-wide basis.'
	elif [ "$1" = "fedora-23" ] ; then
		other_distro_details="FIXME: add fedora copyright+trademark disclaimers here."
	else
		other_distro_details=''
	fi
	now=$(date +'%Y-%m-%d %H:%M %Z')

	# The context for pystache3 CLI must be json
	context=$(printf '{
		"job_url" : "%s",
		"job_name" : "%s",
		"date" : "%s",
		"other_distro_details" : "%s"
	}' "${JOB_URL:-""}" "${JOB_NAME:-""}" "$now" "$other_distro_details")

	write_page "$(pystache3 $PAGE_FOOTER_TEMPLATE "$context")"
	write_page "</div>"
	write_page "</body></html>"
 }

write_variation_table() {
	write_page "<p style=\"clear:both;\">"
	if [ "$1" = "fedora-23" ] ; then
		write_page "There are no variations introduced in the $1 builds yet. Stay tuned.</p>"
		return
	fi
	write_page "<table class=\"main\" id=\"variation\"><tr><th>variation</th><th width=\"40%\">first build</th><th width=\"40%\">second build</th></tr>"
	if [ "$1" = "debian" ] ; then
		write_page "<tr><td>hostname</td><td>one of:"
		for a in ${ARCHS} ; do
			local COMMA=""
			local ARCH_NODES=""
			write_page "<br />&nbsp;&nbsp;"
			for i in $(echo $BUILD_NODES | sed -s 's# #\n#g' | sort -u) ; do
				if [ "$(echo $i | grep $a)" ] ; then
					echo -n "$COMMA ${ARCH_NODES}$(echo $i | cut -d '.' -f1 | sed -s 's# ##g')" >> $PAGE
					if [ -z $COMMA ] ; then
						COMMA=","
					fi
				fi
			done
		done
		write_page "</td><td>i-capture-the-hostname</td></tr>"
		write_page "<tr><td>domainname</td><td>$(hostname -d)</td><td>i-capture-the-domainname</td></tr>"
	else
		if [ "$1" = "LEDE" ] || [ "$1" != "Arch Linux" ] || [ "$1" != "OpenWrt" ] ; then
			write_page "<tr><td>hostname</td><td> profitbricks-build3-amd64 or profitbricks-build4-amd64</td><td>the other one</td></tr>"
		else
			write_page "<tr><td>hostname</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		fi
		write_page "<tr><td>domainname</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
	fi
	if [ "$1" != "FreeBSD" ] && [ "$1" != "Arch Linux" ] && [ "$1" != "fedora-23" ] ; then
		write_page "<tr><td>env CAPTURE_ENVIRONMENT</td><td><em>not set</em></td><td>CAPTURE_ENVIRONMENT=\"I capture the environment\"</td></tr>"
	fi
	write_page "<tr><td>env TZ</td><td>TZ=\"/usr/share/zoneinfo/Etc/GMT+12\"</td><td>TZ=\"/usr/share/zoneinfo/Etc/GMT-14\"</td></tr>"
	if [ "$1" = "debian" ]  ; then
		write_page "<tr><td>env LANG</td><td>LANG=\"C\"</td><td>on amd64: LANG=\"fr_CH.UTF-8\"<br />on i386: LANG=\"de_CH.UTF-8\"<br />on arm64: LANG=\"nl_BE.UTF-8\"<br />on armhf: LANG=\"it_CH.UTF-8\"</td></tr>"
		write_page "<tr><td>env LANGUAGE</td><td>LANGUAGE=\"en_US:en\"</td><td>on amd64: LANGUAGE=\"fr_CH:fr\"<br />on i386: LANGUAGE=\"de_CH:de\"<br />on arm64: LANGUAGE=\"nl_BE:nl\"<br />on armhf: LANGUAGE=\"it_CH:it\"</td></tr>"
		write_page "<tr><td>env LC_ALL</td><td><em>not set</em></td><td>on amd64: LC_ALL=\"fr_CH.UTF-8\"<br />on i386: LC_ALL=\"de_CH.UTF-8\"<br />on arm64: LC_ALL=\"nl_BE.UTF-8\"<br />on armhf: LC_ALL=\"it_CH.UTF-8\"</td></tr>"
	elif [ "$1" = "Arch Linux" ]  ; then
		write_page "<tr><td>env LANG</td><td><em>not set</em></td><td>LANG=\"fr_CH.UTF-8\"</td></tr>"
		write_page "<tr><td>env LC_ALL</td><td><em>not set</em></td><td>LC_ALL=\"fr_CH.UTF-8\"</td></tr>"
	else
		write_page "<tr><td>env LANG</td><td>LANG=\"en_GB.UTF-8\"</td><td>LANG=\"fr_CH.UTF-8\"</td></tr>"
		write_page "<tr><td>env LC_ALL</td><td><em>not set</em></td><td>LC_ALL=\"fr_CH.UTF-8\"</td></tr>"
	fi
	if [ "$1" != "FreeBSD" ] && [ "$1" != "Arch Linux" ]  ; then
		write_page "<tr><td>env PATH</td><td>PATH=\"/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:\"</td><td>PATH=\"/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/i/capture/the/path\"</td></tr>"
	else
		write_page "<tr><td>env PATH</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
	fi
	if [ "$1" = "debian" ] ; then
		write_page "<tr><td>env BUILDUSERID</td><td>BUILDUSERID=\"1111\"</td><td>BUILDUSERID=\"2222\"</td></tr>"
		write_page "<tr><td>env BUILDUSERNAME</td><td>BUILDUSERNAME=\"pbuilder1\"</td><td>BUILDUSERNAME=\"pbuilder2\"</td></tr>"
		write_page "<tr><td>env USER</td><td>USER=\"pbuilder1\"</td><td>USER=\"pbuilder2\"</td></tr>"
		write_page "<tr><td>env HOME</td><td>HOME=\"/nonexistent/first-build\"</td><td>HOME=\"/nonexistent/second-build\"</td></tr>"
		write_page "<tr><td>niceness</td><td>10</td><td>11</td></tr>"
		write_page "<tr><td>uid</td><td>uid=1111</td><td>uid=2222</td></tr>"
		write_page "<tr><td>gid</td><td>gid=1111</td><td>gid=2222</td></tr>"
		write_page "<tr><td>/bin/sh</td><td>/bin/dash</td><td>/bin/bash</td></tr>"
		write_page "<tr><td>build path</td><td>/build/1st/\$pkg-\$ver <em>(not varied for stretch/buster)</em></td><td>/build/\$pkg-\$ver/2nd <em>(not varied for stretch/buster)</em></td></tr>"
		write_page "<tr><td>user's login shell</td><td>/bin/sh</td><td>/bin/bash</td></tr>"
		write_page "<tr><td>user's <a href="https://en.wikipedia.org/wiki/Gecos_field">GECOS</a></td><td>first user,first room,first work-phone,first home-phone,first other</td><td>second user,second room,second work-phone,second home-phone,second other</td></tr>"
		write_page "<tr><td>env DEB_BUILD_OPTIONS</td><td>DEB_BUILD_OPTIONS=\"parallel=XXX\"<br />&nbsp;&nbsp;XXX on amd64: 16 or 15<br />&nbsp;&nbsp;XXX on i386: 10 or 9<br />&nbsp;&nbsp;XXX on armhf: 8, 4 or 2</td><td>DEB_BUILD_OPTIONS=\"parallel=YYY\"<br />&nbsp;&nbsp;YYY on amd64: 16 or 15 (!= the first build)<br />&nbsp;&nbsp;YYY on i386: 10 or 9 (!= the first build)<br />&nbsp;&nbsp;YYY is the same as XXX on arm64<br />&nbsp;&nbsp;YYY on armhf: 8, 4, or 2 (not varied systematically)</td></tr>"
		write_page "<tr><td>UTS namespace</td><td><em>shared with the host</em></td><td><em>modified using</em> /usr/bin/unshare --uts</td></tr>"
	else
		write_page "<tr><td>env USER</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		write_page "<tr><td>uid</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		write_page "<tr><td>gid</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		if [ "$1" != "FreeBSD" ] ; then
			write_page "<tr><td>UTS namespace</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		fi
	fi
	if [ "$1" != "FreeBSD" ] ; then
		if [ "$1" = "debian" ] ; then
			write_page "<tr><td>kernel version</td></td><td>"
			for a in ${ARCHS} ; do
				write_page "<br />on $a one of:"
				write_page "$(cat /srv/reproducible-results/node-information/*$a* | grep KERNEL | cut -d '=' -f2- | sort -u | tr '\n' '\0' | xargs -0 -n1 echo '<br />&nbsp;&nbsp;')"
			done
			write_page "</td>"
			write_page "<td>(on amd64 systematically varied, on i386 as well and also with 32 and 64 bit kernel variation, while on armhf not systematically)<br />"
			for a in ${ARCHS} ; do
				write_page "<br />on $a one of:"
				write_page "$(cat /srv/reproducible-results/node-information/*$a* | grep KERNEL | cut -d '=' -f2- | sort -u | tr '\n' '\0' | xargs -0 -n1 echo '<br />&nbsp;&nbsp;')"
			done
			write_page "</td></tr>"
		elif [ "$1" != "Arch Linux" ]  ; then
			write_page "<tr><td>kernel version, modified using /usr/bin/linux64 --uname-2.6</td><td>$(uname -sr)</td><td>$(/usr/bin/linux64 --uname-2.6 uname -sr)</td></tr>"
		else
			write_page "<tr><td>kernel version</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		fi
		write_page "<tr><td>umask</td><td>0022<td>0002</td><tr>"
	else
		write_page "<tr><td>FreeBSD kernel version</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		write_page "<tr><td>umask</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td><tr>"
	fi
	FUTURE=$(date --date="${DATE}+398 days" +'%Y-%m-%d')
	if [ "$1" = "debian" ] ; then
		write_page "<tr><td>CPU type</td><td>one of: $(cat /srv/reproducible-results/node-information/* | grep CPU_MODEL | cut -d '=' -f2- | sort -u | tr '\n' '\0' | xargs -0 -n1 echo '<br />&nbsp;&nbsp;')</td><td>on i386: systematically varied (AMD or Intel CPU with different names & features)<br />on amd64: same for both builds<br />on arm64: always the same<br />on armhf: sometimes varied (depending on the build job), but only the minor CPU revision</td></tr>"
		write_page "<tr><td>year, month, date</td><td>today ($DATE) or (on amd64, i386 and arm64 only) also: $FUTURE</td><td>on amd64, i386 and arm64: varied (398 days difference)<br />on armhf: same for both builds (currently, work in progress)</td></tr>"
	else
		write_page "<tr><td>CPU type</td><td>$(cat /proc/cpuinfo|grep 'model name'|head -1|cut -d ":" -f2-)</td><td>same for both builds</td></tr>"
		write_page "<tr><td>/bin/sh</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		if [ "$1" != "FreeBSD" ] && [ "$1" != "Arch Linux" ] ; then
			write_page "<tr><td>year, month, date</td><td>today ($DATE)</td><td>same for both builds (currently, work in progress)</td></tr>"
		else
			write_page "<tr><td>year, month, date</td><td>today ($DATE)</td><td>398 days in the future ($FUTURE)</td></tr>"
		fi
	fi
	if [ "$1" != "FreeBSD" ] ; then
		if [ "$1" = "debian" ] ; then
			write_page "<tr><td>hour, minute</td><td>at least the minute will probably vary between two builds anyway...</td><td>on amd64, i386 and arm64 the \"future builds\" additionally run 6h and 23min ahead</td></tr>"
		        write_page "<tr><td>filesystem</td><td>tmpfs</td><td><em>temporarily not</em> varied using <a href=\"https://tracker.debian.org/disorderfs\">disorderfs</a> (<a href=\"https://sources.debian.net/src/disorderfs/sid/disorderfs.1.txt/\">manpage</a>)</td></tr>"
		else
			write_page "<tr><td>hour, minute</td><td>hour and minute will probably vary between two builds...</td><td>the future system actually runs 398 days, 6 hours and 23 minutes ahead...</td></tr>"
			write_page "<tr><td>Filesystem</td><td>tmpfs</td><td>same for both builds (currently, this could be varied using <a href=\"https://tracker.debian.org/disorderfs\">disorderfs</a>)</td></tr>"
		fi
	else
		write_page "<tr><td>year, month, date</td><td>today ($DATE)</td><td>the 2nd build is done with the build node set 1 year, 1 month and 1 day in the future</td></tr>"
		write_page "<tr><td>hour, minute</td><td>hour and minute will vary between two builds</td><td>additionally the \"future build\" also runs 6h and 23min ahead</td></tr>"
		write_page "<tr><td>filesystem of the build directory</td><td>ufs</td><td>same for both builds</td></tr>"
	fi
	if [ "$1" = "debian" ] ; then
		write_page "<tr><td><em>everything else...</em></td><td colspan=\"2\">is likely the same. So far, this is just about the <em>potential</em> of <a href=\"https://wiki.debian.org/ReproducibleBuilds\">reproducible builds of Debian</a> - there will be more variations in the wild.</td></tr>"
	else
		write_page "<tr><td><em>everything else...</em></td><td colspan=\"2\">is likely the same. There will be more variations in the wild.</td></tr>"
	fi
	write_page "</table></p>"
}

publish_page() {
	if [ "$1" = "" ] ; then
		TARGET=$PAGE
	else
		TARGET=$1/$PAGE
	fi
	cp -v $PAGE $BASE/$TARGET
	rm $PAGE
	echo "Enjoy $REPRODUCIBLE_URL/$TARGET"
}

link_packages() {
	set +x
        local i
	for (( i=1; i<$#+1; i=i+400 )) ; do
		local string='['
		local delimiter=''
		local j
		for (( j=0; j<400; j++)) ; do
			local item=$(( $j+$i ))
			if (( $item < $#+1 )) ; then
				string+="${delimiter}\"${!item}\""
				delimiter=','
			fi
		done
		string+=']'
		cd /srv/jenkins/bin
		DATA=" $(python3 -c "from reproducible_common import link_packages; \
				print(link_packages(${string}, '$SUITE', '$ARCH'))" 2> /dev/null)"
		cd - > /dev/null
		write_page "$DATA"
	done
	if "$DEBUG" ; then set -x ; fi
}

gen_package_html() {
	cd /srv/jenkins/bin
	python3 -c "import reproducible_html_packages as rep
pkg = rep.Package('$1', no_notes=True)
rep.gen_packages_html([pkg], no_clean=True)" || echo "Warning: cannot update HTML pages for $1"
	cd - > /dev/null
}

calculate_build_duration() {
	END=$(date +'%s')
	DURATION=$(( $END - $START ))
}

print_out_duration() {
	if [ -z "$DURATION" ]; then
		return
	fi
	local HOUR=$(echo "$DURATION/3600"|bc)
	local MIN=$(echo "($DURATION-$HOUR*3600)/60"|bc)
	local SEC=$(echo "$DURATION-$HOUR*3600-$MIN*60"|bc)
	echo "$(date -u) - total duration: ${HOUR}h ${MIN}m ${SEC}s." | tee -a ${RBUILDLOG}
}

irc_message() {
	local CHANNEL="$1"
	shift
	local MESSAGE="$@"
	echo "Sending '$MESSAGE' to $CHANNEL now."
	kgb-client --conf /srv/jenkins/kgb/$CHANNEL.conf --relay-msg "$MESSAGE" || true # don't fail the whole job
}

call_diffoscope() {
	mkdir -p $TMPDIR/$1/$(dirname $2)
	local TMPLOG=(mktemp --tmpdir=$TMPDIR)
	local msg=""
	set +e
	# remember to also modify the retry diffoscope call 15 lines below
	( ulimit -v "$DIFFOSCOPE_VIRT_LIMIT"
	  timeout "$TIMEOUT" nice schroot \
		--directory $TMPDIR \
		-c source:jenkins-reproducible-${DBDSUITE}-diffoscope \
		diffoscope -- \
			--html $TMPDIR/$1/$2.html \
			$TMPDIR/b1/$1/$2 \
			$TMPDIR/b2/$1/$2 2>&1 \
	) 2>&1 >> $TMPLOG
	RESULT=$?
	LOG_RESULT=$(grep '^E: 15binfmt: update-binfmts: unable to open' $TMPLOG || true)
	if [ ! -z "$LOG_RESULT" ] ; then
		rm -f $TMPLOG $TMPDIR/$1/$2.html
		echo "$(date -u) - schroot jenkins-reproducible-${DBDSUITE}-diffoscope not available, will sleep 2min and retry."
		sleep 2m
		# remember to also modify the retry diffoscope call 15 lines above
		( ulimit -v "$DIFFOSCOPE_VIRT_LIMIT"
		  timeout "$TIMEOUT" nice schroot \
			--directory $TMPDIR \
			-c source:jenkins-reproducible-${DBDSUITE}-diffoscope \
			diffoscope -- \
				--html $TMPDIR/$1/$2.html \
				$TMPDIR/b1/$1/$2 \
				$TMPDIR/b2/$1/$2 2>&1 \
			) 2>&1 >> $TMPLOG
		RESULT=$?
	fi
	if ! "$DEBUG" ; then set +x ; fi
	set -e
	cat $TMPLOG # print dbd output
	rm -f $TMPLOG
	case $RESULT in
		0)	echo "$(date -u) - $1/$2 is reproducible, yay!"
			;;
		1)
			echo "$(date -u) - $DIFFOSCOPE found issues, please investigate $1/$2"
			;;
		2)
			msg="$(date -u) - $DIFFOSCOPE had trouble comparing the two builds. Please investigate $1/$2"
			;;
		124)
			if [ ! -s $TMPDIR/$1.html ] ; then
				msg="$(date -u) - $DIFFOSCOPE produced no output for $1/$2 and was killed after running into timeout after ${TIMEOUT}..."
			else
				msg="$DIFFOSCOPE was killed after running into timeout after $TIMEOUT, but there is still $TMPDIR/$1/$2.html"
			fi
			;;
		*)
			# Process killed by signal exits with 128+${signal number}.
			# 31 = SIGSYS = maximum signal number in signal(7)
			if (( $RESULT > 128 )) && (( $RESULT <= 128+31 )); then
				RESULT="$RESULT (SIG$(kill -l $(($RESULT - 128))))"
			fi
			msg="$(date -u) - Something weird happened, $DIFFOSCOPE on $1/$2 exited with $RESULT and I don't know how to handle it."
			;;
	esac
	if [ ! -z "$msg" ] ; then
		echo $msg | tee -a $TMPDIR/$1/$2.html
	fi
}

get_filesize() {
		local BYTESIZE="$(du -h -b $1 | cut -f1)"
		# numbers below 16384K are understood and more meaningful than 16M...
		if [ $BYTESIZE -gt 16777216 ] ; then
			SIZE="$(echo $BYTESIZE/1048576|bc)M"
		elif [ $BYTESIZE -gt 1024 ] ; then
			SIZE="$(echo $BYTESIZE/1024|bc)K"
		else
			SIZE="$BYTESIZE bytes"
		fi
}

cleanup_pkg_files() {
	rm -vf $DEBIAN_BASE/rbuild/${SUITE}/${ARCH}/${SRCPACKAGE}_*.rbuild.log{,.gz}
	rm -vf $DEBIAN_BASE/logs/${SUITE}/${ARCH}/${SRCPACKAGE}_*.build?.log{,.gz}
	rm -vf $DEBIAN_BASE/dbd/${SUITE}/${ARCH}/${SRCPACKAGE}_*.diffoscope.html
	rm -vf $DEBIAN_BASE/dbdtxt/${SUITE}/${ARCH}/${SRCPACKAGE}_*.diffoscope.txt{,.gz}
	rm -vf $DEBIAN_BASE/buildinfo/${SUITE}/${ARCH}/${SRCPACKAGE}_*.buildinfo
	rm -vf $DEBIAN_BASE/logdiffs/${SUITE}/${ARCH}/${SRCPACKAGE}_*.diff{,.gz}
}

#
# create the png (and query the db to populate a csv file...)
#
create_png_from_table() {
	echo "Checking whether to update $2..."
	# $1 = id of the stats table
	# $2 = image file name
	echo "${FIELDS[$1]}" > ${TABLE[$1]}.csv
	# prepare query
	WHERE_EXTRA="WHERE suite = '$SUITE'"
	if [ "$ARCH" = "armhf" ] ; then
		# armhf was only build since 2015-08-30
		WHERE2_EXTRA="WHERE s.datum >= '2015-08-30'"
	elif [ "$ARCH" = "i386" ] ; then
		# i386 was only build since 2016-03-28
		WHERE2_EXTRA="WHERE s.datum >= '2016-03-28'"
	elif [ "$ARCH" = "arm64" ] ; then
		# arm63 was only build since 2016-12-23
		WHERE2_EXTRA="WHERE s.datum >= '2016-12-23'"
	else
		WHERE2_EXTRA=""
	fi
	if [ $1 -eq 3 ] || [ $1 -eq 4 ] || [ $1 -eq 5 ] || [ $1 -eq 8 ] ; then
		# TABLE[3+4+5] don't have a suite column: (and TABLE[8] (and 9) is faked, based on 3)
		WHERE_EXTRA=""
	fi
	if [ $1 -eq 0 ] || [ $1 -eq 2 ] ; then
		# TABLE[0+2] have a architecture column:
		WHERE_EXTRA="$WHERE_EXTRA AND architecture = '$ARCH'"
		if [ "$ARCH" = "armhf" ]  ; then
			if [ $1 -eq 2 ] ; then
				# unstable/armhf was only build since 2015-08-30 (and experimental/armhf since 2015-12-19 and stretch/armhf since 2016-01-01)
				WHERE_EXTRA="$WHERE_EXTRA AND datum >= '2015-08-30'"
			fi
		elif [ "$ARCH" = "i386" ]  ; then
			if [ $1 -eq 2 ] ; then
				# i386 was only build since 2016-03-28
				WHERE_EXTRA="$WHERE_EXTRA AND datum >= '2016-03-28'"
			fi
		elif [ "$ARCH" = "arm64" ]  ; then
			if [ $1 -eq 2 ] ; then
				# arm64 was only build since 2016-12-23
				WHERE_EXTRA="$WHERE_EXTRA AND datum >= '2016-12-23'"
			fi
		fi
		# stretch/amd64 was only build since...
		# WHERE2_EXTRA="WHERE s.datum >= '2015-03-08'"
		# experimental/amd64 was only build since...
		# WHERE2_EXTRA="WHERE s.datum >= '2015-02-28'"
	fi
	# run query
	if [ $1 -eq 1 ] ; then
		# not sure if it's worth to generate the following query...
		WHERE_EXTRA="AND architecture='$ARCH'"

		# This query becomes much more obnoxious when gaining
		# compatibility with postgres
		query_to_csv "SELECT stats.datum,
			 COALESCE(reproducible_stretch,0) AS reproducible_stretch,
			 COALESCE(reproducible_buster,0) AS reproducible_buster,
			 COALESCE(reproducible_unstable,0) AS reproducible_unstable,
			 COALESCE(reproducible_experimental,0) AS reproducible_experimental,
			 COALESCE(unreproducible_stretch,0) AS unreproducible_stretch,
			 COALESCE(unreproducible_buster,0) AS unreproducible_buster,
			 COALESCE(unreproducible_unstable,0) AS unreproducible_unstable,
			 COALESCE(unreproducible_experimental,0) AS unreproducible_experimental,
			 COALESCE(FTBFS_stretch,0) AS FTBFS_stretch,
			 COALESCE(FTBFS_buster,0) AS FTBFS_buster,
			 COALESCE(FTBFS_unstable,0) AS FTBFS_unstable,
			 COALESCE(FTBFS_experimental,0) AS FTBFS_experimental,
			 COALESCE(other_stretch,0) AS other_stretch,
			 COALESCE(other_buster,0) AS other_buster,
			 COALESCE(other_unstable,0) AS other_unstable,
			 COALESCE(other_experimental,0) AS other_experimental
			FROM (SELECT s.datum,
			 COALESCE((SELECT e.reproducible FROM stats_builds_per_day AS e WHERE s.datum=e.datum AND suite='stretch' $WHERE_EXTRA),0) AS reproducible_stretch,
			 COALESCE((SELECT e.reproducible FROM stats_builds_per_day AS e WHERE s.datum=e.datum AND suite='buster' $WHERE_EXTRA),0) AS reproducible_buster,
			 COALESCE((SELECT e.reproducible FROM stats_builds_per_day AS e WHERE s.datum=e.datum AND suite='unstable' $WHERE_EXTRA),0) AS reproducible_unstable,
			 COALESCE((SELECT e.reproducible FROM stats_builds_per_day AS e WHERE s.datum=e.datum AND suite='experimental' $WHERE_EXTRA),0) AS reproducible_experimental,
			 (SELECT e.unreproducible FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='stretch' $WHERE_EXTRA) AS unreproducible_stretch,
			 (SELECT e.unreproducible FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='buster' $WHERE_EXTRA) AS unreproducible_buster,
			 (SELECT e.unreproducible FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='unstable' $WHERE_EXTRA) AS unreproducible_unstable,
			 (SELECT e.unreproducible FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='experimental' $WHERE_EXTRA) AS unreproducible_experimental,
			 (SELECT e.FTBFS FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='stretch' $WHERE_EXTRA) AS FTBFS_stretch,
			 (SELECT e.FTBFS FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='buster' $WHERE_EXTRA) AS FTBFS_buster,
			 (SELECT e.FTBFS FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='unstable' $WHERE_EXTRA) AS FTBFS_unstable,
			 (SELECT e.FTBFS FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='experimental' $WHERE_EXTRA) AS FTBFS_experimental,
			 (SELECT e.other FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='stretch' $WHERE_EXTRA) AS other_stretch,
			 (SELECT e.other FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='buster' $WHERE_EXTRA) AS other_buster,
			 (SELECT e.other FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='unstable' $WHERE_EXTRA) AS other_unstable,
			 (SELECT e.other FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='experimental' $WHERE_EXTRA) AS other_experimental
			 FROM stats_builds_per_day AS s $WHERE2_EXTRA GROUP BY s.datum) as stats
			ORDER BY datum" >> ${TABLE[$1]}.csv
	elif [ $1 -eq 2 ] ; then
		# just make a graph of the oldest reproducible build (ignore FTBFS and unreproducible)
		query_to_csv "SELECT datum, oldest_reproducible FROM ${TABLE[$1]} ${WHERE_EXTRA} ORDER BY datum" >> ${TABLE[$1]}.csv
	elif [ $1 -eq 7 ] ; then
		query_to_csv "SELECT datum, $SUM_DONE, $SUM_OPEN from ${TABLE[3]} ORDER BY datum" >> ${TABLE[$1]}.csv
	elif [ $1 -eq 8 ] ; then
		query_to_csv "SELECT ${FIELDS[$1]} from ${TABLE[3]} ${WHERE_EXTRA} ORDER BY datum" >> ${TABLE[$1]}.csv
	elif [ $1 -eq 9 ] ; then
		query_to_csv "SELECT datum, $REPRODUCIBLE_DONE, $REPRODUCIBLE_OPEN from ${TABLE[3]} ORDER BY datum" >> ${TABLE[$1]}.csv
	else
		query_to_csv "SELECT ${FIELDS[$1]} from ${TABLE[$1]} ${WHERE_EXTRA} ORDER BY datum" >> ${TABLE[$1]}.csv
	fi
	# this is a gross hack: normally we take the number of colors a table should have...
	#  for the builds_age table we only want one color, but different ones, so this hack:
	COLORS=${COLOR[$1]}
	if [ $1 -eq 2 ] ; then
		case "$SUITE" in
			stretch)	COLORS=40 ;;
			buster)		COLORS=41 ;;
			unstable)	COLORS=42 ;;
			experimental)	COLORS=43 ;;
		esac
	fi
	local WIDTH=1920
	local HEIGHT=960
	# only generate graph if the query returned data
	if [ $(cat ${TABLE[$1]}.csv | wc -l) -gt 1 ] ; then
		echo "Updating $2..."
		DIR=$(dirname $2)
		mkdir -p $DIR
		echo "Generating $2."
		/srv/jenkins/bin/make_graph.py ${TABLE[$1]}.csv $2 ${COLORS} "${MAINLABEL[$1]}" "${YLABEL[$1]}" $WIDTH $HEIGHT
		mv $2 $DEBIAN_BASE/$DIR
		[ "$DIR" = "." ] || rmdir $(dirname $2)
	# create empty dummy png if there havent been any results ever
	elif [ ! -f $DEBIAN_BASE/$DIR/$(basename $2) ] ; then
		DIR=$(dirname $2)
		mkdir -p $DIR
		echo "Creating $2 dummy."
		convert -size 1920x960 xc:#aaaaaa -depth 8 $2
		mv $2 $DEBIAN_BASE/$DIR
		[ "$DIR" = "." ] || rmdir $(dirname $2)
	fi
	rm ${TABLE[$1]}.csv
}

