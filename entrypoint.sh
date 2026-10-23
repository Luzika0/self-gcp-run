#!/bin/sh
set -eu

: "${VLESS_UUID:?VLESS_UUID must be supplied at runtime; configure it in Cloud Run or Secret Manager}"
: "${GRPC_SERVICE_NAME:=grpc}"

case "$VLESS_UUID" in
  ????????-????-????-????-????????????) ;;
  *) echo "VLESS_UUID does not look like a UUID" >&2; exit 1 ;;
esac

case "$GRPC_SERVICE_NAME" in
  ""|*[!A-Za-z0-9_-]*)
    echo "GRPC_SERVICE_NAME must contain only letters, digits, underscores, or hyphens" >&2
    exit 1
    ;;
esac

# Escape the template variables in the sed search patterns; replace them with runtime values.
sed \
  -e "s|\${VLESS_UUID}|$VLESS_UUID|g" \
  -e "s|\${GRPC_SERVICE_NAME}|$GRPC_SERVICE_NAME|g" \
  /etc/xray/config.template.json > /tmp/xray-config.json

/usr/local/bin/xray run -test -config /tmp/xray-config.json
/usr/local/bin/xray run -config /tmp/xray-config.json &
XRAY_PID=$!

/usr/local/bin/envoy -c /etc/envoy/envoy.yaml --log-level warning &
ENVOY_PID=$!

stop_children() {
  kill "$XRAY_PID" "$ENVOY_PID" 2>/dev/null || true
}
trap stop_children TERM INT

if wait "$ENVOY_PID"; then
  STATUS=0
else
  STATUS=$?
fi

kill "$XRAY_PID" 2>/dev/null || true
wait "$XRAY_PID" 2>/dev/null || true
exit "$STATUS"
