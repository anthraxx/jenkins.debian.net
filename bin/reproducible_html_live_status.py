#!/usr/bin/python3
# -*- coding: utf-8 -*-
#
# Copyright © 2015 Holger Levsen <holger@layer-acht.org>
# based on ~jenkins.d.n:~mattia/status.sh by Mattia Rizzolo <mattia@mapreri.org>
# Licensed under GPL-2
#
# Depends: python3
#

from reproducible_common import *
from reproducible_html_indexes import build_leading_text_section

def generate_schedule(arch):
    """ the schedule pages are very different than others index pages """
    log.info('Building the schedule index page for ' + arch + '...')
    title = 'Packages currently scheduled on ' + arch + ' for testing for build reproducibility'
    query = 'SELECT sch.date_scheduled, s.suite, s.architecture, s.name ' + \
            'FROM schedule AS sch JOIN sources AS s ON sch.package_id=s.id ' + \
            'WHERE sch.date_build_started = "" AND s.architecture="{arch}" ORDER BY sch.date_scheduled'
    text = Template('$tot packages are currently scheduled for testing on $arch:')
    html = ''
    rows = query_db(query.format(arch=arch))
    html += build_leading_text_section({'text': text}, rows, defaultsuite, arch)
    html += generate_live_status_table(arch)
    html += '<p><table class="scheduled">\n' + tab
    html += '<tr><th>#</th><th>scheduled at</th><th>suite</th>'
    html += '<th>architecture</th><th>source package</th></tr>\n'
    for row in rows:
        # 0: date_scheduled, 1: suite, 2: arch, 3: pkg name
        pkg = row[3]
        html += tab + '<tr><td>&nbsp;</td><td>' + row[0] + '</td>'
        html += '<td>' + row[1] + '</td><td>' + row[2] + '</td><td><code>'
        html += link_package(pkg, row[1], row[2])
        html += '</code></td></tr>\n'
    html += '</table></p>\n'
    destfile = BASE + '/index_' + arch + '_scheduled.html'
    desturl = REPRODUCIBLE_URL + '/index_' + arch + '_scheduled.html'
    write_html_page(title=title, body=html, destfile=destfile, arch=arch)
    log.info("Page generated at " + desturl)


def generate_live_status_table(arch):
    query = 'SELECT s.id, s.suite, s.architecture, s.name, s.version, ' + \
            'p.scheduler, p.date_build_started, ' + \
            'r.status, r.build_duration, p.builder, p.notify ' + \
            'FROM sources AS s JOIN schedule AS p ON p.package_id=s.id LEFT JOIN results AS r ON s.id=r.package_id ' + \
            'WHERE (p.date_build_started != "" OR p.notify != "") AND s.architecture="{arch}" ' + \
            'ORDER BY p.date_build_started DESC'
    html = ''
    rows = query_db(query.format(arch=arch))
    html += '<p><table class="scheduled">\n' + tab
    html += '<tr><th>#</th><th>src pkg id</th><th>suite</th><th>arch</th>'
    html += '<th>name</th><th>version</th></th><th>scheduled by</th>'
    html += '<th>build started</th><th>previous build status</th>'
    html += '<th>previous build duration</th><th>builder job</th><th>notify</th>'
    html += '</tr>\n'
    counter = 0
    for row in rows:
        counter += 1
        # the numbers 16 and 7 should really be derived from /var/lib/jenkins/jobs/reproducible_builder_${arch}_* instead of being hard-coded here...
        if ( arch == 'amd64' and counter == 16 ) or ( arch == 'armhf' and counter == 7 ):
             html += '<tr><td colspan="12">There are more builds marked as currently building in the database than there are ' + arch + ' build jobs. This does not compute. Please cleanup and please automate cleanup.</td></tr>'
        suite = row[1]
        arch = row[2]
        pkg = row[3]
        html += tab + '<tr><td>&nbsp;</td><td>' + str(row[0]) + '</td>'
        html += '<td>' + suite + '</td><td>' + arch + '</td>'
        html += '<td><code>' + link_package(pkg, suite, arch) + '</code></td>'
        html += '<td>' + str(row[4]) + '</td><td>' + str(row[5]) + '</td><td>' + str(row[6]) + '</td>'
        html += '<td>' + str(row[7]) + '</td><td>' + str(row[8]) + '</td> '
        html += '<td><a href="https://jenkins.debian.net/job/reproducible_builder_' + str(row[9]) + '/console">' + str(row[9]) + '</a></td><td>' + str(row[10]) + '</td>'
        html += '</tr>\n'
    html += '</table></p>\n'
    return html

if __name__ == '__main__':
    for arch in ARCHS:
        generate_schedule(arch)

