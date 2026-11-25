# Dockerfile for OpenLogReplicator
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
# OpenLogReplicator Dockerfile
# --------------------------
# This is the Dockerfile for OpenLogReplicator
#
# HOW TO BUILD THIS IMAGE
# -----------------------
# Put all downloaded files in the same directory as this Dockerfile
# Run:
#       $ docker build -t bersler/openlogreplicator:debian-12.0 -f Dockerfile --build-arg IMAGE=debian --build-arg VERSION=12.0 --build-arg GIDOLR=${GIDOLR} --build-arg UIDOLR=${UIDOLR} --build-arg GIDORA=${GIDORA} --build-arg WITHORACLE=1 --build-arg WITHKAFKA=1 --build-arg WITHPROTOBUF=1 --build-arg BUILD_TYPE=Release .
#       $ docker build -t bersler/openlogreplicator:debian-13.0 -f Dockerfile --build-arg IMAGE=debian --build-arg VERSION=13.0 --build-arg GIDOLR=${GIDOLR} --build-arg UIDOLR=${UIDOLR} --build-arg GIDORA=${GIDORA} --build-arg WITHORACLE=1 --build-arg WITHKAFKA=1 --build-arg WITHPROTOBUF=1 --build-arg BUILD_TYPE=Release .
#       $ docker build -t bersler/openlogreplicator:ubuntu-22.04 -f Dockerfile --build-arg IMAGE=ubuntu --build-arg VERSION=22.04 --build-arg GIDOLR=${GIDOLR} --build-arg UIDOLR=${UIDOLR} --build-arg GIDORA=${GIDORA} --build-arg WITHORACLE=1 --build-arg WITHKAFKA=1 --build-arg WITHPROTOBUF=1 --build-arg BUILD_TYPE=Release .
#

ARG BASE_IMAGE=ghcr.io/tarantool/openlogreplicator-base:latest
ARG ORACLE_CLIENT19_VERSION=19.28.0.0.0dbru

