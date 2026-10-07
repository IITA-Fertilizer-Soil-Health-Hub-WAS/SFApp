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
    POETRY_VIRTUALENVS_CREATE=false \
    VENV_PATH=/opt/venv

# Build-time only: compilers/headers for any sdist that lacks a wheel.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Create the runtime virtualenv up front so every install lands in it.
RUN python -m venv "$VENV_PATH"
ENV PATH="$VENV_PATH/bin:$PATH"

# Install Poetry into its own location (kept out of the runtime venv).
RUN pip install "poetry==${POETRY_VERSION}"

WORKDIR /app

# Copy only the dependency manifests first so this layer caches across code
# changes. poetry.lock pins the exact, known-good dependency set.
COPY pyproject.toml poetry.lock ./

# Install ONLY the main dependency group (no dev tools) into the active venv
# using the lock file for reproducibility. pyproject has package-mode=false, so
# only dependencies are installed (there is no project root to build).
RUN poetry install --only main --no-interaction --no-ansi

# Drop bytecode/caches that pip/poetry leave behind to trim the venv.
RUN find "$VENV_PATH" -type d -name "__pycache__" -prune -exec rm -rf {} + \
    && find "$VENV_PATH" -type d -name "tests" -prune -exec rm -rf {} + 2>/dev/null || true

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
    # Streamlit listens here; the Container App targetPort must match.
    PORT=8501

# curl is only needed for the container healthcheck.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 appuser \
    && mkdir -p /var/secrets/google \
    && chown -R appuser:appuser /var/secrets/google

# Bring in the finished virtualenv from the builder.
COPY --from=builder /opt/venv /opt/venv

WORKDIR /SFApp

# Application code (see .dockerignore for what stays out of the image).
COPY --chown=appuser:appuser . .

RUN chmod +x /SFApp/docker-entrypoint.sh

USER appuser

EXPOSE 8501

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl --fail "http://localhost:${PORT}/_stcore/health" || exit 1

ENTRYPOINT ["/SFApp/docker-entrypoint.sh"]
