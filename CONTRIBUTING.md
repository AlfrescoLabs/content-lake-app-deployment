# Contributing

This project is part of the **Content Lake** PoC ecosystem. Contributions are welcome.

## Before You Start

- Read the [README](README.md) to understand the deployment profiles and stack layout.
- Check the open issues before starting new work.
- For significant changes, open an issue first to discuss the approach.

## Making Changes

1. Fork the repository and create a branch from `main`.
2. Make your changes. Keep commits focused -- one logical change per commit.
3. Validate by running `make config` (dry-run, renders compose configuration) and then starting
   the affected profile with `make up-alfresco` or `make up-nuxeo`.
4. Run the smoke tests if you have a running stack:
   ```bash
   ./test/smoke-test.sh
   ```
5. Open a pull request. Describe what changed and why.

## Service Dockerfiles

All seven Content Lake service images are built from a single file, `dockerfiles/Dockerfile`. Each
service is a build target, selected from `compose.content-lake.yaml` with `target:`.

When adding a new Maven module to `content-lake-app`, add one `COPY --from=code <group>/<module>/pom.xml`
line to the `poms` stage of that file. That stage is the only place the reactor's module list is
enumerated, and Maven needs the full reactor to resolve any subset of it, so a missing line breaks
services unrelated to the new module. Add a `src` copy only to the service stages that actually build
the module.

`compose.content-lake.yaml` holds no build instructions beyond `context`, `dockerfile`, `target`, the `code`
context and the base-image args, so adding a module does not touch it. Only adding a new *service* would. A
new service built from `dockerfiles/Dockerfile` must forward `CONTENT_LAKE_BUILD_IMAGE` and
`CONTENT_LAKE_RUNTIME_IMAGE` as bare args, and a new `FROM` must use a global `ARG` with a public default
(see [docs/custom-base-images.md](docs/custom-base-images.md)).

One further build depends on the module layout and is easy to miss: `acs/alfresco/Dockerfile` installs
`common/content-lake-repo-model` into the Alfresco image and names that path twice.

Nothing under `content-lake-app/plugins/` takes part in any of this. A connector ships as a jar dropped
into `connectors/` at runtime.

## Commit Messages

Use the format: `type: short description`

Types: `feat`, `fix`, `docs`, `chore`
