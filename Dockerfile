# syntax=docker/dockerfile:1

ARG ZIG_VERSION=0.16.0
ARG NODE_VERSION=22

FROM debian:stable-slim AS zig

ARG ZIG_VERSION
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && case "${TARGETARCH}" in \
    amd64|x86_64) ZIG_ARCH=x86_64 ;; \
    arm64|aarch64) ZIG_ARCH=aarch64 ;; \
    *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL --retry 5 \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    -o /tmp/zig.tar.xz \
    && mkdir -p /usr/local/zig \
    && tar -xJf /tmp/zig.tar.xz -C /usr/local/zig --strip-components=1 \
    && ln -sf /usr/local/zig/zig /usr/local/bin/zig \
    && rm -f /tmp/zig.tar.xz


FROM zig AS api-build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY build.zig build.zig.zon ./
RUN zig fetch --save "git+https://github.com/zigzap/zap#v0.10.6"

COPY src ./src
COPY libraries ./libraries
COPY common ./common

RUN zig build -Doptimize=ReleaseSafe


FROM node:${NODE_VERSION}-bookworm-slim AS web-build

WORKDIR /web

COPY web/package.json web/package-lock.json ./
RUN npm ci

COPY web ./
RUN npm run build


FROM debian:stable-slim AS api

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=api-build /src/zig-out/bin/scorpio /usr/local/bin/scorpio
COPY --from=api-build /src/zig-out/bin/pack-blog /usr/local/bin/pack-blog
COPY --from=api-build /src/zig-out/bin/prerun /usr/local/bin/prerun
COPY docker/entrypoint.sh /entrypoint.sh
COPY pages ./pages
COPY sql ./sql

RUN chmod +x /entrypoint.sh \
    && mkdir -p packed/blog packed/staging

ENV SERVER_PORT=9090 \
    SERVER_THREADS=2 \
    SERVER_WORKERS=1 \
    LOG_LEVEL=info \
    BLOG_INPUT_DIR=pages \
    BLOG_PACK_DIR=packed/blog \
    BLOG_STAGING_DIR=packed/staging \
    BLOG_PREFETCH_NEIGHBORS=1 \
    DB_URL=postgresql://postgres:postgres@postgres:5432/scorpio \
    DB_HOST=postgres \
    DB_PORT=5432

EXPOSE 9090
ENTRYPOINT ["/entrypoint.sh"]


FROM nginx:1.34.1 AS web

COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=web-build /web/dist /usr/share/nginx/html

EXPOSE 80
