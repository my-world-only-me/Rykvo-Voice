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

FROM nginx:alpine
COPY --from=build /out/rykvo-auth /usr/local/bin/rykvo-auth
COPY frontend/ /app/web/
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY docker/entrypoint.sh /entrypoint.sh
ENV WEB_ROOT=/app/web
RUN chmod +x /entrypoint.sh \
    && mkdir -p /var/lib/rykvo-voice/voice-audio \
                /var/lib/rykvo-voice/message-results \
                /var/lib/rykvo-voice/tunnel
EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