# Oracle Instant Client 19 (CentOS 7 only) is unpacked in a throwaway stage so
# that the archives from the build context never end up in a layer of the
# image. Multi-stage keeps this working with the classic builder.
FROM ${BASE_IMAGE} AS oracle19
ARG ORACLE_CLIENT19_VERSION
COPY oracle-instantclient/ /tmp/oracle-instantclient/
RUN set -eu; \
    mkdir /oracle19; \
    if [ -r /etc/centos-release ]; then \
        major=${ORACLE_CLIENT19_VERSION%%.*}; \
        minor=${ORACLE_CLIENT19_VERSION#*.}; minor=${minor%%.*}; \
        cd /oracle19; \
        unzip -o /tmp/oracle-instantclient/instantclient-basic-linux.x64-${ORACLE_CLIENT19_VERSION}.zip; \
        rm -rf META-INF; \
        unzip -o /tmp/oracle-instantclient/instantclient-sdk-linux.x64-${ORACLE_CLIENT19_VERSION}.zip; \
        rm -rf META-INF; \
        cd /oracle19/instantclient_${major}_${minor}; \
        ln -s libclntsh.so.${major}.1 libclntsh.so.23.1; \
        ln -s libclntsh.so.${major}.1 libclntshcore.so.23.1; \
        ln -s libclntshcore.so.23.1 libclntshcore.so; \
        ln -s libnnz${major}.so libnnz.so; \
        ln -s /opt/instantclient_${major}_${minor} /oracle19/instantclient_23_26; \
    fi

FROM ${BASE_IMAGE} AS builder

ARG ORACLE_MAJOR=23
ARG ORACLE_MINOR=26
ARG ORACLE_CLIENT19_VERSION
ARG OPENLOGREPLICATOR_VERSION=2.0.0
ARG ARCH=x86_64
ARG NEXUS_REPOSITORY_URL=
ARG GIDOLR=1001
ARG UIDOLR=1001
ARG GIDORA=54322
ARG BUILD_TYPE=Debug
ARG WITHKAFKA=1
ARG WITHPROMETHEUS=1
ARG WITHORACLE=1
ARG WITHPROTOBUF=1
ARG WITHTESTS

LABEL org.opencontainers.image.authors="Adam Leszczynski <aleszczynski@bersler.com>"

ENV OPENLOGREPLICATOR_VERSION=${OPENLOGREPLICATOR_VERSION}
ENV BUILDARGS="-DCMAKE_BUILD_TYPE=${BUILD_TYPE} -DWITH_RAPIDJSON=/opt/rapidjson -S ../ -B ./"
ENV BUILDARGS="${BUILDARGS}${WITHKAFKA:+ -DWITH_RDKAFKA=/opt/librdkafka}"
ENV BUILDARGS="${BUILDARGS}${WITHPROMETHEUS:+ -DWITH_PROMETHEUS=/opt/prometheus}"
ENV BUILDARGS="${BUILDARGS}${WITHORACLE:+ -DWITH_OCI=/opt/instantclient_${ORACLE_MAJOR}_${ORACLE_MINOR}}"
ENV BUILDARGS="${BUILDARGS}${WITHPROTOBUF:+ -DWITH_PROTOBUF=/opt/protobuf}"
ENV COMPILEKAFKA="${WITHKAFKA:+1}"
ENV COMPILEPROMETHEUS="${WITHPROMETHEUS:+1}"
ENV COMPILEORACLE="${WITHORACLE:+1}"
ENV COMPILEPROTOBUF="${WITHPROTOBUF:+1}"

# Установка devtoolset-9 для C++17 на CentOS 7 (yum-репозитории — прокси Nexus,
# если задан NEXUS_REPOSITORY_URL, иначе публичный vault)
COPY configure-mirrors.sh /usr/local/bin/configure-mirrors.sh
RUN set -eu; \
    configure-mirrors.sh "${NEXUS_REPOSITORY_URL}"; \
    if [ -r /etc/centos-release ]; then \
        yum -y install devtoolset-9-gcc devtoolset-9-gcc-c++ devtoolset-9-libasan-devel devtoolset-9-libubsan-devel; \
    fi

# Установка Oracle Instant Client 19 для CentOS 7 (совместим с glibc 2.17):
# версия ORACLE_CLIENT19_VERSION из контекста сборки (./fetch-oracle-instantclient.sh)
# заменяет 23.26 из базового образа
RUN if [ -r /etc/centos-release ]; then rm -rf /opt/instantclient_*; fi
COPY --from=oracle19 /oracle19/ /opt/

# Копируем исходники из контекста сборки (должны быть подготовлены заранее)
COPY OpenLogReplicator /opt/OpenLogReplicator-${OPENLOGREPLICATOR_VERSION}

# 1. Генерация protobuf (если нужно)
RUN set -eu; \
    if [ "${COMPILEPROTOBUF}" != "" ]; then \
        cd /opt/OpenLogReplicator-${OPENLOGREPLICATOR_VERSION}/proto; \
        /opt/protobuf/bin/protoc OraProtoBuf.proto --cpp_out=.; \
        mv OraProtoBuf.pb.cc ../src/common/OraProtoBuf.pb.cpp; \
        mv OraProtoBuf.pb.h ../src/common/OraProtoBuf.pb.h; \
    fi

# 2. Сборка OpenLogReplicator
RUN set -eu; \
    if [ -r /etc/centos-release ]; then export MANPATH=""; source /opt/rh/devtoolset-9/enable; fi; \
    cd /opt/OpenLogReplicator-${OPENLOGREPLICATOR_VERSION}; \
    mkdir cmake-build-${BUILD_TYPE}-${ARCH}; \
    cd cmake-build-${BUILD_TYPE}-${ARCH}; \
    if [ -r /etc/centos-release ]; then \
        cmake ${BUILDARGS} -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++"; \
    else \
        cmake ${BUILDARGS}; \
    fi; \
    cmake --build ./ --target OpenLogReplicator -j

# 3. Копирование и подготовка директорий
RUN set -eu; \
    mkdir -p /opt/OpenLogReplicator/log /opt/OpenLogReplicator/tmp /opt/OpenLogReplicator/scripts /home/user1; \
    mv /opt/OpenLogReplicator-${OPENLOGREPLICATOR_VERSION}/cmake-build-${BUILD_TYPE}-${ARCH}/OpenLogReplicator /opt/OpenLogReplicator; \
    cp -p /opt/OpenLogReplicator-${OPENLOGREPLICATOR_VERSION}/scripts/gencfg.sql /opt/OpenLogReplicator/scripts/gencfg.sql; \
    if [ "${WITHTESTS:-}" != "" ]; then \
        # OLR Makefile (make test, generate.sh) references /opt/OpenLogReplicator-local —
        # symlink the version-stamped source dir so paths resolve regardless of OLR_VERSION.
        ln -sf /opt/OpenLogReplicator-${OPENLOGREPLICATOR_VERSION} /opt/OpenLogReplicator-local; \
    fi

# 3a. Tooling for the test image: docker CLI + compose plugin + python3.
#     Skipped entirely when WITHTESTS is empty (dev/prod images stay slim).
#     The pinned docker packages come from the Docker APT repository (its
#     Nexus proxy when NEXUS_REPOSITORY_URL is set). The repository has no
#     26.1.4/2.27.0 builds for trixie, so the bookworm packages are used: the
#     CLI and the plugin are static Go binaries.
ARG DOCKER_CLI_VERSION=26.1.4
ARG DOCKER_COMPOSE_VERSION=2.27.0
ARG DOCKER_DEB_SUITE=bookworm
ARG DOCKER_DEB_RELEASE=debian.12~bookworm
RUN set -eu; \
    if [ "${WITHTESTS:-}" != "" ]; then \
        cd /tmp; \
        docker_apt="${NEXUS_REPOSITORY_URL:+${NEXUS_REPOSITORY_URL}/apt-docker-debian-remote}"; \
        docker_apt="${docker_apt:-https://download.docker.com/linux/debian}"; \
        pool="${docker_apt}/dists/${DOCKER_DEB_SUITE}/pool/stable/amd64"; \
        cli_deb="docker-ce-cli_${DOCKER_CLI_VERSION}-1~${DOCKER_DEB_RELEASE}_amd64.deb"; \
        compose_deb="docker-compose-plugin_${DOCKER_COMPOSE_VERSION}-1~${DOCKER_DEB_RELEASE}_amd64.deb"; \
        wget -q "${pool}/${cli_deb}" "${pool}/${compose_deb}"; \
        apt-get update; \
        apt-get -y install "./${cli_deb}" "./${compose_deb}" python3; \
        rm -f "${cli_deb}" "${compose_deb}"; \
        rm -rf /var/lib/apt/lists/*; \
        docker --version; \
        docker compose version; \
    fi

# 4. Создание пользователей и групп
RUN chown -R ${UIDOLR}:${GIDOLR} /home/user1 /opt/OpenLogReplicator; \
    if [ "${WITHTESTS:-}" != "" ]; then \
        chown -R ${UIDOLR}:${GIDOLR} /opt/OpenLogReplicator-${OPENLOGREPLICATOR_VERSION}; \
    fi

# 5. Очистка (только для prod-Release сборки без WITHTESTS)
RUN set -eu; \
    if [ "${BUILD_TYPE}" != "Debug" ] && [ "${WITHTESTS:-}" = "" ]; then \
        rm -rf /opt/OpenLogReplicator-${OPENLOGREPLICATOR_VERSION} /opt/rapidjson /opt/rapidjson-${RAPIDJSON_VERSION}; \
        if [ "${COMPILEKAFKA}" != "" ]; then rm -rf /opt/librdkafka-${LIBRDKAFKA_VERSION}; fi; \
        if [ "${COMPILEPROTOBUF}" != "" ]; then rm -rf /opt/protobuf-${PROTOBUF_VERSION}; fi; \
        if [ "${COMPILEPROMETHEUS}" != "" ]; then rm -rf /opt/prometheus-cpp-with-submodules; fi; \
        if [ -r /etc/centos-release ]; then \
            yum -y remove autoconf automake file gcc gcc-c++ libaio-devel libtool make patch unzip wget zlib-devel git; \
            yum -y autoremove; \
            yum clean all; \
            rm -rf /var/cache/yum; \
        fi; \
        if [ -r /etc/debian_version ]; then \
            apt-get -y remove file gcc g++ libtool libz-dev make unzip wget git; \
            apt-get -y autoremove; \
            apt-get clean; \
            rm -rf /var/lib/apt/lists/*; \
        fi; \
    fi

RUN set -eu ; \
    if [ -r /etc/centos-release ]; then export MANPATH=""; source /opt/rh/devtoolset-9/enable; fi; \
    if [ -r /etc/centos-release ]; then \
        export ORACLE_MAJOR=${ORACLE_CLIENT19_VERSION%%.*}; \
        ORACLE_MINOR=${ORACLE_CLIENT19_VERSION#*.}; export ORACLE_MINOR=${ORACLE_MINOR%%.*}; \
    fi; \
    export LD_LIBRARY_PATH=/opt/instantclient_${ORACLE_MAJOR}_${ORACLE_MINOR}:/opt/librdkafka/lib:/opt/prometheus/lib:/opt/protobuf/lib ; \
    /opt/OpenLogReplicator/OpenLogReplicator --version

# The package manager must not keep pointing to the build-time Nexus
RUN configure-mirrors.sh --public

ARG OLR_USER=user1:oracle
USER ${OLR_USER}

WORKDIR /opt/OpenLogReplicator
ENTRYPOINT ["/opt/run.sh"]
