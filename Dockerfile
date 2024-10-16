FROM lukemathwalker/cargo-chef:latest-rust-1.75-bookworm AS chef
WORKDIR /usr/src

ENV RUSTC_WRAPPER=/usr/local/bin/sccache

# Donwload, configure sccache
RUN apt-get update && apt-get install -y \
    sccache \
    && rm -rf /var/lib/apt/lists/*

FROM chef AS planner

COPY backends backends
COPY core core
COPY router router
COPY Cargo.toml ./
COPY Cargo.lock ./

RUN cargo chef prepare  --recipe-path recipe.json

FROM chef AS builder

ARG GIT_SHA
ARG DOCKER_LABEL

# sccache specific variables
ARG ACTIONS_CACHE_URL
ARG ACTIONS_RUNTIME_TOKEN
ARG SCCACHE_GHA_ENABLED

COPY --from=chef /usr/bin/sccache /usr/local/bin/sccache

COPY --from=planner /usr/src/recipe.json recipe.json

RUN cargo chef cook --release --features ort --no-default-features --recipe-path recipe.json && sccache -s

COPY backends backends
COPY core core
COPY router router
COPY Cargo.toml ./
COPY Cargo.lock ./

FROM builder AS http-builder

RUN cargo build --release --bin text-embeddings-router -F ort -F http --no-default-features && sccache -s

FROM builder AS grpc-builder

RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

COPY proto proto

RUN cargo build --release --bin text-embeddings-router -F grpc -F ort --no-default-features && sccache -s

FROM debian:bookworm-slim AS base

ENV HUGGINGFACE_HUB_CACHE=/data \
    PORT=80

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*


FROM base AS grpc

COPY --from=grpc-builder /usr/src/target/release/text-embeddings-router /usr/local/bin/text-embeddings-router

ENTRYPOINT ["text-embeddings-router"]
CMD ["--json-output"]

FROM base AS http

COPY --from=http-builder /usr/src/target/release/text-embeddings-router /usr/local/bin/text-embeddings-router

# Amazon SageMaker compatible image
FROM http AS sagemaker
COPY --chmod=775 sagemaker-entrypoint.sh entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]

# Default image
FROM http

ENTRYPOINT ["text-embeddings-router"]
CMD ["--json-output"]
