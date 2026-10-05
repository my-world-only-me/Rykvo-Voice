# syntax=docker/dockerfile:1
FROM golang:1.27.1-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY VERSION .
COPY backend/ ./backend/
WORKDIR /src/backend
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w -X main.buildVersion=$(cat /src/VERSION)" -o /out/rykvo-auth .

# 下载钉版 cloudflared / sing-box（校验和见 deploy/runtime.json）
FROM alpine:3.22 AS bins
ARG TARGETARCH
RUN apk add --no-cache python3 ca-certificates
COPY deploy/runtime.json /tmp/runtime.json
RUN TARGETARCH=${TARGETARCH} python3 - <<'PY'
import hashlib, io, json, os, pathlib, tarfile, urllib.request
arch = os.environ['TARGETARCH']
cfg = json.loads(pathlib.Path('/tmp/runtime.json').read_text())
out = pathlib.Path('/out'); out.mkdir()
def fetch(url, expect):
    data = urllib.request.urlopen(url, timeout=300).read()
    if hashlib.sha256(data).hexdigest() != expect:
        raise SystemExit('checksum mismatch: ' + url)
    return data
cf = cfg['cloudflared']
(out / 'cloudflared').write_bytes(fetch(
    f"https://github.com/cloudflare/cloudflared/releases/download/{cf['version']}/cloudflared-linux-{arch}",
    cf[arch]))
sb = cfg['sing-box']
tgz = fetch(
    f"https://github.com/SagerNet/sing-box/releases/download/v{sb['version']}/sing-box-{sb['version']}-linux-{arch}.tar.gz",
    sb[arch])
with tarfile.open(fileobj=io.BytesIO(tgz), mode='r:gz') as t:
    (out / 'sing-box').write_bytes(t.extractfile(f"sing-box-{sb['version']}-linux-{arch}/sing-box").read())
PY
RUN chmod 0755 /out/*

# 运行层：与宿主机部署同布局 /opt/rykvo-voice/live
FROM nginx:alpine
RUN apk add --no-cache python3 socat nftables iptables iproute2 wireguard-tools \
    ca-certificates tzdata libqmi pcsc-lite-libs opus opencore-amr vo-amrwbenc
COPY --from=build /out/rykvo-auth /opt/rykvo-voice/live/rykvo-auth
COPY --from=bins /out/ /opt/rykvo-voice/live/
COPY deploy/network-control.py deploy/network_runtime.py deploy/host-settings.py \
     deploy/network-drivers.py deploy/qmi-read.py deploy/sip-network.py /opt/rykvo-voice/live/
COPY VERSION UPDATE_EPOCH /opt/rykvo-voice/live/
COPY frontend/ /opt/rykvo-voice/live/web/
COPY docker/nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh /opt/rykvo-voice/live/rykvo-auth /opt/rykvo-voice/live/cloudflared \
               /opt/rykvo-voice/live/sing-box \
 && printf '#!/bin/sh\nexec python3 -I /opt/rykvo-voice/live/qmi-read.py "$@"\n' > /opt/rykvo-voice/live/qmi.sh \
 && printf '#!/bin/sh\nexec python3 -I /opt/rykvo-voice/live/host-settings.py "$@"\n' > /opt/rykvo-voice/live/host.sh \
 && printf '#!/bin/sh\nexec python3 -I /opt/rykvo-voice/live/sip-network.py "$@"\n' > /opt/rykvo-voice/live/sip.sh \
 && printf '#!/bin/sh\nexec /opt/rykvo-voice/live/rykvo-auth -hardware-wifi-worker "$@"\n' > /opt/rykvo-voice/live/wifi.sh \
 && chmod 0755 /opt/rykvo-voice/live/*.sh \
 && mkdir -p /var/lib/rykvo-voice/voice-audio /var/lib/rykvo-voice/message-results \
              /var/lib/rykvo-voice/tunnel /var/lib/rykvo-sip-network \
              /var/lib/rykvo-network /var/lib/rykvo-network-route /run/rykvo-voice
ENV WEB_ROOT=/opt/rykvo-voice/live/web
ENV PYTHONNOUSERSITE=1
EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
