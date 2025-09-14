# -------------------------------------------------------------------
# Docling Serve - CUDA 12.8 Containerfile
# Builds a GPU-enabled image for Docling with local code modifications
# -------------------------------------------------------------------

# Base image: NVIDIA CUDA 12.8 (development image)
ARG BASE_IMAGE=nvidia/cuda:12.8.0-devel-ubi9
FROM ${BASE_IMAGE} AS docling-base

# Use root for OS-level package installation
USER 0

# Install OS dependencies (assuming os-packages.txt exists in repo)
RUN --mount=type=bind,source=os-packages.txt,target=/tmp/os-packages.txt \
    dnf -y install --best --nodocs --setopt=install_weak_deps=False dnf-plugins-core && \
    dnf config-manager --enable crb && \
    dnf -y update && \
    dnf install -y $(cat /tmp/os-packages.txt) && \
    dnf -y clean all && \
    rm -rf /var/cache/dnf

# Permissions for cache directories
RUN /usr/bin/fix-permissions /opt/app-root/src/.cache

# Tesseract data path
ENV TESSDATA_PREFIX=/usr/share/tesseract/tessdata/

# CUDA env variables
ENV CUDA_HOME=/usr/local/cuda
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

# -------------------------------------------------------------------
# UV stage for Python dependencies
# -------------------------------------------------------------------
ARG UV_VERSION=0.8.3
ARG UV_SYNC_EXTRA_ARGS=""
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv_stage

# -------------------------------------------------------------------
# Docling Serve Layer
# -------------------------------------------------------------------
FROM docling-base
USER 1001
WORKDIR /opt/app-root/src

# Environment
ENV \
    OMP_NUM_THREADS=4 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PYTHONIOENCODING=utf-8 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/app-root \
    DOCLING_SERVE_ARTIFACTS_PATH=/opt/app-root/src/.cache/docling/models

ARG UV_SYNC_EXTRA_ARGS
ARG MODELS_LIST="layout tableformer picture_classifier easyocr"

# Sync Python dependencies using uv
RUN --mount=from=uv_stage,source=/uv,target=/bin/uv \
    --mount=type=cache,target=/opt/app-root/src/.cache/uv,uid=1001 \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    umask 002 && \
    UV_SYNC_ARGS="--frozen --no-install-project --no-dev --all-extras" && \
    uv sync ${UV_SYNC_ARGS} ${UV_SYNC_EXTRA_ARGS}

# Download required models
RUN echo "Downloading Docling models..." && \
    HF_HUB_DOWNLOAD_TIMEOUT="90" \
    HF_HUB_ETAG_TIMEOUT="90" \
    docling-tools models download -o "${DOCLING_SERVE_ARTIFACTS_PATH}" ${MODELS_LIST} && \
    chown -R 1001:0 ${DOCLING_SERVE_ARTIFACTS_PATH} && \
    chmod -R g=u ${DOCLING_SERVE_ARTIFACTS_PATH}

# Copy your local modified Python code
COPY --chown=1001:0 ./docling_serve ./docling_serve

# Optionally resync uv after copying code
RUN --mount=from=uv_stage,source=/uv,target=/bin/uv \
    --mount=type=cache,target=/opt/app-root/src/.cache/uv,uid=1001 \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    umask 002 && uv sync --frozen --no-dev --all-extras ${UV_SYNC_EXTRA_ARGS}

# Expose service port
EXPOSE 5001

# Entry point
CMD ["docling-serve", "run"]
