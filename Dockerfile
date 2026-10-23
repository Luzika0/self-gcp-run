FROM ghcr.io/xtls/xray-core:latest AS xray

FROM envoyproxy/envoy:v1.35-latest

COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
# Required by the geoip:cn routing rule in config.template.json.
COPY --from=xray /usr/local/share/xray/geoip.dat /usr/local/share/xray/geoip.dat
COPY config.template.json /etc/xray/config.template.json
COPY envoy.yaml /etc/envoy/envoy.yaml
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
    && /usr/local/bin/envoy --mode validate -c /etc/envoy/envoy.yaml

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
CMD []
