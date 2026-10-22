FROM ghcr.io/xtls/xray-core:latest AS xray

FROM envoyproxy/envoy:v1.35-latest

COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY config.template.json /etc/xray/config.template.json
COPY envoy.yaml /etc/envoy/envoy.yaml
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
