# Custom base images, registry login and proxy CA

The image builds start from public images on Docker Hub by default. That fails where Docker Hub is blocked
or rate-limited, and where the approved base images are a private mirror or hardened images. Each base
image can be replaced with one variable. Leave the variables unset and nothing changes.

A replacement only changes the `FROM` line. It must provide what the stage runs, listed below. The defaults
are the public images the Dockerfiles have always used.

## Variables

| Variable | Dockerfile / stage | Default | The image must provide |
|---|---|---|---|
| `CONTENT_LAKE_BUILD_IMAGE` | `dockerfiles/Dockerfile`: `poms`, and so every `build-*` stage | `maven:3.9.11-eclipse-temurin-25-alpine` | Maven and JDK 25 |
| `CONTENT_LAKE_RUNTIME_IMAGE` | `dockerfiles/Dockerfile`: `runtime-base`, the base of the six service targets | `eclipse-temurin:25-jre-alpine` | JRE 25 on Alpine: `apk`, busybox `addgroup` and `adduser`, `wget` for the HEALTHCHECK |
| `MOCK_GRAPH_IMAGE` | `dockerfiles/Dockerfile`: `mock-graph` | `eclipse-temurin:25-jdk-alpine` | JDK 25 (the container runs `java File.java`, which needs a compiler), busybox `addgroup` and `adduser` |
| `ACS_MODEL_BUILD_IMAGE` | `acs/alfresco/Dockerfile`: `model-build` | `maven:3.9.9-eclipse-temurin-21-alpine` | Maven and a JDK of at least 17 |
| `HXPR_BUILD_IMAGE` | `hxpr/Dockerfile`: `build` | `maven:3-eclipse-temurin-25-alpine` | Maven, JDK 25, `apk` (installs git and bash). Used only with `compose.hxpr-build.yaml` |
| `HXPR_RUNTIME_IMAGE` | `hxpr/Dockerfile`: runtime stage | `amazoncorretto:25-alpine` | JRE 25, `apk` (installs curl), busybox `adduser` and `addgroup`. Used only with `compose.hxpr-build.yaml` |
| `ACA_BUILDER_IMAGE` | `docker/Dockerfile` of alfresco-content-lake-ui: builder stage | `node:24-alpine` | Node 24 with npm. Alpine or Debian; git is installed if missing |
| `ACA_RUNTIME_IMAGE` | same file: runtime stage | `nginxinc/nginx-unprivileged:1.25-alpine` | nginx on Alpine, running as uid 101, with the `/docker-entrypoint.d/` and `/etc/nginx/templates/` mechanism of the official nginx images |

The `ACA_*` variables are declared in the ACA image's Dockerfile. See [ACA images](#aca-images) below.

## Setting them

Put the variables in `.env.local`. The Makefile and `setup.sh` load it after `.env`. Set only the ones you
need. The others keep their defaults.

```bash
# Example .env.local. registry.example.com is a placeholder for your mirror.
CONTENT_LAKE_BUILD_IMAGE=registry.example.com/mirror/maven:3.9.11-eclipse-temurin-25-alpine
CONTENT_LAKE_RUNTIME_IMAGE=registry.example.com/mirror/eclipse-temurin:25-jre-alpine
MOCK_GRAPH_IMAGE=registry.example.com/mirror/eclipse-temurin:25-jdk-alpine
ACS_MODEL_BUILD_IMAGE=registry.example.com/mirror/maven:3.9.9-eclipse-temurin-21-alpine
HXPR_BUILD_IMAGE=registry.example.com/mirror/maven:3-eclipse-temurin-25-alpine
HXPR_RUNTIME_IMAGE=registry.example.com/mirror/amazoncorretto:25-alpine
ACA_BUILDER_IMAGE=registry.example.com/mirror/node:24-alpine
ACA_RUNTIME_IMAGE=registry.example.com/mirror/nginx-unprivileged:1.25-alpine
CONTENT_LAKE_UI_GIT_CONTEXT=../alfresco-content-lake-ui
```

Drop the `CONTENT_LAKE_UI_GIT_CONTEXT` line once the ACA change is on the UI repository's main branch.

## How compose forwards them

Compose passes a build arg only when its variable is set. If it is not set, the `ARG` default in the
Dockerfile applies. The forwarding is written in the compose files like this:

- Bare names, such as `- CONTENT_LAKE_BUILD_IMAGE`, in `compose.content-lake.yaml` and `compose.alfresco-2.yaml`.
- Null map entries, such as `ACA_BUILDER_IMAGE:`, in `compose.ui.yaml`, `compose.alfresco.yaml`,
  `compose.alfresco-2.yaml` and `compose.hxpr-build.yaml`.

