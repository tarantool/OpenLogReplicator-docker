#!/bin/sh
# Point the package manager of a build image to the dependency mirrors
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
# Usage: configure-mirrors.sh [NEXUS_REPOSITORY_URL | --public]
#
# --public points the package manager back to the public upstreams. Run it as
# the last step of an image build, so that the image does not keep the Nexus
# URL in its package manager configuration. Layers created earlier in the build
# still contain the Nexus configuration.
#
# NEXUS_REPOSITORY_URL is the base URL of a Nexus instance, for example
# https://nexus.example.com/repository. When it is empty, public upstreams
# are used.
#
# Debian: with Nexus, rewrites deb.debian.org in the APT sources to the Nexus
# APT proxies and installs ca-certificates when the image has no CA bundle
# yet. Without Nexus, the APT sources are left unchanged.
# CentOS 7: replaces all yum repositories with the CentOS vault and the EPEL
# archive, through the Nexus yum proxies when Nexus is set. The SCLo and EPEL
# repositories are added once their release packages have installed the GPG
# keys, so run the script again after installing centos-release-scl and
# epel-release. The script is idempotent.

set -eu

ETC=${MIRRORS_ETC:-/etc}
VAR=${MIRRORS_VAR:-/var}
public=
if [ "${1:-}" = "--public" ]; then
    public=1
    NEXUS_REPOSITORY_URL=
else
    NEXUS_REPOSITORY_URL=${1:-${NEXUS_REPOSITORY_URL:-}}
    NEXUS_REPOSITORY_URL=${NEXUS_REPOSITORY_URL%/}
fi
CENTOS_VAULT_RELEASE=7.9.2009

configure_debian() {
    if [ -n "$public" ]; then
        for sources in "${ETC}/apt/sources.list" "${ETC}/apt/sources.list.d/debian.sources"; do
            [ -f "$sources" ] || continue
            sed -i \
                -e 's|[^[:space:]]*/apt-debian-security-remote|https://deb.debian.org/debian-security|g' \
                -e 's|[^[:space:]]*/apt-debian-remote|https://deb.debian.org/debian|g' \
                "$sources"
        done
        rm -f "${ETC}/apt/apt.conf.d/99nexus-timeout"
        rm -rf "${VAR}"/lib/apt/lists/*
        return 0
    fi
    [ -n "$NEXUS_REPOSITORY_URL" ] || return 0
    # The URL is a sed replacement: escape \, & and the | delimiter
    nexus_sed=$(printf '%s' "$NEXUS_REPOSITORY_URL" | sed 's/[\\&|]/\\&/g')
    for sources in "${ETC}/apt/sources.list" "${ETC}/apt/sources.list.d/debian.sources"; do
        [ -f "$sources" ] || continue
        sed -i \
            -e "s|https\{0,1\}://deb\.debian\.org/debian-security|${nexus_sed}/apt-debian-security-remote|g" \
            -e "s|https\{0,1\}://security\.debian\.org/debian-security|${nexus_sed}/apt-debian-security-remote|g" \
            -e "s|https\{0,1\}://deb\.debian\.org/debian|${nexus_sed}/apt-debian-remote|g" \
            "$sources"
    done
    if grep -rqsE 'deb\.debian\.org|security\.debian\.org' "${ETC}/apt/sources.list" "${ETC}/apt/sources.list.d"; then
        echo "configure-mirrors.sh: APT sources still reference public Debian mirrors" >&2
        exit 1
    fi
    # Nexus answers only after it has fetched an uncached file from the upstream.
    printf '%s\n' 'Acquire::https::Timeout "600";' > "${ETC}/apt/apt.conf.d/99nexus-timeout"

    # The Debian image ships without a CA bundle, so the first HTTPS request to
    # Nexus cannot verify the server certificate. Only this bootstrap step skips
    # TLS peer verification; APT still verifies the signed InRelease files and
    # package checksums against the Debian archive keyring.
    if [ ! -s "${ETC}/ssl/certs/ca-certificates.crt" ]; then
        apt-get -o Acquire::https::Verify-Peer=false update
        apt-get -o Acquire::https::Verify-Peer=false -y install --no-install-recommends ca-certificates
    fi
}

write_yum_repo() {
    # $1 - repository id, $2 - name, $3 - baseurl, $4 - gpg key file
    # Nexus sends nothing until it has fetched an uncached package from the
    # upstream, so the default 30 s stall timeout is too short for large RPMs.
    printf '%s\n' \
        "[$1]" \
        "name=$2" \
        "baseurl=$3" \
        "enabled=1" \
        "gpgcheck=1" \
        "gpgkey=file://$4" \
        "timeout=600" \
        ""
}

configure_centos() {
    if [ -n "$NEXUS_REPOSITORY_URL" ]; then
        vault="${NEXUS_REPOSITORY_URL}/yum-centos-vault-remote"
        epel="${NEXUS_REPOSITORY_URL}/yum-epel-archive-remote"
    else
        vault="https://vault.centos.org"
        epel="https://archives.fedoraproject.org/pub/archive/epel"
    fi
    vault="${vault}/${CENTOS_VAULT_RELEASE}"
    centos_key="${ETC}/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7"
    sclo_key="${ETC}/pki/rpm-gpg/RPM-GPG-KEY-CentOS-SIG-SCLo"
    epel_key="${ETC}/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7"
    repo="${ETC}/yum.repos.d/mirrors.repo"

    rm -f "${ETC}"/yum.repos.d/*.repo
    {
        write_yum_repo base "CentOS ${CENTOS_VAULT_RELEASE} - Base" "${vault}/os/\$basearch/" "$centos_key"
        write_yum_repo updates "CentOS ${CENTOS_VAULT_RELEASE} - Updates" "${vault}/updates/\$basearch/" "$centos_key"
        write_yum_repo extras "CentOS ${CENTOS_VAULT_RELEASE} - Extras" "${vault}/extras/\$basearch/" "$centos_key"
        if [ -r "$sclo_key" ]; then
            write_yum_repo centos-sclo-rh "CentOS ${CENTOS_VAULT_RELEASE} - SCLo rh" "${vault}/sclo/\$basearch/rh/" "$sclo_key"
        fi
        if [ -r "$epel_key" ]; then
            write_yum_repo epel "EPEL 7 (archive)" "${epel}/7/\$basearch/" "$epel_key"
        fi
    } > "$repo"
    yum clean all >/dev/null
}

if [ -r "${ETC}/centos-release" ]; then
    configure_centos
elif [ -r "${ETC}/debian_version" ]; then
    configure_debian
else
    echo "configure-mirrors.sh: unsupported distribution" >&2
    exit 1
fi
