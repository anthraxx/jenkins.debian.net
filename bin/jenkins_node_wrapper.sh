#!/usr/bin/env bash

# Copyright (c) 2009, 2010, 2012, 2015 Peter Palfrader
#               2015-2017 Holger Levsen
#               2017      Mattia Rizzolo <mattia@debian.org>
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

set -e
set -u

MYLOGNAME="`basename "$0"`[$$]"

usage() {
	echo "local Usage: $0"
	echo "via ssh orig command:"
	echo "                      <allowed command>"
}

info() {
	echo >&2 "$MYLOGNAME $1"
	echo > ~/jenkins-ssh-wrap.log "$MYLOGNAME $1"
}

croak() {
	echo >&2 "$MYLOGNAME $1"
	echo > ~/jenkins-ssh-wrap.log "$MYLOGNAME $1"
	exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

# check/parse remote command line
if [ -z "${SSH_ORIGINAL_COMMAND:-}" ] ; then
	croak "Did not find SSH_ORIGINAL_COMMAND"
fi
set "dummy" ${SSH_ORIGINAL_COMMAND}
shift

allowed_cmds=()

if [[ "$*" = "/bin/true" ]] ; then
	exec /bin/true ; croak "Exec failed";
elif [[ "$*" = 'rm -v $(mktemp --tmpdir=/tmp read-only-fs-test-XXXXXX)' ]] ; then
	exec rm -v $(mktemp --tmpdir=/tmp read-only-fs-test-XXXXXX) ; croak "Exec failed";
elif [[ "$*" = "cleanup_nodes /srv/jenkins/bin/reproducible_slay.sh" ]] ; then
	exec /srv/jenkins/bin/reproducible_slay.sh ; croak "Exec failed";
elif [[ "$*" =~ ^/bin/nc\ localhost\ 4949 ]] ; then
	exec /bin/nc localhost 4949 ; croak "Exec failed";
elif [[ "$*" =~ ^rebootstrap_.* ]] ; then
	shift
	REBOOTSTRAPSH="/srv/jenkins/bin/rebootstrap.sh $@"
	export LC_ALL=C
	exec $REBOOTSTRAPSH; croak "Exec failed";
elif [ "$*" = "reproducible_html_nodes_info" ] ; then
	exec /srv/jenkins/bin/reproducible_info.sh ; croak "Exec failed";
elif [ "$1" = "/srv/jenkins/bin/reproducible_build.sh" ] && ( [ "$2" = "1" ] || [ "$2" = "2" ] ) ; then
	exec /srv/jenkins/bin/reproducible_build.sh "$2" "$3" "$4" "$5" "$6" ; croak "Exec failed";
elif [[ "$*" =~ ^rsync\ --server\ --sender\ .*\ \.\ /srv/workspace/chroots/.* ]] ; then
	exec rsync --server --sender "$4" . "$6" ; croak "Exec failed";
elif [[ "$*" =~ ^rsync\ --server\ --sender\ .*\ \.\ /srv/reproducible-results/.* ]] ; then
	exec rsync --server --sender "$4" . "$6" ; croak "Exec failed";
elif [[ "$*" =~ ^rsync\ --server\ --sender\ .*\ \.\ /var/lib/jenkins/userContent/reproducible/.* ]] ; then
	exec rsync --server --sender "$4" . "$6" ; croak "Exec failed";
elif [[ "$*" =~ ^rsync\ --server\ --sender\ .*\ \.\ /var/lib/jenkins/jobs/.*/workspace/results/.* ]] ; then
	exec rsync --server --sender "$4" . "$6" ; croak "Exec failed";
elif [[ "$*" =~ ^rsync\ --server\ .*\ \.\ /srv/d-i/isos/ ]] ; then
	exec rsync --server "$3" . "$5" ; croak "Exec failed";
elif [[ "$*" =~ ^rsync\ --server\ .*\ \.\ /srv/workspace/chroots/.* ]] ; then
	# LEDE is using this to share files between master node1 node2.
	exec rsync --server "$3" . "$5" ; croak "Exec failed";
elif [[ "$*" =~ ^rsync\ --server\ .*\ \.\ /srv/reproducible-results/.* ]] ; then
	# allow to push files to /srv/reproducible-results/
	exec rsync --server "$3" . "$5" ; croak "Exec failed";
elif [[ "$*" =~ ^mkdir\ -p\ /srv/d-i/isos.* ]] ; then
	exec mkdir -p "$3"  ; croak "Exec failed";
elif [[ "$*" =~ ^rm\ -r\ /srv/reproducible-results/tmp.* ]] ; then
	exec rm -r "$3" ; croak "Exec failed";
elif [[ "$*" =~ ^rm\ -r\ /srv/reproducible-results/rbuild.* ]] ; then
	exec rm -r "$3" ; croak "Exec failed";
elif [[ "$*" =~ ^rm\ -r\ /srv/reproducible-results/archlinuxrb-build.* ]] ; then
	exec rm -r "$3" ; croak "Exec failed";
elif [[ "$*" =~ ^rm\ -r\ /var/lib/jenkins/jobs/.*/workspace/results ]] ; then
	exec rm -r "$3" ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_pbuilder_buster_.*_.* ]] ; then
	exec /srv/jenkins/bin/reproducible_setup_pbuilder.sh buster ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_pbuilder_unstable_.*_.* ]] ; then
	exec /srv/jenkins/bin/reproducible_setup_pbuilder.sh unstable ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_pbuilder_stretch_.*_.* ]] ; then
	exec /srv/jenkins/bin/reproducible_setup_pbuilder.sh stretch ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_pbuilder_experimental_.*_.* ]] ; then
	exec /srv/jenkins/bin/reproducible_setup_pbuilder.sh experimental ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_maintenance_.*_.* ]] ; then
	exec /srv/jenkins/bin/reproducible_maintenance.sh ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_node_health_check_.*_.* ]] ; then
	exec /srv/jenkins/bin/reproducible_node_health_check.sh ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_schroot_unstable_diffoscope_.*_.* ]] ; then
	exec /srv/jenkins/bin/schroot-create.sh reproducible reproducible-unstable-diffoscope unstable diffoscope locales-all ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_schroot_buster_.*_.* ]] ; then
	exec /srv/jenkins/bin/schroot-create.sh reproducible reproducible-buster buster ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_schroot_unstable_.*_.* ]] ; then
	exec /srv/jenkins/bin/schroot-create.sh reproducible reproducible-unstable unstable botch ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_schroot_stretch_.*_.* ]] ; then
	exec /srv/jenkins/bin/schroot-create.sh reproducible reproducible-stretch stretch ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_schroot_experimental_.*_.* ]] ; then
	exec /srv/jenkins/bin/schroot-create.sh reproducible reproducible-experimental experimental ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_coreboot ]] ; then
	exec /srv/jenkins/bin/reproducible_coreboot.sh ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_openwrt ]] ; then
	shift ; exec /srv/jenkins/bin/reproducible_openwrt.sh $@ ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_lede ]] ; then
	shift ; exec /srv/jenkins/bin/reproducible_lede.sh $@ ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_netbsd ]] ; then
	exec /srv/jenkins/bin/reproducible_netbsd.sh ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_freebsd ]] ; then
	exec /srv/jenkins/bin/reproducible_freebsd.sh ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_schroot_archlinux ]] ; then
	exec /srv/jenkins/bin/reproducible_setup_archlinux_schroot.sh ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_fdroid_build_apps ]] ; then
	exec /srv/jenkins/bin/reproducible_fdroid_build_apps.sh ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_fdroid_test ]] ; then
	exec /srv/jenkins/bin/reproducible_fdroid_test.sh ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_fdroid_build_environment ]] ; then
	exec /srv/jenkins/bin/reproducible_setup_fdroid_build_environment.sh ; croak "Exec failed";
elif [[ "$*" =~ ^reproducible_setup_mock_fedora-23_x86_64 ]] ; then
	exec /srv/jenkins/bin/reproducible_setup_mock.sh fedora-23 x86_64 ; croak "Exec failed";
elif [ "$1" = "/srv/jenkins/bin/reproducible_build_archlinux_pkg.sh" ] && ( [ "$2" = "1" ] || [ "$2" = "2" ] ) ; then
	exec /srv/jenkins/bin/reproducible_build_archlinux_pkg.sh "$2" "$3" "$4" "$5" "$6" ; croak "Exec failed";
elif [ "$1" = "/srv/jenkins/bin/reproducible_build_rpm.sh" ] && ( [ "$2" = "1" ] || [ "$2" = "2" ] ) ; then
	exec /srv/jenkins/bin/reproducible_build_rpm.sh "$2" "$3" "$4" "$5" "$6" "$7" ; croak "Exec failed";
elif [ "$*" = "some_jenkins_job_name" ] ; then
	exec echo run any commands here ; croak "Exec failed";
fi

croak "Command '$*' not found in allowed commands."
