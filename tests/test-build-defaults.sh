#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    file=$1
    expected=$2
    grep -F -- "$expected" "$file" >/dev/null ||
        fail "expected '$expected' in $file"
}

assert_not_contains() {
    file=$1
    unexpected=$2
    if grep -F -- "$unexpected" "$file" >/dev/null; then
        fail "did not expect '$unexpected' in $file"
    fi
}

make_fakes() {
    fake_bin=$1
    mkdir -p "$fake_bin"

    printf '%s\n' '#!/bin/sh' 'printf "%s\n" test-user' > "$fake_bin/whoami"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" 1001' > "$fake_bin/id"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = clone ]; then' \
        '    printf "%s\n" "$2" > "$GIT_CLONE_LOG"' \
        '    mkdir -p "$3/.git"' \
        'elif [ "$1" = describe ]; then' \
        '    printf "%s\n" v1.9.0-2-gabc1234' \
        'fi' > "$fake_bin/git"
    printf '%s\n' \
        '#!/bin/sh' \
        'printf "%s\n" "$*" > "$DOCKER_LOG"' > "$fake_bin/docker"
    chmod +x "$fake_bin/whoami" "$fake_bin/id" "$fake_bin/git" "$fake_bin/docker"
}

run_build() {
    mode=$1
    script=$2
    case_dir="$TEST_TMP/${mode}-${script}"
    fake_bin="$case_dir/bin"
    work_dir="$case_dir/work"
    mkdir -p "$work_dir"
    make_fakes "$fake_bin"
    cp "$ROOT/$script" "$ROOT/nexus-repository-url.sh" "$work_dir/"
    cp "$ROOT/Dockerfile" "$ROOT/Dockerfile.solaris" "$work_dir/"

    export GIT_CLONE_LOG="$case_dir/git-clone.log"
    export DOCKER_LOG="$case_dir/docker.log"

    if [ "$mode" = community ]; then
        (cd "$work_dir" && env -u CI_JOB_TOKEN -u CI_REGISTRY_IMAGE -u REGISTRY_PATH \
            -u DOCKER_IMAGE_NAME -u BASE_IMAGE_NAME -u OLR_INTERNAL_REPO_URL \
            -u NEXUS_URL -u NEXUS_REPOSITORY_URL \
            PATH="$fake_bin:$PATH" "./$script")
        assert_contains "$GIT_CLONE_LOG" "https://github.com/tarantool/openlogreplicator.git"
        assert_contains "$DOCKER_LOG" "-t ghcr.io/tarantool/openlogreplicator:"
        assert_not_contains "$DOCKER_LOG" "NEXUS_REPOSITORY_URL"
    else
        internal_repo_url=https://gitlab-ci-token:test-token@gitlab.invalid/openlogreplicator.git
        test_image_name=openlogreplicator-test
        (cd "$work_dir" && env -u NEXUS_REPOSITORY_URL CI_JOB_TOKEN=test-token \
            OLR_INTERNAL_REPO_URL="$internal_repo_url" \
            NEXUS_URL=https://nexus.invalid/repository/raw-hosted/ \
            CI_REGISTRY_IMAGE=registry.example/team/openlogreplicator-docker \
            DOCKER_IMAGE_NAME="$test_image_name" \
            PATH="$fake_bin:$PATH" "./$script")
        assert_contains "$GIT_CLONE_LOG" "$internal_repo_url"
        assert_contains "$DOCKER_LOG" \
            "-t registry.example/team/openlogreplicator-docker/${test_image_name}:"
        assert_contains "$DOCKER_LOG" \
            "--build-arg BASE_IMAGE=registry.example/team/openlogreplicator-docker/${test_image_name}-base"
        assert_contains "$DOCKER_LOG" \
            "--build-arg BASE_IMAGE=registry.example/team/openlogreplicator-docker/"
        if [ "$script" != build-solaris.sh ]; then
            assert_contains "$DOCKER_LOG" \
                "--build-arg NEXUS_REPOSITORY_URL=https://nexus.invalid/repository "
        fi
    fi
}

