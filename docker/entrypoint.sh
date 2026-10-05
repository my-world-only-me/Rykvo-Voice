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

rykvo-auth &
backend=$!

nginx -g 'daemon off;' &
web=$!

trap 'kill "$backend" "$web" 2>/dev/null || true' TERM INT

while kill -0 "$backend" 2>/dev/null && kill -0 "$web" 2>/dev/null; do
    sleep 2
done
exit 1
