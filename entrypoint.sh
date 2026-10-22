#!/bin/sh
set -eu

: "${PORT:=8080}"
: "${VLESS_UUID:?VLESS_UUID must be supplied at runtime; use Secret Manager on Cloud Run}"
: "${GRPC_SERVICE_NAME:=grpc}"

case "$PORT" in
  *[!0-9]*|"") echo "PORT must be a number" >&2; exit 1 ;;
esac

case "$VLESS_UUID" in
  ????????-????-????-????-????????????) ;;
  *) echo "VLESS_UUID does not look like a UUID" >&2; exit 1 ;;
esac

case "$GRPC_SERVICE_NAME" in
  ""|/*|*\?*|*\#*) echo "GRPC_SERVICE_NAME must be a non-empty service name without /, ? or #" >&2; exit 1 ;;
esac

export PORT VLESS_UUID GRPC_SERVICE_NAME
envsubst '${PORT} ${VLESS_UUID} ${GRPC_SERVICE_NAME}' < /etc/xray/config.template.json > /tmp/config.json
/usr/local/bin/xray run -test -config /tmp/config.json
exec /usr/local/bin/xray run -config /tmp/config.json