# In CI the Linux builds must use the Nexus mirrors and never fall back to
# the public upstreams.
run_missing_nexus() {
    script=$1
    case_dir="$TEST_TMP/missing-nexus-${script}"
    fake_bin="$case_dir/bin"
    work_dir="$case_dir/work"
    mkdir -p "$work_dir"
    make_fakes "$fake_bin"
    cp "$ROOT/$script" "$ROOT/nexus-repository-url.sh" "$work_dir/"

    export GIT_CLONE_LOG="$case_dir/git-clone.log"
    export DOCKER_LOG="$case_dir/docker.log"

    if (cd "$work_dir" && env -u NEXUS_URL -u NEXUS_REPOSITORY_URL CI_JOB_TOKEN=test-token \
        OLR_INTERNAL_REPO_URL=https://gitlab.invalid/internal.git \
        PATH="$fake_bin:$PATH" "./$script") >/dev/null 2>"$case_dir/stderr"; then
        fail "$script must fail in CI without NEXUS_URL"
    fi
    assert_contains "$case_dir/stderr" 'NEXUS_URL must be set'
}

run_override() {
    script=$1
    case_dir="$TEST_TMP/override-${script}"
    fake_bin="$case_dir/bin"
    work_dir="$case_dir/work"
    mkdir -p "$work_dir"
    make_fakes "$fake_bin"
    cp "$ROOT/$script" "$ROOT/nexus-repository-url.sh" "$work_dir/"

    export GIT_CLONE_LOG="$case_dir/git-clone.log"
    export DOCKER_LOG="$case_dir/docker.log"

    (cd "$work_dir" && env -u NEXUS_URL CI_JOB_TOKEN=test-token \
        OLR_INTERNAL_REPO_URL=https://gitlab.invalid/internal.git \
        OLR_REPO_URL=https://example.invalid/olr.git \
        NEXUS_REPOSITORY_URL=https://mirror.invalid/repository \
        ORACLE_CLIENT19_VERSION=19.99.0.0.0dbru \
        PATH="$fake_bin:$PATH" "./$script")
    assert_contains "$GIT_CLONE_LOG" "https://example.invalid/olr.git"
    if [ "$script" != build-solaris.sh ]; then
        assert_contains "$DOCKER_LOG" \
            "--build-arg NEXUS_REPOSITORY_URL=https://mirror.invalid/repository "
        assert_contains "$DOCKER_LOG" "--build-arg ORACLE_CLIENT19_VERSION=19.99.0.0.0dbru "
    fi
}

unset OLR_REPO_URL

for script in build-dev.sh build-prod.sh build-solaris.sh; do
    run_build community "$script"
    run_build corporate "$script"
    run_override "$script"
done
run_missing_nexus build-dev.sh
run_missing_nexus build-prod.sh

# A NEXUS_URL without a repository path must be rejected instead of becoming a
# malformed https:/ base URL.
if (cd "$TEST_TMP" && env -u NEXUS_REPOSITORY_URL NEXUS_URL=https://nexus.invalid \
    sh -c '. "$1"' _ "$ROOT/nexus-repository-url.sh") \
    >/dev/null 2>"$TEST_TMP/nexus-url-err"; then
    fail "nexus-repository-url.sh must reject a NEXUS_URL without a path"
fi
assert_contains "$TEST_TMP/nexus-url-err" 'must include a repository path'

if (cd "$TEST_TMP" && env -u NEXUS_URL CI_JOB_TOKEN=test-token \
    sh "$ROOT/fetch-oracle-instantclient.sh" 23.26.0.0.0) >/dev/null 2>"$TEST_TMP/fetch-err"; then
    fail "fetch-oracle-instantclient.sh must fail in CI without NEXUS_URL"
fi
assert_contains "$TEST_TMP/fetch-err" 'NEXUS_URL must be set'

