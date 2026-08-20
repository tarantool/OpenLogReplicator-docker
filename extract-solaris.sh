#!/bin/sh
# Script to extract OpenLogReplicator SPARC binary and Oracle libraries from Docker image
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
    echo "Example: $0 <registry>/<namespace>/<image>:<tag>-solaris"
    echo "Example with custom name: $0 <image> openlogreplicator-1.9.0-110-3d58ede1-solaris"
    exit 1
fi

OUTPUT_DIR="./extracted-solaris"
mkdir -p "${OUTPUT_DIR}"

echo "Creating container from image: ${IMAGE_NAME}"
CONTAINER_ID=$(docker create "${IMAGE_NAME}")

echo "Extracting SPARC binary..."
docker cp "${CONTAINER_ID}:/opt/OpenLogReplicator/OpenLogReplicator" "${OUTPUT_DIR}/OpenLogReplicator"

echo "Extracting Oracle Instant Client for Solaris SPARC..."
# Extract Oracle Instant Client libraries (sparcv9 = 64-bit)
docker cp "${CONTAINER_ID}:/opt/usr/oracle/instantclient/18.3/lib/" "${OUTPUT_DIR}/oracle-lib/" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/opt/usr/oracle/instantclient/18.3/lib/sparcv9/" "${OUTPUT_DIR}/oracle-lib64/" 2>/dev/null || true

echo "Removing container..."
docker rm "${CONTAINER_ID}"

echo "Creating wrapper script..."
cat > "${OUTPUT_DIR}/run.sh" << 'EOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="${DIR}/oracle-lib64:${DIR}/oracle-lib:${LD_LIBRARY_PATH:-}"
exec "${DIR}/OpenLogReplicator" "$@"
EOF
chmod +x "${OUTPUT_DIR}/run.sh"

echo "Verifying binary architecture..."
file "${OUTPUT_DIR}/OpenLogReplicator" || true

echo "Creating archive..."
if [ -z "${ARCHIVE_NAME}" ]; then
    ARCHIVE_NAME="openlogreplicator-$(basename "${IMAGE_NAME}" | tr ':' '-').tar.gz"
fi
tar czf "${ARCHIVE_NAME}" -C "${OUTPUT_DIR}" .

echo "Done!"
echo "SPARC binary and libraries extracted to: ${OUTPUT_DIR}/"
echo "Archive created: ${ARCHIVE_NAME}"
echo ""
echo "To deploy on Solaris SPARC VM:"
echo "  1. Copy archive: scp ${ARCHIVE_NAME} user@solaris-vm:/path/"
echo "  2. Extract:      tar xzf ${ARCHIVE_NAME}"
echo "  3. Run:          ./run.sh --version"
