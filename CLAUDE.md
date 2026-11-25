# CLAUDE.md

This file provides guidance to coding agents working in this repository.

## Repository overview

This is a **fork** of OpenLogReplicator-docker that builds Docker images for
[`tarantool/openlogreplicator`](https://github.com/tarantool/openlogreplicator),
an Oracle change data capture application.

Key files:

- `Dockerfile.base` builds Linux dependencies.
- `Dockerfile` compiles the Linux application image.
- `build-dev.sh` and `build-prod.sh` build debug and release images.
- `Dockerfile.base.solaris` builds the Solaris SPARC cross-toolchain.
- `Dockerfile.solaris` cross-compiles the Solaris SPARC application.
- `build-solaris.sh` builds the Solaris application image.
- `extract-binary.sh` and `extract-solaris.sh` create native archives.
- `upload-to-nexus.sh` uploads native archives from the internal CI pipeline.
- `configure-mirrors.sh` points APT/yum of a build image to the Nexus proxies
  (`--public` restores the public upstreams at the end of a build).
- `fetch-oracle-instantclient.sh` downloads the proprietary Oracle Instant
  Client archives into `oracle-instantclient/` (ignored by Git).
- `nexus-repository-url.sh` is sourced by the build scripts and CI jobs to
  derive `NEXUS_REPOSITORY_URL` from `NEXUS_URL`.
- `patches/` holds files that the Nexus raw proxy cannot serve (rapidjson fix).
- `tests/test-build-defaults.sh` is the regression test for build defaults.
- `.gitlab-ci.yml` contains the internal GitLab build, test, and release jobs.
- `run.sh` is the Linux container entry point.

`OpenLogReplicator/` is a generated local clone of the source repository, not
a tracked submodule. It is ignored by Git, and its `.git` directory is excluded
from the Docker build context.

## Build system

### Local Linux builds

Build a development image with debug symbols:

```bash
./build-dev.sh
```

Build an optimized release image without Docker cache:

```bash
./build-prod.sh
```

Both scripts clone or update `OpenLogReplicator/`, check out `OLR_BRANCH`,
derive the version with `git describe --tags --long`, and build an image with
that version in its tag.

Outside GitLab CI, the defaults are:

- source: `https://github.com/tarantool/openlogreplicator.git`
- source branch: `2.0.0`
- registry namespace: `ghcr.io/tarantool`
- image name: `openlogreplicator`
- Linux base image: `ghcr.io/tarantool/openlogreplicator-base:latest`
- Solaris base image: `ghcr.io/tarantool/openlogreplicator-base-solaris:latest`

The build scripts read these variables:

| Variable | Community default | GitLab CI default | Purpose |
|----------|-------------------|-------------------|---------|
| `OLR_REPO_URL` | GitHub repository | internal GitLab repository authenticated by `CI_JOB_TOKEN` | source repository |
| `OLR_BRANCH` | `2.0.0` | `2.0.0` | source branch or tag |
| `NEXUS_URL` | unset | required, hosted raw repository | derives `NEXUS_REPOSITORY_URL` (its parent URL) |
| `NEXUS_REPOSITORY_URL` | unset, public upstreams | derived from `NEXUS_URL` | Nexus base URL passed to Docker as a build argument |
| `REGISTRY_PATH` | `ghcr.io/tarantool` | `CI_REGISTRY_IMAGE` | registry namespace |
| `DOCKER_IMAGE_NAME` | `openlogreplicator` | value configured by CI | application image name |
| `BASE_IMAGE_NAME` | GHCR base image | project registry base image | base image override |
| `GIDOLR`, `UIDOLR` | current user IDs | CI values | runtime group and user IDs |
| `GIDORA` | `54322` | `54322` | Oracle group ID |
| `WITHTESTS` | unset | job-specific | include source tests in a development image |
| `OLR_USER` | unset | job-specific | runtime user override |

Explicit values always take precedence over detected defaults. For example:

```bash
OLR_REPO_URL=https://example.org/olr.git \
REGISTRY_PATH=registry.example.org/team \
DOCKER_IMAGE_NAME=olr \
BASE_IMAGE_NAME=openlogreplicator-base:local \
./build-dev.sh
```

Build a test-enabled development image with:

```bash
WITHTESTS=1 OLR_USER=root ./build-dev.sh
```

### Build arguments

The application Dockerfiles support these main arguments:

- `BUILD_TYPE`: `Debug` or `Release`.
- `WITHORACLE=1`: enable Oracle Instant Client support.
- `WITHKAFKA=1`: enable Kafka/librdkafka support on Linux.
- `WITHPROMETHEUS=1`: enable Prometheus metrics.
- `WITHPROTOBUF=1`: enable Protobuf.
- `GIDOLR`, `UIDOLR`, and `GIDORA`: runtime user and group IDs.
- `OPENLOGREPLICATOR_VERSION`: source directory/version name.
- `BASE_IMAGE`: base image selected before the first `FROM`.
- `NEXUS_REPOSITORY_URL`: Nexus base URL; empty means public upstreams.

### Two-stage Linux build

The project separates dependencies from application compilation:

1. `Dockerfile.base` installs and builds Oracle, Kafka, Prometheus, and
   Protobuf dependencies. It supports Debian 12/13 and CentOS 7.
2. `Dockerfile` copies the generated `OpenLogReplicator/` source tree,
   generates Protobuf sources when enabled, and compiles the application.

Build a Debian base image locally. `Dockerfile.base` unpacks Oracle Instant
Client from `oracle-instantclient/`, so download it first (a CentOS 7
application build also needs `./fetch-oracle-instantclient.sh 19.28.0.0.0dbru`):

```bash
./fetch-oracle-instantclient.sh 23.26.0.0.0
docker build \
  -t openlogreplicator-base:local \
  -f Dockerfile.base \
  --build-arg IMAGE=debian \
  --build-arg VERSION=13.0 \
  --build-arg WITHORACLE=1 \
  --build-arg WITHKAFKA=1 \
  --build-arg WITHPROMETHEUS=1 \
  --build-arg WITHPROTOBUF=1 \
  .
```

Use it for an application build:

```bash
BASE_IMAGE_NAME=openlogreplicator-base:local ./build-dev.sh
```

## Version tagging

The version comes from the generated `OpenLogReplicator/` clone, not this
repository:

```bash
cd OpenLogReplicator
git describe --tags --long
```

The scripts remove the leading `v` and the `g` before the commit hash. For
example, `v1.9.0-109-geaf86214` becomes `1.9.0-109-eaf86214`. Development
images append `-dev`; Solaris images append `-solaris`.

## Internal GitLab CI

The internal pipeline uses the Docker-in-Docker runner selected by the
required `CI_RUNNER` CI/CD variable and has three stages:

1. `build-base`: Debian, CentOS 7, and Solaris SPARC base images.
2. `build`: development images for merge requests and release images for
   version tags or explicitly triggered pipelines.
3. `test`: standalone C++ unit tests and Oracle XE 21c / Free 23c regression
   tests.

Inside CI, the build scripts detect `CI_JOB_TOKEN` and
`CI_REGISTRY_IMAGE`. This selects the internal source repository and project
registry without changing the public defaults. Jobs pass the exact Debian,
CentOS, or Solaris `BASE_IMAGE_NAME` explicitly.

The Solaris base job downloads these proprietary files from Nexus into the
Docker build context before invoking `Dockerfile.base.solaris`:

- `solaris-sysroot.tar.gz`
- `oracle-instantclient-18.3-solaris-sparc.tar.gz`

Dockerfiles never receive Nexus credentials. CI jobs require `NEXUS_URL`,
`NEXUS_USER`, and `NEXUS_PASS`; `NEXUS_REPOSITORY_URL` is derived from
`NEXUS_URL` and passed as a build argument. `build-dev.sh`, `build-prod.sh`
and `fetch-oracle-instantclient.sh` fail in CI when `NEXUS_URL` is missing
instead of using public upstreams. Development and
release jobs use `upload-to-nexus.sh` to upload extracted archives to
`NEXUS_DEV_PATH` or `NEXUS_PROD_PATH`.

The Dockerfiles take Oracle Instant Client from `oracle-instantclient/` in the
build context and unpack it in a throwaway stage, so the archives never stay
in an image layer. CI runs `fetch-oracle-instantclient.sh` in the Debian and
CentOS 7 base jobs (`ORACLE_CLIENT_VERSION`) and in the CentOS 7 application jobs
(`ORACLE_CLIENT19_VERSION`); Debian
application images take the client from the base image. The CI logs show the
classic Docker builder (the client in `OLR_CI_IMAGE` has no buildx), so do not
use BuildKit-only syntax such as `RUN --mount`. The `OLR_CI_IMAGE` and
`OLR_INTERNAL_REPO_URL` CI/CD variables select the job image and the internal
source repository.

## Image architecture

### Linux base image

`Dockerfile.base` installs build tools and optional dependencies. On CentOS 7
it enables `devtoolset-9`, redirects end-of-life repositories to
`vault.centos.org` (through the Nexus proxies when `NEXUS_REPOSITORY_URL` is
set), disables Prometheus tests, and creates the required
library-directory compatibility link.

### Linux application image

`Dockerfile`:

1. copies the generated source tree;
2. generates Protobuf code when enabled;
3. configures and builds OpenLogReplicator;
4. uses static `libgcc` and `libstdc++` linking on CentOS 7;
5. creates the runtime user and validates the binary with `--version`.

## CentOS 7 compatibility build

Build a CentOS 7 base image for glibc 2.17 targets (after
`./fetch-oracle-instantclient.sh 23.26.0.0.0`):

```bash
docker build \
  -t openlogreplicator-base:centos7 \
  -f Dockerfile.base \
  --build-arg IMAGE=centos \
  --build-arg VERSION=7 \
  --build-arg WITHORACLE=1 \
  --build-arg WITHKAFKA=1 \
  --build-arg WITHPROMETHEUS=1 \
  --build-arg WITHPROTOBUF=1 \
  .
```

Then build the application:

```bash
BASE_IMAGE_NAME=openlogreplicator-base:centos7 ./build-prod.sh
```

## Solaris SPARC cross-compilation

`Dockerfile.base.solaris` requires the two proprietary archives listed in the
CI section. For a local build, place them in the repository root. They are
ignored by Git.

The base image builds a GCC 11.4 cross-compiler and binutils 2.40, builds
Protobuf and Prometheus for Solaris SPARC, and creates
`/opt/cross-solaris/solaris-sparc-toolchain.cmake`.

Build the base and application images:

```bash
docker build \
  -t openlogreplicator-base-solaris:local \
  -f Dockerfile.base.solaris \
  --build-arg BASE_IMAGE=ghcr.io/tarantool/openlogreplicator-base-centos7:latest \
  .

BASE_IMAGE_NAME=openlogreplicator-base-solaris:local ./build-solaris.sh
```

`Dockerfile.solaris` cross-compiles with the toolchain file, enables Oracle,
Prometheus, and Protobuf through build arguments, statically links the C++
runtime, and uses `-j1` to avoid cross-compiler failures under parallel load.

## Extract native packages

Extract a Linux binary and its shared libraries:

```bash
./extract-binary.sh ghcr.io/tarantool/openlogreplicator:<tag>
```

The script creates `extracted/`, removes the binary RPATH with `patchelf`
when available, collects supported libraries, creates a `run.sh` wrapper, and
writes a gzip-compressed tar archive.

Extract a Solaris SPARC package:

```bash
./extract-solaris.sh ghcr.io/tarantool/openlogreplicator:<tag>-solaris
```

The Solaris archive contains the SPARC binary, Oracle libraries, and a
`run.sh` wrapper that sets `LD_LIBRARY_PATH`.

Both extraction scripts accept any fully qualified image reference, including
an internal GitLab Registry image.

## Verification

Check shell syntax:

```bash
for file in build-dev.sh build-prod.sh build-solaris.sh \
  extract-binary.sh extract-solaris.sh upload-to-nexus.sh run.sh \
  configure-mirrors.sh fetch-oracle-instantclient.sh nexus-repository-url.sh; do
  sh -n "$file"
done
```

Run the build-default regression test:

```bash
sh tests/test-build-defaults.sh
```

For Dockerfile changes, run the affected Docker build or a BuildKit validation.
A Solaris base build additionally requires the two proprietary archives.
