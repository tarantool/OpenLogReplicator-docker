#!/bin/sh
# Script to build Docker images
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

USER=`whoami`
GIDOLR=${GIDOLR:=`id -r -g ${USER}`}
UIDOLR=${UIDOLR:=`id -r -u ${USER}`}
GIDORA=${GIDORA:=54322}
OLR_BRANCH=${OLR_BRANCH:=2.0.0}

if [ -n "${OLR_REPO_URL:-}" ]; then
    : # explicit override
elif [ -n "${CI_JOB_TOKEN:-}" ]; then
    if [ -z "${OLR_INTERNAL_REPO_URL:-}" ]; then
        echo "OLR_INTERNAL_REPO_URL must be set when CI_JOB_TOKEN is set" >&2
        exit 1
    fi
    OLR_REPO_URL=${OLR_INTERNAL_REPO_URL}
else
    OLR_REPO_URL="https://github.com/tarantool/openlogreplicator.git"
fi

# Nexus repository base URL for the dependency mirrors (see README). Empty
# means public upstreams. CI derives it from NEXUS_URL and must not fall back.
if [ -z "${NEXUS_REPOSITORY_URL:-}" ] && [ -n "${CI_JOB_TOKEN:-}" ]; then
    . "$(dirname "$0")/nexus-repository-url.sh"
fi

# Clone OpenLogReplicator if not exists
if [ ! -d "OpenLogReplicator/.git" ]; then
    echo "Cloning OpenLogReplicator repository..."
    git clone "${OLR_REPO_URL}" OpenLogReplicator
fi

# Checkout the specified branch and get version info
cd OpenLogReplicator
git fetch origin
git checkout "${OLR_BRANCH}" 2>/dev/null || git checkout -b "${OLR_BRANCH}" "origin/${OLR_BRANCH}"
git pull origin "${OLR_BRANCH}"

# Get version info from git describe: v1.9.0-13-gb586ac8 -> 1.9.0-13-b586ac8
GIT_DESCRIBE=$(git describe --tags --long 2>/dev/null | sed 's/^v//' | sed 's/-g/-/')
if [ -z "$GIT_DESCRIBE" ]; then
    echo "Failed to get git describe info"
    exit 1
fi

cd ..

# Build image tag: 1.9.0-13-b586ac8
REGISTRY_PATH=${REGISTRY_PATH:-${CI_REGISTRY_IMAGE:-ghcr.io/tarantool}}
IMAGE_NAME=${DOCKER_IMAGE_NAME:-openlogreplicator}
OLR_IMAGE=${OLR_IMAGE:=${REGISTRY_PATH}/${IMAGE_NAME}:${GIT_DESCRIBE}}

if [ "$GIDOLR" -eq "0" ] || [ "$UIDOLR" -eq "0" ]; then
    echo "Failed, you are not allowed to run OpenLogReplicator as root"
    exit 1
fi

# Optional build args are collected as positional parameters so their values
# (notably NEXUS_REPOSITORY_URL) are never word-split or glob-expanded.
set --
if [ -n "${OPENLOGREPLICATOR_VERSION:-}" ]; then
    set -- "$@" --build-arg "OPENLOGREPLICATOR_VERSION=${OPENLOGREPLICATOR_VERSION}"
fi

if [ -n "${NEXUS_REPOSITORY_URL:-}" ]; then
    set -- "$@" --build-arg "NEXUS_REPOSITORY_URL=${NEXUS_REPOSITORY_URL}"
fi

if [ -n "${ORACLE_CLIENT19_VERSION:-}" ]; then
    set -- "$@" --build-arg "ORACLE_CLIENT19_VERSION=${ORACLE_CLIENT19_VERSION}"
fi

echo "Building image: ${OLR_IMAGE}"

if [ -z "${BASE_IMAGE_NAME:-}" ]; then
    if [ -n "${CI_REGISTRY_IMAGE:-}" ]; then
        BASE_IMAGE_NAME="${CI_REGISTRY_IMAGE}/${IMAGE_NAME}-base:latest"
    else
        BASE_IMAGE_NAME="ghcr.io/tarantool/openlogreplicator-base:latest"
    fi
fi

docker build \
-t ${OLR_IMAGE} \
-f Dockerfile \
"$@" \
--no-cache \
--build-arg BASE_IMAGE=${BASE_IMAGE_NAME} \
--build-arg GIDOLR=${GIDOLR} \
--build-arg UIDOLR=${UIDOLR} \
--build-arg GIDORA=${GIDORA} \
--build-arg WITHORACLE=1 \
--build-arg WITHKAFKA=1 \
--build-arg WITHPROMETHEUS=1 \
--build-arg WITHPROTOBUF=1 \
--build-arg BUILD_TYPE=Release \
--build-arg OPENLOGREPLICATOR_VERSION="${OLR_BRANCH}" .
