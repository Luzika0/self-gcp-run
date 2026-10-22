FROM ghcr.io/xtls/xray-core:latest AS xray

FROM golang:1.24-alpine AS gateway-build
WORKDIR /src
COPY gateway.go .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /gateway gateway.go

FROM alpine:3.22
RUN apk add --no-cache ca-certificates gettext
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=gateway-build /gateway /gateway
COPY config.template.json /etc/xray/config.template.json
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PORT=8080
ENV XRAY_PORT=8081
ENV VLESS_UUID=36459fd0-0c89-4733-b20e-067ffc341bd2
ENV WS_PATH=/TG-@Not_Ragnar

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
