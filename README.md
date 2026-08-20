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
| `OLR_REPO_URL` | GitHub, or internal GitLab in CI | Source repository |
| `OLR_BRANCH` | `1.9.0` | Source branch or tag |
| `REGISTRY_PATH` | `ghcr.io/tarantool`, or `CI_REGISTRY_IMAGE` in CI | Image registry and namespace |
| `DOCKER_IMAGE_NAME` | `openlogreplicator` | Application image name |
| `BASE_IMAGE_NAME` | GHCR, or the project registry in CI | Build base image |
| `GIDOLR`, `UIDOLR`, `GIDORA` | Current user IDs and `54322` | Runtime user and Oracle group IDs |

For example, to use a locally built base image:

```bash
BASE_IMAGE_NAME=openlogreplicator-base:local ./build-dev.sh
```

## Build the base image

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