# The repository is published as open source: internal hosts must not appear
# in any file. Internal URLs come from GitLab CI/CD variables only.
INTERNAL_HOSTS='vk[t]eam|vk[.]team|corp[.]mail[.]ru'
if (cd "$ROOT" && git ls-files -co --exclude-standard -z |
    xargs -0 grep -nIE "$INTERNAL_HOSTS" --); then
    fail "internal host in the repository"
fi

# Dockerfiles download only through the mirror-aware URL variables. Comment
# lines are skipped and backslash continuations are joined first, so that a URL
# on the line after `wget \` is found and a URL in a comment is not.
hardcoded_urls() {
    awk '
        FNR == 1 && line != "" { print prev ": " line; line = "" }
        { prev = FILENAME }
        /^[ \t]*#/ { next }
        { line = line $0 }
        /\\$/ { sub(/\\$/, "", line); next }
        { print FILENAME ": " line; line = "" }
        END { if (line != "") print prev ": " line }
    ' "$@" | grep -E '(wget|curl)[^#]*https?://' || true
}

printf '%s\n' '# wget https://comment.invalid/x' 'RUN wget ${URL}/a # https://doc.invalid' \
    > "$TEST_TMP/Dockerfile.ok"
printf '%s\n' 'RUN set -eu; \' '    wget \' '        https://hard.invalid/y' \
    > "$TEST_TMP/Dockerfile.bad"
[ -z "$(hardcoded_urls "$TEST_TMP/Dockerfile.ok")" ] ||
    fail "hardcoded_urls reports a comment or a variable URL"
[ -n "$(hardcoded_urls "$TEST_TMP/Dockerfile.bad")" ] ||
    fail "hardcoded_urls misses a URL after a line continuation"
printf 'RUN wget https://tail.invalid/q \\\n' > "$TEST_TMP/Dockerfile.tail"
[ -n "$(hardcoded_urls "$TEST_TMP/Dockerfile.tail")" ] ||
    fail "hardcoded_urls misses a URL on a trailing continuation line"

urls=$(hardcoded_urls "$ROOT"/Dockerfile*)
if [ -n "$urls" ]; then
    printf '%s\n' "$urls" >&2
    fail "hard-coded download URL in a Dockerfile"
fi

# The Oracle client versions CI fetches must match what the Dockerfiles unpack.
ci_var() { sed -n "s/^  $1: \"\(.*\)\"\$/\1/p" "$ROOT/.gitlab-ci.yml"; }
base_major=$(sed -n 's/^ENV ORACLE_MAJOR=//p' "$ROOT/Dockerfile.base")
base_minor=$(sed -n 's/^ENV ORACLE_MINOR=//p' "$ROOT/Dockerfile.base")
[ -n "$base_major" ] && [ "$(ci_var ORACLE_CLIENT_VERSION)" = "${base_major}.${base_minor}.0.0.0" ] ||
    fail "ORACLE_CLIENT_VERSION in .gitlab-ci.yml differs from Dockerfile.base"
[ -n "$(ci_var ORACLE_CLIENT19_VERSION)" ] &&
    [ "$(ci_var ORACLE_CLIENT19_VERSION)" = \
        "$(sed -n 's/^ARG ORACLE_CLIENT19_VERSION=//p' "$ROOT/Dockerfile")" ] ||
    fail "ORACLE_CLIENT19_VERSION in .gitlab-ci.yml differs from Dockerfile"
if grep -nE 'fetch-oracle-instantclient\.sh +[0-9]' "$ROOT/.gitlab-ci.yml"; then
    fail "hard-coded Oracle client version in .gitlab-ci.yml"
fi

assert_contains "$ROOT/.gitlab-ci.yml" \
    'curl_auth --fail --location --silent --show-error'
# Nexus credentials must not appear in a curl command line (visible in ps).
if grep -nE -- '--user|NEXUS_PASS[^;]*\\$' "$ROOT/.gitlab-ci.yml" \
    "$ROOT/fetch-oracle-instantclient.sh" "$ROOT/upload-to-nexus.sh" | grep -v ':?'; then
    fail "Nexus credentials passed on a curl command line"
fi
assert_contains "$ROOT/.gitlab-ci.yml" \
    '--build-arg BASE_IMAGE="${CI_REGISTRY_IMAGE}/${DOCKER_IMAGE_NAME}-base-centos7:latest"'
assert_contains "$ROOT/.gitlab-ci.yml" \
    'DOCKER_BASE_IMAGE_NAME: "${DOCKER_IMAGE_NAME}-base-debian"'
assert_contains "$ROOT/.gitlab-ci.yml" \
    '$CI_MERGE_REQUEST_TARGET_BRANCH_NAME == $CI_DEFAULT_BRANCH'
assert_contains "$ROOT/.gitlab-ci.yml" 'image: "$OLR_CI_IMAGE"'
assert_not_contains "$ROOT/.gitlab-ci.yml" 'registry-gitlab.'
assert_not_contains "$ROOT/.gitlab-ci.yml" '--build-arg NEXUS_PASS'
assert_contains "$ROOT/upload-to-nexus.sh" 'Uploading ${ARCHIVE_NAME} to Nexus'

# --- configure-mirrors.sh: runs against a temporary MIRRORS_ETC tree ---------

DEBIAN_SOURCES='Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main

Types: deb
URIs: https://security.debian.org/debian-security
Suites: bookworm-security
Components: main'

mirrors_env() {
    # $1 - case name; sets ETC_DIR, FAKE_BIN and TOOL_LOG for the case
    case_dir="$TEST_TMP/mirrors-$1"
    ETC_DIR="$case_dir/etc"
    FAKE_BIN="$case_dir/bin"
    TOOL_LOG="$case_dir/tools.log"
    mkdir -p "$ETC_DIR" "$FAKE_BIN"
    : > "$TOOL_LOG"
    # The script targets GNU sed; BSD sed (macOS) needs `-i ''`.
    if ! sed --version >/dev/null 2>&1; then
        printf '%s\n' '#!/bin/sh' \
            "if [ \"\$1\" = -i ]; then shift; exec $(command -v sed) -i '' \"\$@\"; fi" \
            "exec $(command -v sed) \"\$@\"" > "$FAKE_BIN/sed"
        chmod +x "$FAKE_BIN/sed"
    fi
    for tool in apt-get yum; do
        printf '%s\n' '#!/bin/sh' "printf '%s %s\\n' $tool \"\$*\" >> \"$TOOL_LOG\"" \
            > "$FAKE_BIN/$tool"
        chmod +x "$FAKE_BIN/$tool"
    done
}

run_mirrors() {
    (cd "$TEST_TMP" && env -u NEXUS_REPOSITORY_URL MIRRORS_ETC="$ETC_DIR" \
        MIRRORS_VAR="$case_dir/var" \
        PATH="$FAKE_BIN:$PATH" sh "$ROOT/configure-mirrors.sh" "$@")
}

debian_tree() {
    mirrors_env "$1"
    mkdir -p "$ETC_DIR/apt/sources.list.d" "$ETC_DIR/apt/apt.conf.d" "$ETC_DIR/ssl/certs"
    : > "$ETC_DIR/debian_version"
    printf '%s\n' "$DEBIAN_SOURCES" > "$ETC_DIR/apt/sources.list.d/debian.sources"
    SOURCES="$ETC_DIR/apt/sources.list.d/debian.sources"
    TIMEOUT_CONF="$ETC_DIR/apt/apt.conf.d/99nexus-timeout"
}

debian_tree debian-nexus
printf '%s\n' cert > "$ETC_DIR/ssl/certs/ca-certificates.crt"
run_mirrors https://nexus.invalid/repository/
assert_contains "$SOURCES" 'URIs: https://nexus.invalid/repository/apt-debian-remote'
assert_contains "$SOURCES" 'URIs: https://nexus.invalid/repository/apt-debian-security-remote'
assert_not_contains "$SOURCES" 'deb.debian.org'
assert_not_contains "$SOURCES" 'security.debian.org'
[ -f "$TIMEOUT_CONF" ] || fail "99nexus-timeout is not written with Nexus"
assert_not_contains "$TOOL_LOG" 'apt-get'
cp "$SOURCES" "$case_dir/first.sources"
run_mirrors https://nexus.invalid/repository/
cmp -s "$SOURCES" "$case_dir/first.sources" || fail "configure-mirrors.sh is not idempotent"
run_mirrors --public
assert_contains "$SOURCES" 'URIs: https://deb.debian.org/debian'
assert_contains "$SOURCES" 'URIs: https://deb.debian.org/debian-security'
assert_not_contains "$SOURCES" 'nexus.invalid'
[ ! -e "$TIMEOUT_CONF" ] || fail "--public leaves 99nexus-timeout"

# A URL with sed-special characters must land in the sources verbatim.
debian_tree debian-special
printf '%s\n' cert > "$ETC_DIR/ssl/certs/ca-certificates.crt"
run_mirrors 'https://nexus.invalid/r?a=1&b=2|c\d'
assert_contains "$SOURCES" 'URIs: https://nexus.invalid/r?a=1&b=2|c\d/apt-debian-remote'

# Without Nexus the Debian sources stay untouched.
debian_tree debian-public
cp "$SOURCES" "$case_dir/orig.sources"
run_mirrors
cmp -s "$SOURCES" "$case_dir/orig.sources" || fail "sources changed without Nexus"
[ ! -e "$TIMEOUT_CONF" ] || fail "99nexus-timeout written without Nexus"

# Without a CA bundle the bootstrap installs ca-certificates with peer
# verification disabled for that step only.
debian_tree debian-bootstrap
run_mirrors https://nexus.invalid/repository
assert_contains "$TOOL_LOG" 'apt-get -o Acquire::https::Verify-Peer=false update'
assert_contains "$TIMEOUT_CONF" 'Acquire::https::Timeout "600"'
assert_contains "$TOOL_LOG" \
    'apt-get -o Acquire::https::Verify-Peer=false -y install --no-install-recommends ca-certificates'

centos_tree() {
    mirrors_env "$1"
    mkdir -p "$ETC_DIR/yum.repos.d" "$ETC_DIR/pki/rpm-gpg"
    : > "$ETC_DIR/centos-release"
    printf '%s\n' '[old]' 'baseurl=http://mirror.centos.org/' > "$ETC_DIR/yum.repos.d/CentOS-Base.repo"
    REPO="$ETC_DIR/yum.repos.d/mirrors.repo"
}

centos_tree centos-nexus
run_mirrors https://nexus.invalid/repository
assert_contains "$REPO" 'baseurl=https://nexus.invalid/repository/yum-centos-vault-remote/7.9.2009/os/$basearch/'
[ ! -e "$ETC_DIR/yum.repos.d/CentOS-Base.repo" ] || fail "old yum repository is kept"
assert_not_contains "$REPO" 'epel'
assert_contains "$REPO" 'gpgcheck=1'
assert_contains "$REPO" 'enabled=1'
assert_contains "$REPO" 'timeout=600'
assert_contains "$TOOL_LOG" 'yum clean all'
: > "$ETC_DIR/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7"
run_mirrors https://nexus.invalid/repository
assert_contains "$REPO" 'baseurl=https://nexus.invalid/repository/yum-epel-archive-remote/7/$basearch/'
run_mirrors --public
assert_contains "$REPO" 'baseurl=https://vault.centos.org/7.9.2009/os/$basearch/'
assert_contains "$REPO" 'baseurl=https://archives.fedoraproject.org/pub/archive/epel/7/$basearch/'
assert_not_contains "$REPO" 'nexus.invalid'

if (cd "$TEST_TMP" && env MIRRORS_ETC="$TEST_TMP/mirrors-empty" sh "$ROOT/configure-mirrors.sh") \
    >/dev/null 2>&1; then
    fail "configure-mirrors.sh must fail on an unsupported distribution"
fi

# --- fetch-oracle-instantclient.sh: a fake curl records the request ----------

run_fetch() {
    # $1 - case name; remaining arguments are env assignments
    case_dir="$TEST_TMP/fetch-$1"
    shift
    mkdir -p "$case_dir/bin" "$case_dir/work"
    CURL_ARGS="$case_dir/curl-args.log"
    CURL_STDIN="$case_dir/curl-stdin.log"
    : > "$CURL_ARGS"
    : > "$CURL_STDIN"
    cat > "$case_dir/bin/curl" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_ARGS"
while [ "$#" -gt 0 ]; do
    case $1 in
        --config) cat >> "$CURL_STDIN" ;;
        --output) out=$2; shift ;;
    esac
    shift
