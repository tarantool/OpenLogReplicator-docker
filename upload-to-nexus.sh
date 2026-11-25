#!/bin/bash
set -euo pipefail

ARCHIVE_NAME="$1"
NEXUS_PATH="${2:-openlogreplicator}"

if [ -z "${NEXUS_URL:-}" ] || [ -z "${NEXUS_USER:-}" ] || [ -z "${NEXUS_PASS:-}" ]; then
    echo "ERROR: NEXUS_URL, NEXUS_USER, NEXUS_PASS must be set" >&2
    exit 1
fi

if [ ! -f "${ARCHIVE_NAME}" ]; then
    echo "ERROR: Archive '${ARCHIVE_NAME}' not found" >&2
    exit 1
fi

UPLOAD_URL="${NEXUS_URL}/${NEXUS_PATH}/${ARCHIVE_NAME}"

echo "Uploading ${ARCHIVE_NAME} to Nexus..."
echo "URL: ${UPLOAD_URL}"

# The credentials go to curl through stdin so that they do not show up in the
# process list; backslashes and quotes are escaped for the curl config syntax.
curl_auth() {
    printf 'user = "%s:%s"\n' \
        "$(printf '%s' "$NEXUS_USER" | sed 's/[\\"]/\\&/g')" \
        "$(printf '%s' "$NEXUS_PASS" | sed 's/[\\"]/\\&/g')" |
        curl --config - "$@"
}

HTTP_CODE=$(curl_auth -s -o /dev/null -w "%{http_code}" \
    --upload-file "${ARCHIVE_NAME}" \
    "${UPLOAD_URL}")

if [ "${HTTP_CODE}" -eq 201 ] || [ "${HTTP_CODE}" -eq 200 ]; then
    echo "Upload successful (HTTP ${HTTP_CODE})"
else
    echo "ERROR: Upload failed with HTTP ${HTTP_CODE}" >&2
    exit 1
fi
