#!/bin/sh
set -eu

cd /app

write_env() {
    cat > .env <<EOF
SERVER_PORT=${PORT:-${SERVER_PORT:-9090}}
SERVER_THREADS=${SERVER_THREADS:-2}
SERVER_WORKERS=${SERVER_WORKERS:-1}
LOG_LEVEL=${LOG_LEVEL:-info}
BLOG_INPUT_DIR=${BLOG_INPUT_DIR:-pages}
BLOG_PACK_DIR=${BLOG_PACK_DIR:-packed/blog}
BLOG_STAGING_DIR=${BLOG_STAGING_DIR:-packed/staging}
BLOG_PREFETCH_NEIGHBORS=${BLOG_PREFETCH_NEIGHBORS:-1}
CLOUDINARY_CLOUDNAME=${CLOUDINARY_CLOUDNAME:-demo}
CLOUDINARY_API_KEY=${CLOUDINARY_API_KEY:-key}
CLOUDINARY_API_SECRET=${CLOUDINARY_API_SECRET:-secret}
CLOUDINARY_PACK_PREFIX=${CLOUDINARY_PACK_PREFIX:-scorpio/blog/packed}
DB_URL=${DB_URL:-postgresql://postgres:postgres@postgres:5432/scorpio}
EOF
}

host_from_db_url() {
    # postgresql://user:pass@host:port/db  or  postgresql://user:pass@host/db
    echo "${DB_URL:-}" | sed -n 's|.*@\([^:/]*\).*|\1|p'
}

port_from_db_url() {
    echo "${DB_URL:-}" | sed -n 's|.*@[^:]*:\([0-9][0-9]*\).*|\1|p'
}

wait_for_postgres() {
    host="${DB_HOST:-$(host_from_db_url)}"
    host="${host:-postgres}"
    port="${DB_PORT:-$(port_from_db_url)}"
    port="${port:-5432}"
    echo "waiting for postgres at ${host}:${port}"
    i=0
    while [ "$i" -lt 60 ]; do
        if pg_isready -h "$host" -p "$port" -q; then
            echo "postgres is ready"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    echo "postgres did not become ready in time" >&2
    return 1
}

write_env
wait_for_postgres

mkdir -p "${BLOG_PACK_DIR:-packed/blog}" "${BLOG_STAGING_DIR:-packed/staging}"

if [ "${FORCE_PACK:-0}" = "1" ] || [ ! -f "${BLOG_PACK_DIR:-packed/blog}/manifest.json" ]; then
    echo "packing blog content"
    pack-blog
fi

echo "running prerun"
prerun

echo "starting scorpio"
exec scorpio