done
: > "$out"
printf x > "$out"
FAKE
    chmod +x "$case_dir/bin/curl"
    FETCH_DIR="$case_dir/work/oracle-instantclient"
    (cd "$case_dir/work" && env -u NEXUS_URL -u NEXUS_USER -u NEXUS_PASS -u CI_JOB_TOKEN -u DEST_DIR \
        CURL_ARGS="$CURL_ARGS" CURL_STDIN="$CURL_STDIN" "$@" \
        PATH="$case_dir/bin:$PATH" sh "$ROOT/fetch-oracle-instantclient.sh" 23.26.0.0.0)
}

run_fetch nexus NEXUS_URL=https://nexus.invalid/repository/raw-hosted/ \
    NEXUS_USER='u"ser' NEXUS_PASS='p\ss $x'
assert_contains "$CURL_ARGS" \
    'https://nexus.invalid/repository/raw-hosted/otn_software/linux/instantclient/2326000/instantclient-basic-linux.x64-23.26.0.0.0.zip'
assert_contains "$CURL_ARGS" 'instantclient-sdk-linux.x64-23.26.0.0.0.zip'
assert_not_contains "$CURL_ARGS" 'ss $x'
assert_not_contains "$CURL_ARGS" '--user'
assert_contains "$CURL_ARGS" '--fail --location --silent --show-error'
assert_contains "$CURL_STDIN" 'user = "u\"ser:p\\ss $x"'
[ -s "$FETCH_DIR/instantclient-basic-linux.x64-23.26.0.0.0.zip" ] ||
    fail "the basic archive was not stored"
