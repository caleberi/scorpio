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
    unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY build.zig build.zig.zon ./
COPY vendor/zap.zip ./vendor/zap.zip
RUN unzip -q vendor/zap.zip -d vendor \
    && rm -f vendor/zap.zip

# pg.zig pulls translate-c from Codeberg over git+https. Zig's git client
# fails there with ProtocolError; the GitHub archive is the same commit/hash.
RUN zig fetch "https://github.com/ziglang/translate-c/archive/57c559cf581b1fcad90494eda219f98abeb155ce.tar.gz"

COPY src ./src
COPY libraries ./libraries
COPY common ./common

# Portable CPU: native features from the build host SIGILL on Render (exit 132).
RUN zig build -Doptimize=ReleaseSafe -Dcpu=baseline


FROM node:${NODE_VERSION}-bookworm-slim AS web-build

WORKDIR /web

# Render injects NODE_ENV=production and NPM_CONFIG_PRODUCTION=true at
# build time. Those omit packages unless we force a full install.
COPY web/package.json web/package-lock.json web/.npmrc ./
RUN NPM_CONFIG_PRODUCTION=false NPM_CONFIG_OMIT= npm ci

COPY web/index.html web/tsconfig.json web/tsconfig.app.json web/tsconfig.node.json web/vite.config.ts ./
COPY web/src ./src
COPY web/public ./public

ENV NODE_ENV=production
RUN npm run build


FROM nginx:1.31.4 AS web

COPY docker/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY docker/nginx-env.sh /docker-entrypoint.d/18-scorpio-env.envsh
COPY --from=web-build /web/dist /usr/share/nginx/html

# nginx's entrypoint sources *.envsh only when the file is executable.
RUN chmod +x /docker-entrypoint.d/18-scorpio-env.envsh

EXPOSE 80


# Last stage is the default image. Render Docker services that omit a
# target must get scorpio, not nginx.
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
COPY blobs ./blobs
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
    BLOG_PREFETCH_NEIGHBORS=1

EXPOSE 9090
ENTRYPOINT ["/entrypoint.sh"]
