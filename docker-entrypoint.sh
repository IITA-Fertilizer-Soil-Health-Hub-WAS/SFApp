#!/usr/bin/env bash
# Container entrypoint for the Sampling Frames Streamlit app.
#
# The app (eefun.py) authenticates to Google Earth Engine at import time using a
# service-account key *file*. In Azure Container Apps we don't mount files, so
# the key is delivered as a Container App secret exposed to the container as the
# GOOGLE_CREDENTIALS_JSON environment variable. This script materializes that
# secret into the file path the app expects, then launches Streamlit.
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

exec streamlit run SFapp.py \
    --server.port="${PORT:-8501}" \
    --server.address=0.0.0.0 \
    --server.headless=true \
    --browser.gatherUsageStats=false
