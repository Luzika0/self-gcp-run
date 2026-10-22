FROM ghcr.io/xtls/xray-core:latest

RUN apk add --no-cache ca-certificates gettext
COPY config.template.json /etc/xray/config.template.json
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PORT=8080
ENV GRPC_SERVICE_NAME=grpc

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