An empty value is not the same as an unset one. A line such as `CONTENT_LAKE_BUILD_IMAGE=` in `.env.local`
is set, to the empty string. Compose passes the empty string, the `ARG` default is overridden with nothing,
and the build fails at `FROM`. To use the default, delete the line. Do not leave `NAME=` with no value.

## ACA images

`ACA_BUILDER_IMAGE` and `ACA_RUNTIME_IMAGE` go to `content-app` (`compose.ui.yaml`) and `content-app-2`
(`compose.alfresco-2.yaml`). They are declared in `docker/Dockerfile` of alfresco-content-lake-ui, from
AlfrescoLabs/alfresco-content-lake-ui#25.

Until that change is on the repository's main branch, the default build context (a git URL) does not declare
them. Docker then prints a build warning about build args that were not consumed, and the public images are
used. To use the variables, build from a local checkout that has the change:

```bash
CONTENT_LAKE_UI_GIT_CONTEXT=../alfresco-content-lake-ui
```

## Non-root base images

Each stage that runs `apk` or `addgroup` starts with `USER root`. The service images switch back to `USER app`
at the end. So a base image whose default user is not root works in those stages.

The `poms` and `build-*` stages do not switch to root, because they only run Maven. If one of them fails with
`Permission denied`, the build image's user cannot write there. Use a build image that can write to the
working directory and the Maven home, or add `USER root` above the failing stage.

## Registry login and proxy CA

`setup.sh` loads `.env` and then `.env.local`, as the Makefile does. Two optional variables help when the
machine is behind a private registry or a TLS-inspecting proxy. Both are empty by default.

- **`DOCKER_REGISTRY_LOGIN`**: a registry host, for example `registry.example.com`. Step 1 runs
  `docker login <host>` before anything is pulled, so the base images can be pulled from a registry that
  needs credentials. The login may ask for a credential-helper or GPG unlock: keep the terminal open.
- **`MODEL_RUNNER_CA_BUNDLE`**: a CA bundle file on the host. Step 3 copies it into the Docker Model Runner
  container when the content differs from the container's `/etc/ssl/certs/ca-certificates.crt`, restarts the
  container and waits for it to answer. Model pulls then trust the proxy's CA. The file replaces the whole
  bundle in the container, so it must contain the system CAs as well as the proxy's CA. A missing file or
  container only prints a warning and skips this step.
- **`MODEL_RUNNER_CONTAINER`**: the container name. Default `docker-model-runner`.

## Verify

Check which variables reach compose. The build args appear under `build.args` only when they are set:

```bash
make config | grep -E '_IMAGE: '
```

Lint the shared Dockerfile. `--check` also resolves the `FROM` images, so run it where they can be pulled.
It needs the `code` context, which is the content-lake-app source (here a local checkout, or the same git
URL as `CONTENT_LAKE_GIT_CONTEXT`):

```bash
docker buildx build --check --build-context code=../content-lake-app -f dockerfiles/Dockerfile .
```

Then build the stack. The build log shows each `FROM` line with the image it resolved to:

```bash
make up-alfresco
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `apk: not found` | The base image is not Alpine, and the stage calls `apk` | Use an Alpine variant of the image. For `ACA_BUILDER_IMAGE` a Debian image also works |
| `pull access denied`, `unauthorized` | Not logged in to the registry | Set `DOCKER_REGISTRY_LOGIN`, or run `docker login <host>` yourself |
| `manifest unknown` or `not found` on `FROM` | The tag does not exist in the mirror | Check the name with `docker manifest inspect <image>` |
| `base name (${...}) should not be blank` on `FROM` | A variable is set to an empty value | Delete the line from `.env.local` |
| `Permission denied` during the build | A stage writes somewhere its base image's user cannot | See [Non-root base images](#non-root-base-images) |
| `UnsupportedClassVersionError`, or `release version N not supported` | The JDK in the image is older than the stage needs | Use JDK 25 for the Java 25 stages, and at least JDK 17 for `ACS_MODEL_BUILD_IMAGE` |
| Container reported `unhealthy`, log shows `wget: not found` | The runtime image has no `wget` for the HEALTHCHECK | Use a runtime image with busybox `wget` |
| `x509: certificate signed by unknown authority` while pulling models | The Model Runner container does not trust the proxy's CA | Set `MODEL_RUNNER_CA_BUNDLE` |
| `build-args ... were not consumed` for ACA | The ACA image does not declare the variables yet | See [ACA images](#aca-images) |
