FROM ghcr.io/xtls/xray-core:latest

COPY config.json /etc/xray/config.json

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["xray"]
CMD ["run", "-config", "/etc/xray/config.json"]
