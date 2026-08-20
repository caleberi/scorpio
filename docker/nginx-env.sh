#!/bin/sh
# Sourced by the nginx image before envsubst. Keep this POSIX and export-only.

# Render injects PORT; Compose publishes 8080:80.
export LISTEN_PORT="${LISTEN_PORT:-${PORT:-80}}"

# Compose service hostname. On Render, set to the API private URL, e.g. http://scorpio-api:9090
export API_UPSTREAM="${API_UPSTREAM:-http://api:9090}"

if [ -z "${NGINX_RESOLVER:-}" ]; then
    NGINX_RESOLVER="$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf)"
fi
export NGINX_RESOLVER="${NGINX_RESOLVER:-127.0.0.11}"

# Do not let envsubst rewrite nginx variables ($host, $uri, …).
export NGINX_ENVSUBST_FILTER="${NGINX_ENVSUBST_FILTER:-LISTEN_PORT|API_UPSTREAM|NGINX_RESOLVER}"
