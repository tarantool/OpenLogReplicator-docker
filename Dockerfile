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
FROM ${BASE_IMAGE} AS builder

ARG ORACLE_MAJOR=23
ARG ORACLE_MINOR=26
ARG OPENLOGREPLICATOR_VERSION=2.0.0
ARG ARCH=x86_64
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

# Установка devtoolset-9 для C++17 на CentOS 7
RUN set -eu; \
    if [ -r /etc/centos-release ]; then \
        yum -y install centos-release-scl; \
        sed -i \
            -e 's|^mirrorlist=|#mirrorlist=|g' \
            -e 's|^#baseurl=http://mirror\.centos\.org/centos/7/sclo/\$basearch/rh/|baseurl=http://vault.centos.org/centos/7/sclo/$basearch/rh/|g' \
            /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo; \
        sed -i 's|^enabled=1|enabled=0|g' /etc/yum.repos.d/CentOS-SCLo-scl.repo; \
        yum -y install devtoolset-9-gcc devtoolset-9-gcc-c++ devtoolset-9-libasan-devel devtoolset-9-libubsan-devel; \
    fi

# Установка Oracle Instant Client 19.28 для CentOS 7 (совместим с glibc 2.17)
RUN set -eu; \
    if [ -r /etc/centos-release ]; then \
        export ORACLE_MAJOR=19; \
        export ORACLE_MINOR=28; \
        cd /opt; \
        rm -rf instantclient_*; \
        wget https://download.oracle.com/otn_software/linux/instantclient/1928000/instantclient-basic-linux.x64-19.28.0.0.0dbru.zip; \
        unzip -o instantclient-basic-linux.x64-19.28.0.0.0dbru.zip; \
        rm instantclient-basic-linux.x64-19.28.0.0.0dbru.zip; \
        rm -rf META-INF; \
        wget https://download.oracle.com/otn_software/linux/instantclient/1928000/instantclient-sdk-linux.x64-19.28.0.0.0dbru.zip; \
        unzip -o instantclient-sdk-linux.x64-19.28.0.0.0dbru.zip; \
        rm instantclient-sdk-linux.x64-19.28.0.0.0dbru.zip; \
        rm -rf META-INF; \
        cd /opt/instantclient_${ORACLE_MAJOR}_${ORACLE_MINOR}; \
        ln -s libclntsh.so.19.1 libclntsh.so.23.1; \
        ln -s libclntsh.so.19.1 libclntshcore.so.23.1; \
        ln -s libclntshcore.so.23.1 libclntshcore.so; \
        ln -s libnnz19.so libnnz.so; \
        ln -s /opt/instantclient_${ORACLE_MAJOR}_${ORACLE_MINOR} /opt/instantclient_23_26; \
    fi

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
ARG DOCKER_CLI_VERSION=26.1.4
ARG DOCKER_COMPOSE_VERSION=2.27.0
RUN set -eu; \
    if [ "${WITHTESTS:-}" != "" ]; then \
        cd /tmp; \
        wget -q https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz; \
        tar -xzf docker-${DOCKER_CLI_VERSION}.tgz --strip-components=1 -C /usr/local/bin docker/docker; \
        rm docker-${DOCKER_CLI_VERSION}.tgz; \
        mkdir -p /usr/local/lib/docker/cli-plugins; \
        wget -q -O /usr/local/lib/docker/cli-plugins/docker-compose \
             https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64; \
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose; \
        apt-get update && apt-get -y install python3 && rm -rf /var/lib/apt/lists/*; \
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
        export ORACLE_MAJOR=19; \
        export ORACLE_MINOR=28; \
    fi; \
    export LD_LIBRARY_PATH=/opt/instantclient_${ORACLE_MAJOR}_${ORACLE_MINOR}:/opt/librdkafka/lib:/opt/prometheus/lib:/opt/protobuf/lib ; \
    /opt/OpenLogReplicator/OpenLogReplicator --version

ARG OLR_USER=user1:oracle
USER ${OLR_USER}

WORKDIR /opt/OpenLogReplicator
ENTRYPOINT ["/opt/run.sh"]