[ ! -e "$FETCH_DIR/instantclient-basic-linux.x64-23.26.0.0.0.zip.part" ] ||
    fail "a partial download was left behind"

# An archive that is already present is not downloaded again.
: > "$CURL_ARGS"
(cd "$case_dir/work" && env -u NEXUS_URL -u CI_JOB_TOKEN -u DEST_DIR CURL_ARGS="$CURL_ARGS" \
    CURL_STDIN="$CURL_STDIN" NEXUS_URL=https://nexus.invalid/r NEXUS_USER=u NEXUS_PASS=p \
    PATH="$case_dir/bin:$PATH" sh "$ROOT/fetch-oracle-instantclient.sh" 23.26.0.0.0) >/dev/null
[ ! -s "$CURL_ARGS" ] || fail "an existing archive was downloaded again"

for missing in NEXUS_USER NEXUS_PASS; do
    case $missing in
        NEXUS_USER) set_env='NEXUS_PASS=p' ;;
        *) set_env='NEXUS_USER=u' ;;
    esac
    if run_fetch "no-$missing" NEXUS_URL=https://nexus.invalid/r "$set_env" \
        >/dev/null 2>"$TEST_TMP/fetch-err"; then
        fail "fetch-oracle-instantclient.sh must fail without $missing"
    fi
    assert_contains "$TEST_TMP/fetch-err" "$missing must be set"
done

run_fetch public
assert_contains "$CURL_ARGS" \
    'https://download.oracle.com/otn_software/linux/instantclient/2326000/instantclient-basic-linux.x64-23.26.0.0.0.zip'
assert_not_contains "$CURL_ARGS" '--config'
[ ! -s "$CURL_STDIN" ] || fail "credentials sent without Nexus"

echo "PASS: community and corporate build defaults"
