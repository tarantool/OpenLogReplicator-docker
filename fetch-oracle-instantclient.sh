#!/bin/sh
# Download Oracle Instant Client archives into the build context
# Copyright (C) 2018-2026 Adam Leszczynski (aleszczynski@bersler.com)
#
# This file is part of OpenLogReplicator
#
# This program is free software: you can redistribute it and/or
# modify it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License along with this program; see the file LICENSE;
# If not, see <http://www.gnu.org/licenses/>.
#
# Usage: fetch-oracle-instantclient.sh VERSION...
#
# VERSION is the full archive version, for example 23.26.0.0.0 or
# 19.28.0.0.0dbru. For each version the script downloads the basic and sdk
# Linux x64 archives into oracle-instantclient/. The Nexus layout mirrors
# download.oracle.com:
#
#   ${NEXUS_URL}/otn_software/linux/instantclient/<MAJOR><MINOR>000/
#       instantclient-{basic,sdk}-linux.x64-<VERSION>.zip
#
# NEXUS_URL is the hosted raw repository with the archives. When it is empty,
# the archives are downloaded from download.oracle.com; in GitLab CI
# (CI_JOB_TOKEN set) NEXUS_URL is required. The hosted repository requires
# NEXUS_USER and NEXUS_PASS. The credentials stay in this script and never
# reach the Docker build.

set -eu

NEXUS_URL=${NEXUS_URL:-}
ORACLE_URL=https://download.oracle.com

if [ -z "$NEXUS_URL" ] && [ -n "${CI_JOB_TOKEN:-}" ]; then
    echo "NEXUS_URL must be set when CI_JOB_TOKEN is set" >&2
    exit 1
fi
DEST_DIR=${DEST_DIR:-oracle-instantclient}

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 VERSION..." >&2
    exit 1
fi

# The credentials go to curl through stdin so that they do not show up in the
# process list; backslashes and quotes are escaped for the curl config syntax.
curl_auth() {
    printf 'user = "%s:%s"\n' \
        "$(printf '%s' "$NEXUS_USER" | sed 's/[\\"]/\\&/g')" \
        "$(printf '%s' "$NEXUS_PASS" | sed 's/[\\"]/\\&/g')" |
        curl --config - "$@"
}

mkdir -p "$DEST_DIR"

for version in "$@"; do
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    for package in basic sdk; do
        file="instantclient-${package}-linux.x64-${version}.zip"
        if [ -s "${DEST_DIR}/${file}" ]; then
            echo "Using existing ${DEST_DIR}/${file}"
            continue
        fi
        path="otn_software/linux/instantclient/${major}${minor}000/${file}"
        if [ -n "$NEXUS_URL" ]; then
            : "${NEXUS_USER:?NEXUS_USER must be set}"
            : "${NEXUS_PASS:?NEXUS_PASS must be set}"
            url="${NEXUS_URL%/}/${path}"
            echo "Downloading ${url}"
            curl_auth --fail --location --silent --show-error \
                --output "${DEST_DIR}/${file}.part" \
                "$url"
        else
            url="${ORACLE_URL}/${path}"
            echo "Downloading ${url}"
            curl --fail --location --silent --show-error \
                --output "${DEST_DIR}/${file}.part" \
                "$url"
        fi
        mv "${DEST_DIR}/${file}.part" "${DEST_DIR}/${file}"
    done
done
