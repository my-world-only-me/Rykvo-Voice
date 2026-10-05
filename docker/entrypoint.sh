#!/bin/sh
set -eu

: "${DATABASE_URL:?DATABASE_URL is required}"

count=0
until rykvo-auth -migrate; do
    count=$((count + 1))
    if [ "$count" -ge 30 ]; then
        echo 'Database unreachable' >&2
        exit 1
    fi
    sleep 2
done

admin_password=${RYKVO_ADMIN_PASSWORD:-}
if [ -n "${RYKVO_ADMIN_PASSWORD_FILE:-}" ] && [ -r "$RYKVO_ADMIN_PASSWORD_FILE" ]; then
    admin_password=$(cat "$RYKVO_ADMIN_PASSWORD_FILE")
fi
if [ -n "$admin_password" ]; then
    printf '%s' "$admin_password" | rykvo-auth -init
fi

visibility_password=${RYKVO_VISIBILITY_PASSWORD:-}
if [ -n "${RYKVO_VISIBILITY_PASSWORD_FILE:-}" ] && [ -r "$RYKVO_VISIBILITY_PASSWORD_FILE" ]; then
    visibility_password=$(cat "$RYKVO_VISIBILITY_PASSWORD_FILE")
fi
if [ -n "$visibility_password" ]; then
    printf '%s' "$visibility_password" | rykvo-auth -init-visibility
fi
unset admin_password visibility_password RYKVO_ADMIN_PASSWORD RYKVO_ADMIN_PASSWORD_FILE \
    RYKVO_VISIBILITY_PASSWORD RYKVO_VISIBILITY_PASSWORD_FILE

rykvo-auth &
backend=$!

nginx -g 'daemon off;' &
web=$!

trap 'kill "$backend" "$web" 2>/dev/null || true' TERM INT

while kill -0 "$backend" 2>/dev/null && kill -0 "$web" 2>/dev/null; do
    sleep 2
done
exit 1
