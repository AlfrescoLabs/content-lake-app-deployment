# Security Policy

## Reporting a Vulnerability

This is a Proof of Concept project intended for local development and evaluation. It is **not
designed for production use** and has not undergone a security audit.

If you discover a security vulnerability, please report it privately by opening a GitHub issue
marked **[security]** or by contacting the repository maintainer directly.

Do not open a public issue for active security vulnerabilities -- wait for acknowledgement before
public disclosure.

## Supported Versions

Only the current `main` branch is supported. No backported security patches are provided.

## Known Limitations

- Default credentials are used throughout (`admin`/`admin`, `Administrator`/`Administrator`) for
  local convenience. Never expose this stack on a public network without changing them.
- The nginx reverse proxy does not enforce TLS in the default configuration. See
  [docs/DEPLOY_EC2.md](docs/DEPLOY_EC2.md) for HTTPS setup guidance.

## Variables That Must Be Overridden Before Non-Local Use

The following variables are committed to `.env` with insecure PoC defaults. Override every one of
them in `.env.local` (or via the deployment environment) before exposing the stack on any network
other than localhost:

| Variable | Default | What to change |
|---|---|---|
| `ALFRESCO_ADMIN_PASSWORD` | `admin` | Strong password |
| `POSTGRES_PASSWORD` | `alfresco` | Strong password |
| `ACTIVEMQ_PASSWORD` | `admin` | Strong password |
| `SHARED_SECRET` | `3uux2z0blli` | Random string (repo <-> batch-indexer transform secure comms) |
| `OPENSEARCH_ADMIN_PASSWORD` | `Hyland_Pass1!` | Strong password (required if security re-enabled) |
| `HXPR_PASSWORD` | `password` | Strong password (engine HTTP Basic auth) |
| `NUXEO_PASSWORD` | `Administrator` | Strong password |
| `SERVER_NAME` | `localhost` | Public hostname or IP |
| `USE_HTTPS` | `false` | `true` + valid certificate |
