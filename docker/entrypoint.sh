#!/bin/sh
set -eu
LIVE=/opt/rykvo-voice/live

: "${DATABASE_URL:?DATABASE_URL is required}"

NGINX_PORT=${NGINX_PORT:-80}
RYKVO_HTTP_ADDR=${RYKVO_HTTP_ADDR:-127.0.0.1:8080}
export NGINX_PORT RYKVO_HTTP_ADDR
export NGINX_PORT
envsubst '$NGINX_PORT $RYKVO_HTTP_ADDR' < /etc/nginx/nginx.conf.template > /etc/nginx/conf.d/default.conf

count=0
until "$LIVE/rykvo-auth" -migrate; do
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
    printf '%s' "$admin_password" | "$LIVE/rykvo-auth" -init
fi

visibility_password=${RYKVO_VISIBILITY_PASSWORD:-}
if [ -n "${RYKVO_VISIBILITY_PASSWORD_FILE:-}" ] && [ -r "$RYKVO_VISIBILITY_PASSWORD_FILE" ]; then
    visibility_password=$(cat "$RYKVO_VISIBILITY_PASSWORD_FILE")
fi
if [ -n "$visibility_password" ]; then
    printf '%s' "$visibility_password" | "$LIVE/rykvo-auth" -init-visibility
fi
unset admin_password visibility_password RYKVO_ADMIN_PASSWORD RYKVO_ADMIN_PASSWORD_FILE \
    RYKVO_VISIBILITY_PASSWORD RYKVO_VISIBILITY_PASSWORD_FILE

# systemd socket activation 等价实现：socat 每连接派生一个助手进程
mkdir -p /var/lib/rykvo-voice/voice-audio /var/lib/rykvo-voice/message-results \
         /var/lib/rykvo-voice/tunnel /run/rykvo-voice
rm -f /run/rykvo-voice-qmi.sock /run/rykvo-voice-host.sock \
      /run/rykvo-voice-wifi.sock /run/rykvo-sip-network.sock
pids=''

socat UNIX-LISTEN:/run/rykvo-voice-qmi.sock,fork EXEC:$LIVE/qmi.sh &
pids="$pids $!"

socat UNIX-LISTEN:/run/rykvo-voice-host.sock,fork EXEC:$LIVE/host.sh &
pids="$pids $!"

socat UNIX-LISTEN:/run/rykvo-sip-network.sock,fork EXEC:$LIVE/sip.sh &
pids="$pids $!"

socat UNIX-LISTEN:/run/rykvo-voice-wifi.sock,fork EXEC:$LIVE/wifi.sh &
pids="$pids $!"

python3 "$LIVE/network-control.py" --cleanup >/dev/null 2>&1 || true
python3 "$LIVE/network-control.py" &
pids="$pids $!"

"$LIVE/rykvo-auth" &
pids="$pids $!"

nginx -g 'daemon off;' &
pids="$pids $!"

stop() {
    code=${1:-0}
    trap - TERM INT
    for p in $pids; do
        kill "$p" 2>/dev/null || true
    done
    for p in $pids; do
        wait "$p" 2>/dev/null || true
    done
    timeout 10 python3 "$LIVE/network-control.py" --cleanup >/dev/null 2>&1 || true
    exit "$code"
}
trap stop TERM INT

while :; do
    for p in $pids; do
        if ! kill -0 "$p" 2>/dev/null; then
            echo 'Service exited unexpectedly' >&2
            stop 1
        fi
    done
    sleep 2
done
