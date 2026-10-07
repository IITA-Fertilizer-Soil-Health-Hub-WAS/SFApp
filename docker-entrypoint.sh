#!/usr/bin/env bash
# Container entrypoint for the Sampling Frames Streamlit app.
#
# 1. Materialize the Google Earth Engine service-account key from the
#    GOOGLE_CREDENTIALS_JSON secret into the file path the app expects
#    (eefun.py authenticates at import time using a key *file*).
# 2. Start Streamlit on an internal port (127.0.0.1:8502).
# 3. Run nginx in the foreground on the ingress port (8501) as a host-gate:
#    only ALLOWED_HOST is served; every other Host (including the default
#    *.azurecontainerapps.io FQDN) gets 404.
set -euo pipefail

CRED_PATH="${GOOGLE_APPLICATION_CREDENTIALS:-/var/secrets/google/key.json}"
if [ -n "${GOOGLE_CREDENTIALS_JSON:-}" ]; then
    mkdir -p "$(dirname "$CRED_PATH")"
    printf '%s' "$GOOGLE_CREDENTIALS_JSON" > "$CRED_PATH"
    chmod 600 "$CRED_PATH"
elif [ "${AUTH_MECHANISM:-}" != "interactive" ] && [ ! -f "$CRED_PATH" ]; then
    echo "WARNING: AUTH_MECHANISM='${AUTH_MECHANISM:-}' expects a service-account key at" >&2
    echo "         '$CRED_PATH', but none was provided (set the GOOGLE_CREDENTIALS_JSON" >&2
    echo "         secret). Earth Engine initialization will fail." >&2
fi

# Render the nginx host-gate config with the allowed public domain.
ALLOWED_HOST="${ALLOWED_HOST:-samplingframes.akilimo.org}"
mkdir -p /tmp/nginx
sed "s/__ALLOWED_HOST__/${ALLOWED_HOST}/g" /SFApp/nginx.conf.template > /tmp/nginx/nginx.conf

# Start Streamlit on the internal port; nginx (below) is the public entrypoint.
streamlit run SFapp.py \
    --server.port=8502 \
    --server.address=127.0.0.1 \
    --server.headless=true \
    --server.enableCORS=false \
    --server.enableXsrfProtection=false \
    --browser.gatherUsageStats=false &

# nginx in the foreground is the container's main process (PID 1 of the app).
exec nginx -c /tmp/nginx/nginx.conf -g 'daemon off;'
