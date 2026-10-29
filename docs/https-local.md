# Local HTTPS with Self-Signed Certificates

Enables HTTPS on the nginx proxy for local development without affecting HTTP.  
Internal service-to-service traffic stays on HTTP inside the Docker network.

## Prerequisites

- OpenSSL installed (`openssl version`)
  - Ubuntu/Debian (including WSL):

    ```bash
    sudo apt-get update
    sudo apt-get install -y openssl
    openssl version
    ```

- Docker Desktop running

## Setup

With `./setup.sh`, steps 1 and 3 are automatic: set `USE_HTTPS=true` in `.env.local` and run `./setup.sh`. It generates the certificate when `nginx/certs/local/server.crt` or `server.key` is missing and keeps an existing one. If openssl is missing, it stops and prints the install steps. The steps below are for `make up-*`.

### 1. Generate the certificate

```bash
bash scripts/generate-local-cert.sh
```

This creates `nginx/certs/local/server.crt` and `server.key` (git-ignored).

### 2. Enable HTTPS in `.env.local`

```bash
echo "USE_HTTPS=true" >> .env.local
```

### 3. Restart the stack

```bash
make down && make up-alfresco   # or up-nuxeo / up-full / up-demo
```

The proxy now:
- Serves HTTPS on port 443
- Redirects HTTP (port 80) → HTTPS

## Browser certificate acceptance

Browsers will warn about the self-signed certificate. Accept it once per browser:

| Browser | How to proceed |
|---------|----------------|
| **Chrome** | Click **Advanced** → **Proceed to localhost (unsafe)** |
| **Firefox** | Click **Advanced** → **Accept the Risk and Continue** |
| **Safari** | Click **Show Details** → **visit this website** → confirm |

## Verify it works

```bash
# HTTPS (ignore cert warning with -k)
curl -k https://localhost/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready-

# HTTP redirect
curl -I http://localhost/aca/
# Expected: 301 Moved Permanently, Location: https://localhost/aca/
```

## Revert to HTTP-only

```bash
echo "USE_HTTPS=false" >> .env.local
make down && make up-alfresco
```

Or remove the `USE_HTTPS` line from `.env.local` entirely (defaults to `false`).

## Troubleshooting

**`nginx: [emerg] cannot load certificate`**  
The HTTPS block is enabled, but nginx cannot read the cert/key pair (for example, `server.key` is missing or unreadable while `server.crt` exists). Regenerate both with `bash scripts/generate-local-cert.sh`, or re-run `./setup.sh` with `USE_HTTPS=true` (it regenerates when either file is missing). Then restart the proxy: `docker restart content-lake-app-proxy-1`.

**`Permission denied` when generating the certificate**  
On a fresh checkout, Docker may have created `nginx/certs/local` as root. Take ownership, then re-run the generator:

```bash
sudo chown -R "$(id -u):$(id -g)" nginx/certs
./setup.sh   # or: bash scripts/generate-local-cert.sh
```

**`ERR_CONNECTION_CLOSED` on https:// after enabling HTTPS**  
The proxy decides at container start whether to enable HTTPS. If `server.crt` was missing then, it serves HTTP only. `./setup.sh` restarts the proxy after it generates a certificate. With `make up-*`, restart it yourself: `docker restart content-lake-app-proxy-1`.

**Port 443 already in use**  
Override the port: `echo "HTTPS_PORT=8443" >> .env.local` then access `https://localhost:8443`.

**Browser still shows HTTP after enabling HTTPS**  
Clear the browser's HSTS cache for `localhost` or use a private/incognito window.
