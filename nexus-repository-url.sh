# Source this file: sets NEXUS_REPOSITORY_URL, the Nexus base URL, to the parent
# of NEXUS_URL (the hosted raw repository) unless it is already set. Exits the
# calling shell when NEXUS_URL is missing.
if [ -z "${NEXUS_REPOSITORY_URL:-}" ]; then
    : "${NEXUS_URL:?NEXUS_URL must be set}"
    # NEXUS_URL must be a hosted repository with a path (e.g.
    # https://nexus.example.com/repository/raw-hosted); its parent becomes the
    # base URL. A bare host would yield a malformed https:/ URL.
    case "${NEXUS_URL%/}" in
        *://*/*) ;;
        *)
            echo "NEXUS_URL must include a repository path, e.g. https://nexus.example.com/repository/raw-hosted" >&2
            exit 1
            ;;
    esac
    NEXUS_REPOSITORY_URL=${NEXUS_URL%/}
    NEXUS_REPOSITORY_URL=${NEXUS_REPOSITORY_URL%/*}
fi
