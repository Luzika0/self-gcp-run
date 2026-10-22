#!/bin/sh
set -eu

: "${PORT:=8080}"
: "${XRAY_PORT:=8081}"
: "${VLESS_UUID:?VLESS_UUID must be supplied at runtime; use Docker .env or Secret Manager}"
: "${WS_PATH:=/}"

case "$XRAY_PORT" in
  *[!0-9]*|"") echo "XRAY_PORT must be a number" >&2; exit 1 ;;
esac

case "$VLESS_UUID" in
  ????????-????-????-????-????????????) ;;
  *) echo "VLESS_UUID does not look like a UUID" >&2; exit 1 ;;
esac

export XRAY_PORT VLESS_UUID WS_PATH
envsubst '${XRAY_PORT} ${VLESS_UUID} ${WS_PATH}' < /etc/xray/config.template.json > /tmp/config.json
/usr/local/bin/xray run -test -config /tmp/config.json

/usr/local/bin/xray run -config /tmp/config.json &
XRAY_PID=$!
trap 'kill "$XRAY_PID" 2>/dev/null || true' TERM INT
/gateway
