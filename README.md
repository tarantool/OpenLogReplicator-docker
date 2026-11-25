# Fork of OpenLogReplicator-docker

Docker build files for
[`tarantool/openlogreplicator`](https://github.com/tarantool/openlogreplicator),
an Oracle change data capture application.

## Requirements

- Docker
- Git
- access to `ghcr.io/tarantool/openlogreplicator-base:latest`, or a locally
  built base image

## Build OpenLogReplicator

The build scripts clone or update the OpenLogReplicator sources in
`OpenLogReplicator/`, determine the image version with `git describe`, and then
run the appropriate Docker build. The nested clone's `.git` directory is
excluded from the Docker build context.

Build a development image:

```bash
./build-dev.sh
```

Build a release image:

```bash
./build-prod.sh
```

The default image names are:

- `ghcr.io/tarantool/openlogreplicator:<version>-dev`
- `ghcr.io/tarantool/openlogreplicator:<version>`

The scripts accept these environment variables. In GitLab CI they
automatically use the internal source repository and project registry when
`CI_JOB_TOKEN` and `CI_REGISTRY_IMAGE` are available; explicit overrides still
take precedence.

| Variable | Default | Purpose |
|----------|---------|---------|
| `OLR_REPO_URL` | GitHub, or `OLR_INTERNAL_REPO_URL` in CI | Source repository |
| `OLR_BRANCH` | `2.0.0` | Source branch or tag |
| `NEXUS_REPOSITORY_URL` | empty (public upstreams), or derived from `NEXUS_URL` in CI | Nexus base URL for the dependency mirrors |
| `REGISTRY_PATH` | `ghcr.io/tarantool`, or `CI_REGISTRY_IMAGE` in CI | Image registry and namespace |
| `DOCKER_IMAGE_NAME` | `openlogreplicator` | Application image name |
| `BASE_IMAGE_NAME` | GHCR, or the project registry in CI | Build base image |
| `GIDOLR`, `UIDOLR`, `GIDORA` | Current user IDs and `54322` | Runtime user and Oracle group IDs |

For example, to use a locally built base image:

```bash
BASE_IMAGE_NAME=openlogreplicator-base:local ./build-dev.sh
```

## Dependency sources

By default the images are built from the public upstreams. When the
`NEXUS_REPOSITORY_URL` build argument is set to the base URL of a Nexus
instance (`https://<nexus>/repository`), every download goes through the
Nexus proxies listed below instead. Base images (`FROM`) are not covered.

GitLab CI always builds through Nexus. It takes the URLs from CI/CD
variables, so no internal address is stored in this repository:

| CI/CD variable | Purpose |
|----------------|---------|
| `NEXUS_URL` | Hosted raw repository with the proprietary archives; `NEXUS_REPOSITORY_URL` is its parent URL |
| `NEXUS_USER`, `NEXUS_PASS` | Credentials for the hosted raw repository |
| `OLR_INTERNAL_REPO_URL` | OpenLogReplicator source repository |

In CI (`CI_JOB_TOKEN` set) `build-dev.sh`, `build-prod.sh` and
`fetch-oracle-instantclient.sh` fail when `NEXUS_URL` is missing instead of
falling back to the public upstreams.

| Dependency | Nexus repository | Upstream | Authentication |
|------------|------------------|----------|----------------|
| Debian packages | `apt-debian-remote`, `apt-debian-security-remote` | `deb.debian.org` | no |
| CentOS 7 packages | `yum-centos-vault-remote` (`7.9.2009/os`, `updates`, `extras`, `sclo/rh`) | CentOS vault | no |
| EPEL 7 packages | `yum-epel-archive-remote` (`7/`) | `archives.fedoraproject.org/pub/archive/epel` | no |
| rapidjson, librdkafka, prometheus-cpp, Protobuf | `raw-github-remote` | `github.com` | no |
| GCC, binutils, GMP, MPFR, MPC (Solaris) | `raw-ftp-gnu-org-remote` | `ftp.gnu.org/gnu` | no |
| docker CLI and compose plugin (test image) | `apt-docker-debian-remote` | `download.docker.com/linux/debian` | no |
| Oracle Instant Client for Linux | `${NEXUS_URL}/otn_software/linux/instantclient/` | `download.oracle.com/otn_software/linux/instantclient/` | yes |
| Solaris sysroot, Oracle Instant Client for Solaris | `${NEXUS_URL}/openlogreplicator/solaris/` | — | yes |

Notes:

- `configure-mirrors.sh` configures APT or yum of the build image; every
  Dockerfile runs it before installing packages. With Nexus, the Debian image
  has no CA bundle yet, so the script installs `ca-certificates` with TLS peer
  verification disabled for that single step; APT still checks the signed
  `InRelease` files. Without Nexus, Debian keeps its default sources and
  CentOS 7 uses the public vault and EPEL archive.
- The Nexus raw proxy does not serve GitHub commit diffs, so the rapidjson
  1.1.0 fix (upstream commit `3b2441b8`) is stored in `patches/`.
- The Docker APT repository has no docker CLI 26.1.4 and compose 2.27.0
  packages for Debian 13, so the test image installs the pinned Debian 12
  packages. The binaries are static.

### Oracle Instant Client

Credentials are never passed to `docker build`:
`fetch-oracle-instantclient.sh` downloads the archives into
`oracle-instantclient/` in the build context. The Dockerfiles unpack them in a
throwaway build stage, so the archives never end up in an image layer. The
directory content is ignored by Git.

```bash
./fetch-oracle-instantclient.sh 23.26.0.0.0      # Dockerfile.base
./fetch-oracle-instantclient.sh 19.28.0.0.0dbru  # Dockerfile, CentOS 7
```

Without `NEXUS_URL` the script downloads from `download.oracle.com`. With
`NEXUS_URL` (plus `NEXUS_USER` and `NEXUS_PASS`) it downloads
`${NEXUS_URL}/otn_software/linux/instantclient/<MAJOR><MINOR>000/instantclient-{basic,sdk}-linux.x64-<VERSION>.zip`,
the same path as on `download.oracle.com`. GitLab CI runs it before the
Debian and CentOS 7 base builds and before the CentOS 7 application builds.

### Update a dependency version

- GitHub and GNU archives: change the version in `Dockerfile.base` or
  `Dockerfile.base.solaris`. The proxy fetches the new file on first request;
  check it with `curl -sI <url>`.
- Oracle Instant Client: upload the `basic` and `sdk` archives of the new
  version to `${NEXUS_URL}/otn_software/linux/instantclient/<MAJOR><MINOR>000/`,
  then change `ORACLE_MAJOR`/`ORACLE_MINOR` in `Dockerfile.base` (or
  `ORACLE_CLIENT19_VERSION` in `Dockerfile`) and the matching
  `ORACLE_CLIENT_VERSION`/`ORACLE_CLIENT19_VERSION` in `.gitlab-ci.yml`;
  `tests/test-build-defaults.sh` fails if they differ.
- docker CLI and compose: change `DOCKER_CLI_VERSION`,
  `DOCKER_COMPOSE_VERSION` and, if needed, `DOCKER_DEB_SUITE` and
  `DOCKER_DEB_RELEASE` in `Dockerfile`.

## Build the base image

The base image needs the Oracle Instant Client archives in
`oracle-instantclient/`, see [Oracle Instant Client](#oracle-instant-client).

```bash
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

## Build the test image

Regression tests are included in the OpenLogReplicator source repository. Build
an image containing those tests with:

```bash
WITHTESTS=1 OLR_USER=root ./build-dev.sh
```

See the
[`tests/README.md`](https://github.com/tarantool/openlogreplicator/blob/1.9.0/tests/README.md)
file in the source repository for test execution instructions.

## Solaris SPARC cross-compilation

The Solaris base image requires two files that cannot be distributed by this
repository:

- `solaris-sysroot.tar.gz`
- `oracle-instantclient-18.3-solaris-sparc.tar.gz`

Place both archives in the repository root, then build the cross-compilation
base and application images:

```bash
docker build \
  -t openlogreplicator-base-solaris:local \
  -f Dockerfile.base.solaris \
  --build-arg BASE_IMAGE=ghcr.io/tarantool/openlogreplicator-base-centos7:latest \
  .

BASE_IMAGE_NAME=openlogreplicator-base-solaris:local ./build-solaris.sh
```

The two proprietary archives are ignored by Git.

The internal GitLab CI downloads these archives from Nexus before the Solaris
base build. Nexus credentials are not passed to the Dockerfile.

## Extract a native package

Extract a Linux binary and its shared libraries from a built image:

```bash
./extract-binary.sh ghcr.io/tarantool/openlogreplicator:<tag>
```

Extract a Solaris SPARC package:

```bash
./extract-solaris.sh ghcr.io/tarantool/openlogreplicator:<tag>-solaris
```

## License

This repository is licensed under the GNU Affero General Public License. See
[LICENSE](LICENSE).
