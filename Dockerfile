FROM ghcr.io/xtls/xray-core:latest AS xray

FROM alpine:3.22
RUN apk add --no-cache ca-certificates gettext
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
# Required by the geoip:cn routing rule in config.template.json.
COPY --from=xray /usr/local/share/xray/geoip.dat /usr/local/share/xray/geoip.dat
COPY config.template.json /etc/xray/config.template.json
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PORT=8080
ENV XRAY_PORT=8080
ENV VLESS_UUID=36459fd0-0c89-4733-b20e-067ffc341bd2
ENV WS_PATH=/

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
