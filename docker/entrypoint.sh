#!/bin/sh
set -eu

cd /app

# scorpio/prerun/pack-blog read .env only, not the process environment.
# Render injects DATABASE_URL (linked Postgres) and PORT; Dockerfile ENV used
# to pin DB_URL to the Compose host, which hid those values.
sync_runtime_env() {
    if [ -z "${DB_URL:-}" ] && [ -n "${DATABASE_URL:-}" ]; then
        DB_URL=$DATABASE_URL
    fi
    if [ -n "${PORT:-}" ]; then
        SERVER_PORT=$PORT
    fi
    export DB_URL SERVER_PORT
}

write_kv() {
    printf '%s=%s\n' "$1" "$2"
}

write_env() {
    {
        write_kv SERVER_PORT "${SERVER_PORT:-9090}"
        write_kv SERVER_THREADS "${SERVER_THREADS:-2}"
        write_kv SERVER_WORKERS "${SERVER_WORKERS:-1}"
        write_kv LOG_LEVEL "${LOG_LEVEL:-info}"
        write_kv BLOG_INPUT_DIR "${BLOG_INPUT_DIR:-pages}"
        write_kv BLOG_PACK_DIR "${BLOG_PACK_DIR:-packed/blog}"
        write_kv BLOG_STAGING_DIR "${BLOG_STAGING_DIR:-packed/staging}"
        write_kv BLOG_PREFETCH_NEIGHBORS "${BLOG_PREFETCH_NEIGHBORS:-1}"
        write_kv CLOUDINARY_CLOUDNAME "${CLOUDINARY_CLOUDNAME:-demo}"
        write_kv CLOUDINARY_API_KEY "${CLOUDINARY_API_KEY:-key}"
        write_kv CLOUDINARY_API_SECRET "${CLOUDINARY_API_SECRET:-secret}"
        write_kv CLOUDINARY_PACK_PREFIX "${CLOUDINARY_PACK_PREFIX:-scorpio/blog/packed}"
        write_kv DB_URL "${DB_URL:-postgresql://postgres:postgres@postgres:5432/scorpio}"
    } > .env
}

host_from_db_url() {
    # postgresql://user:pass@host:port/db  or  postgresql://user:pass@host/db
    echo "${DB_URL:-}" | sed -n 's|.*@\([^:/]*\).*|\1|p'
}

port_from_db_url() {
    echo "${DB_URL:-}" | sed -n 's|.*@[^:]*:\([0-9][0-9]*\).*|\1|p'
}

wait_for_postgres() {
    host="$(host_from_db_url)"
    host="${host:-${DB_HOST:-postgres}}"
    port="$(port_from_db_url)"
    port="${port:-${DB_PORT:-5432}}"
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

sync_runtime_env
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
