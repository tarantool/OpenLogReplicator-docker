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
    cp "$ROOT/$script" "$work_dir/$script"
    cp "$ROOT/Dockerfile" "$ROOT/Dockerfile.solaris" "$work_dir/"

    export GIT_CLONE_LOG="$case_dir/git-clone.log"
    export DOCKER_LOG="$case_dir/docker.log"

    if [ "$mode" = community ]; then
        (cd "$work_dir" && env -u CI_JOB_TOKEN -u CI_REGISTRY_IMAGE -u REGISTRY_PATH \
            -u DOCKER_IMAGE_NAME -u BASE_IMAGE_NAME -u OLR_INTERNAL_REPO_URL \
            PATH="$fake_bin:$PATH" "./$script")
        assert_contains "$GIT_CLONE_LOG" "https://github.com/tarantool/openlogreplicator.git"
        assert_contains "$DOCKER_LOG" "-t ghcr.io/tarantool/openlogreplicator:"
    else
        internal_repo_url=https://gitlab-ci-token:test-token@gitlab.invalid/openlogreplicator.git
        test_image_name=openlogreplicator-test
        (cd "$work_dir" && CI_JOB_TOKEN=test-token \
            OLR_INTERNAL_REPO_URL="$internal_repo_url" \
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
    fi
}

for script in build-dev.sh build-prod.sh build-solaris.sh; do
    run_build community "$script"
    run_build corporate "$script"
done

assert_contains "$ROOT/.gitlab-ci.yml" \
    'curl --fail --location --silent --show-error'
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

echo "PASS: community and corporate build defaults"
