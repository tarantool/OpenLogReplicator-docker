#!/bin/sh
# Script to extract OpenLogReplicator binary and shared libraries from Docker image
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

set -eu

IMAGE_NAME="${1:-}"
ARCHIVE_NAME="${2:-}"

if [ -z "${IMAGE_NAME}" ]; then
    echo "Usage: $0 <docker-image-name> [archive-name]"
    echo "Example: $0 <registry>/<namespace>/<image>:<tag>"
    echo "Example with custom name: $0 <image> openlogreplicator-1.9.0-110-3d58ede1"
    exit 1
fi

OUTPUT_DIR="./extracted"
mkdir -p "${OUTPUT_DIR}"

echo "Creating container from image: ${IMAGE_NAME}"
CONTAINER_ID=$(docker create "${IMAGE_NAME}")

echo "Extracting binary..."
docker cp "${CONTAINER_ID}:/opt/OpenLogReplicator/OpenLogReplicator" "${OUTPUT_DIR}/OpenLogReplicator"

# Remove RPATH so LD_LIBRARY_PATH takes precedence over hardcoded paths
if command -v patchelf >/dev/null 2>&1; then
    echo "Removing RPATH from binary..."
    patchelf --remove-rpath "${OUTPUT_DIR}/OpenLogReplicator"
else
    echo "WARNING: patchelf not found. Binary may have hardcoded RPATH that overrides LD_LIBRARY_PATH."
    echo "Install patchelf on the target VM or build image with -DCMAKE_INSTALL_RPATH=\"\""
fi

echo "Extracting shared libraries..."
# Get list of .so files from ldd output
docker cp "${CONTAINER_ID}:/usr/bin/ldd" "${OUTPUT_DIR}/ldd" 2>/dev/null || true

# Extract libraries from common paths
# Oracle Instant Client (CentOS 7 uses 19_28, Debian uses 23_26)
docker cp "${CONTAINER_ID}:/opt/instantclient_19_28/" "${OUTPUT_DIR}/instantclient_19_28/" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/opt/instantclient_23_26/" "${OUTPUT_DIR}/instantclient_23_26/" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/opt/librdkafka/lib/" "${OUTPUT_DIR}/librdkafka/" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/opt/prometheus/lib/" "${OUTPUT_DIR}/prometheus/" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/opt/prometheus/lib64/" "${OUTPUT_DIR}/prometheus64/" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/opt/protobuf/lib/" "${OUTPUT_DIR}/protobuf/" 2>/dev/null || true

# Note: libstdc++ and libgcc are now statically linked into the binary
# No need to extract them separately

# Extract ASAN and UBSAN libraries for debug builds
echo "Extracting sanitizer libraries (if present)..."
# CentOS 7 paths (devtoolset-9)
docker cp "${CONTAINER_ID}:/usr/lib64/libasan.so.5.0.0" "${OUTPUT_DIR}/" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/usr/lib64/libubsan.so.1.0.0" "${OUTPUT_DIR}/" 2>/dev/null || true
# Debian/Ubuntu paths
docker cp "${CONTAINER_ID}:/usr/lib/x86_64-linux-gnu/libasan.so.8.0.0" "${OUTPUT_DIR}/" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/usr/lib/x86_64-linux-gnu/libubsan.so.1.0.0" "${OUTPUT_DIR}/" 2>/dev/null || true
# libaio for Oracle (CentOS and Debian/Ubuntu have different naming)
# CentOS 7
docker cp "${CONTAINER_ID}:/usr/lib64/libaio.so.1.0.1" "${OUTPUT_DIR}/" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/usr/lib64/libaio.so.1.0.0" "${OUTPUT_DIR}/" 2>/dev/null || true
# Debian/Ubuntu
docker cp "${CONTAINER_ID}:/usr/lib/x86_64-linux-gnu/libaio.so.1t64.0.2" "${OUTPUT_DIR}/" 2>/dev/null || true
# Create symlinks for libaio if actual files were copied
if [ -f "${OUTPUT_DIR}/libaio.so.1.0.1" ]; then
    ln -sf libaio.so.1.0.1 "${OUTPUT_DIR}/libaio.so.1"
fi
if [ -f "${OUTPUT_DIR}/libaio.so.1.0.0" ]; then
    ln -sf libaio.so.1.0.0 "${OUTPUT_DIR}/libaio.so.1"
fi
if [ -f "${OUTPUT_DIR}/libaio.so.1t64.0.2" ]; then
    ln -sf libaio.so.1t64.0.2 "${OUTPUT_DIR}/libaio.so.1t64"
    ln -sf libaio.so.1t64 "${OUTPUT_DIR}/libaio.so.1"
fi
# Create symlinks if actual files were copied
if [ -f "${OUTPUT_DIR}/libasan.so.5.0.0" ]; then
    ln -sf libasan.so.5.0.0 "${OUTPUT_DIR}/libasan.so.5"
fi
if [ -f "${OUTPUT_DIR}/libubsan.so.1.0.0" ]; then
    ln -sf libubsan.so.1.0.0 "${OUTPUT_DIR}/libubsan.so.1"
fi
if [ -f "${OUTPUT_DIR}/libasan.so.8.0.0" ]; then
    ln -sf libasan.so.8.0.0 "${OUTPUT_DIR}/libasan.so.8"
fi
if [ -f "${OUTPUT_DIR}/libubsan.so.1.0.0" ]; then
    ln -sf libubsan.so.1.0.0 "${OUTPUT_DIR}/libubsan.so.1"
fi

echo "Removing container..."
docker rm "${CONTAINER_ID}"

echo "Creating wrapper script..."
cat > "${OUTPUT_DIR}/run.sh" << 'EOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="${DIR}:${DIR}/instantclient_19_28:${DIR}/instantclient_23_26:${DIR}/librdkafka:${DIR}/prometheus:${DIR}/prometheus64:${DIR}/protobuf:${LD_LIBRARY_PATH:-}"
exec "${DIR}/OpenLogReplicator" "$@"
EOF
chmod +x "${OUTPUT_DIR}/run.sh"

echo "Creating archive..."
if [ -z "${ARCHIVE_NAME}" ]; then
    ARCHIVE_NAME="openlogreplicator-$(basename "${IMAGE_NAME}" | tr ':' '-').tar.gz"
fi
tar czf "${ARCHIVE_NAME}" -C "${OUTPUT_DIR}" .

echo "Done!"
echo "Binary and libraries extracted to: ${OUTPUT_DIR}/"
echo "Archive created: ${ARCHIVE_NAME}"
echo ""
echo "To run on target VM:"
echo "  1. Copy archive: scp ${ARCHIVE_NAME} user@vm:/path/"
echo "  2. Extract:      tar xzf ${ARCHIVE_NAME}"
echo "  3. Run:          ./run.sh --version"
