# syntax=docker/dockerfile:1

###############################################################################
# Builder stage: resolve the locked dependencies into a self-contained venv.
# Nothing from this stage ships except the finished /opt/venv, so build tools
# and caches never bloat the runtime image.
###############################################################################
FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    POETRY_VERSION=1.8.3 \
    VENV_PATH=/opt/venv

# Build-time only: compilers/headers for any sdist that lacks a wheel.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Poetry lives in the BASE interpreter (not the runtime venv), and is only used
# to translate the lock file into a pinned requirements list.
RUN pip install "poetry==${POETRY_VERSION}" "poetry-plugin-export==1.8.0"

# Create the runtime virtualenv that will be copied into the final image.
RUN python -m venv "$VENV_PATH"

WORKDIR /app

# Copy only the dependency manifests first so this layer caches across code
# changes. poetry.lock pins the exact, known-good dependency set.
COPY pyproject.toml poetry.lock ./

# Export the locked main dependencies, then install them EXPLICITLY into the
# venv's own pip. This avoids any ambiguity about where Poetry would install
# (the previous `poetry install` left the venv empty, producing a tiny image
# with no streamlit). poetry.lock keeps the versions reproducible.
RUN poetry export --only main --without-hashes --format requirements.txt --output requirements.txt \
    && "$VENV_PATH/bin/pip" install --no-cache-dir -r requirements.txt

# Drop bytecode/caches to trim the venv.
RUN find "$VENV_PATH" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true

###############################################################################
# Runtime stage: slim Python + the prebuilt venv only. No conda, no gcloud SDK.
# The geo wheels (shapely/pyproj/fiona/geopandas) bundle their native libraries,
# so the slim base needs no extra system packages.
###############################################################################
FROM python:3.11-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    VENV_PATH=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    # Non-interactive Earth Engine auth (service account) by default in the
    # container; override to "interactive" only for local dev.
    AUTH_MECHANISM=service_account \
    # The entrypoint writes the service-account key here from a secret env var.
    GOOGLE_APPLICATION_CREDENTIALS=/var/secrets/google/key.json \
    # nginx (the ingress port, targetPort must match) host-gates Streamlit, which
    # listens internally on 8502. Only requests for ALLOWED_HOST are served; every
    # other Host (incl. the default *.azurecontainerapps.io FQDN) gets 404.
    PORT=8501 \
    ALLOWED_HOST=samplingframes.akilimo.org

# nginx is the host-gate in front of Streamlit; curl is for the healthcheck.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl nginx-light \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 appuser \
    && mkdir -p /var/secrets/google /tmp/nginx \
    && chown -R appuser:appuser /var/secrets/google /tmp/nginx /var/log/nginx /var/lib/nginx

# Bring in the finished virtualenv from the builder.
COPY --from=builder /opt/venv /opt/venv

WORKDIR /SFApp

# Application code (see .dockerignore for what stays out of the image).
COPY --chown=appuser:appuser . .

# Make the working directory itself writable by appuser: geemap's
# Map.to_streamlit() writes a temporary HTML file into the CWD at runtime, and
# the directory node created by WORKDIR is otherwise owned by root.
RUN chmod +x /SFApp/docker-entrypoint.sh \
    && chown appuser:appuser /SFApp

USER appuser

EXPOSE 8501

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl --fail "http://localhost:${PORT}/_stcore/health" || exit 1

ENTRYPOINT ["/SFApp/docker-entrypoint.sh"]
