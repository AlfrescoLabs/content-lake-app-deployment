#!/usr/bin/env bash
# Generate a self-signed certificate for local HTTPS development.
# Creates a certificate valid for localhost with a 1-year validity period.

set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nginx/certs/local"
mkdir -p "$CERT_DIR"

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" \
  -out   "$CERT_DIR/server.crt" \
  -subj  "/C=US/ST=Development/L=Local/O=App for OpenArch/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1"

chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"

echo "Self-signed certificate generated:"
echo "  Certificate: $CERT_DIR/server.crt"
echo "  Private key: $CERT_DIR/server.key"
echo ""
echo "Next steps:"
echo "  1. Add 'USE_HTTPS=true' to .env.local"
echo "  2. Restart the stack: make down && make up-alfresco"
echo "  3. Accept the certificate warning in your browser"
