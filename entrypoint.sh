#!/bin/bash
# Site Steward supervisor — starts Mosquitto → Influx → Telegraf → time sidecar
# → Grafana → Node portal on :80, and tears everything down if any child dies.
set -euo pipefail

STATUS_PORT="${STATUS_PORT:-80}"
CONTROL_PORT="${CONTROL_PORT:-80}"
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-blueos/}"
MQTT_ROOT="${MQTT_ROOT:-blueos}"
INFLUX_DB="${INFLUXDB_DB:-esphome}"
MOSQUITTO_DATA="${MOSQUITTO_DATA:-/mosquitto/data}"
MOSQUITTO_CONF="${MOSQUITTO_CONF:-/mosquitto/config/mosquitto.conf}"
GRAFANA_PORT="${GF_SERVER_HTTP_PORT:-${GRAFANA_PORT:-3000}}"
TIME_STATUS_TOPIC="${TIME_STATUS_TOPIC:-blueos/ext/site-steward/json}"

export MQTT_HOST MQTT_PORT MQTT_TOPIC_PREFIX MQTT_ROOT GRAFANA_PORT \
       CONTROL_PORT TIME_STATUS_TOPIC

mkdir -p "$MOSQUITTO_DATA" /mosquitto/log /var/lib/grafana /var/log/grafana \
         /var/lib/grafana/plugins
chown -R grafana:grafana /var/lib/grafana /var/log/grafana || true

TELEGRAF_CONF=/tmp/telegraf.conf
sed \
  -e "s|\${MQTT_HOST}|${MQTT_HOST}|g" \
  -e "s|\${MQTT_PORT}|${MQTT_PORT}|g" \
  -e "s|\${MQTT_TOPIC_PREFIX}|${MQTT_TOPIC_PREFIX}|g" \
  /etc/telegraf/telegraf.conf > "$TELEGRAF_CONF"

cat > /system-www/runtime.json <<EOF
{
  "service": "blueos-site-steward",
  "version": "0.1.0",
  "influx_version": "1.8",
  "database": "${INFLUX_DB}",
  "auth": false,
  "mqtt_tcp": ${MQTT_PORT},
  "mqtt_websockets": 9001,
  "mqtt_anonymous": true,
  "mqtt_topic_prefix": "${MQTT_TOPIC_PREFIX}",
  "grafana_port": ${GRAFANA_PORT},
  "time_status_topic": "${TIME_STATUS_TOPIC}"
}
EOF

echo "[steward] Starting Mosquitto with ${MOSQUITTO_CONF}..."
mosquitto -c "$MOSQUITTO_CONF" &
MQTT_PID=$!

echo "[steward] Waiting for Mosquitto on ${MQTT_HOST}:${MQTT_PORT}..."
for _ in $(seq 1 30); do
  if mosquitto_sub -h 127.0.0.1 -p "$MQTT_PORT" -t '$SYS/broker/version' -C 1 -W 2 >/dev/null 2>&1; then
    echo "[steward] Mosquitto is up"
    break
  fi
  if ! kill -0 "$MQTT_PID" 2>/dev/null; then
    echo "[steward] Mosquitto exited early" >&2
    wait "$MQTT_PID" || true
    exit 1
  fi
  sleep 1
done

echo "[steward] Starting InfluxDB 1.8 (database=${INFLUX_DB})..."
INFLUXDB_CONFIG_PATH=/etc/influxdb/influxdb.conf \
  /influxdb-entrypoint.sh influxd -config /etc/influxdb/influxdb.conf &
INFLUX_PID=$!

echo "[steward] Waiting for InfluxDB..."
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:8086/ping" >/dev/null 2>&1; then
    echo "[steward] InfluxDB is up"
    break
  fi
  if ! kill -0 "$INFLUX_PID" 2>/dev/null; then
    echo "[steward] InfluxDB exited early" >&2
    wait "$INFLUX_PID" || true
    exit 1
  fi
  sleep 2
done

if ! curl -sf "http://127.0.0.1:8086/ping" >/dev/null 2>&1; then
  echo "[steward] InfluxDB failed to become ready" >&2
  exit 1
fi

curl -sf "http://127.0.0.1:8086/query" --data-urlencode "q=CREATE DATABASE ${INFLUX_DB}" >/dev/null || true

echo "[steward] Starting Telegraf → MQTT ${MQTT_HOST}:${MQTT_PORT} (${MQTT_TOPIC_PREFIX}#) → InfluxDB ${INFLUX_DB}..."
telegraf --config "$TELEGRAF_CONF" &
TELEGRAF_PID=$!

echo "[steward] Starting time-from-RTC sidecar (enable=${TIME_SYNC_ENABLE:-true})..."
MQTT_HOST=127.0.0.1 MQTT_PORT="$MQTT_PORT" MQTT_TOPIC_PREFIX="$MQTT_TOPIC_PREFIX" \
TIME_SYNC_STATUS_TOPIC="$TIME_STATUS_TOPIC" \
  python3 /opt/blueos/time_from_rtc.py &
TIME_SYNC_PID=$!

echo "[steward] Starting Grafana on :${GRAFANA_PORT} (as uid 472)..."
chown -R grafana:grafana /var/lib/grafana /var/log/grafana || true
runuser -u grafana -- /usr/share/grafana/bin/grafana server \
  --homepath=/usr/share/grafana \
  --config=/etc/grafana/grafana.ini \
  cfg:default.paths.data=/var/lib/grafana \
  cfg:default.paths.logs=/var/log/grafana \
  cfg:default.paths.plugins=/var/lib/grafana/plugins \
  cfg:default.paths.provisioning=/etc/grafana/provisioning &
GRAFANA_PID=$!

echo "[steward] Waiting for Grafana..."
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
    echo "[steward] Grafana is up"
    break
  fi
  if ! kill -0 "$GRAFANA_PID" 2>/dev/null; then
    echo "[steward] Grafana exited early" >&2
    wait "$GRAFANA_PID" || true
    exit 1
  fi
  sleep 2
done

echo "[steward] Starting portal (MQTT ${MQTT_HOST}:${MQTT_PORT}, root ${MQTT_ROOT}) on :${CONTROL_PORT}..."
node /app/control-ui/server.js &
CONTROL_PID=$!

shutdown() {
  echo "[steward] Shutting down..."
  kill "$CONTROL_PID" "$GRAFANA_PID" "$TELEGRAF_PID" "$TIME_SYNC_PID" \
       "$INFLUX_PID" "$MQTT_PID" 2>/dev/null || true
  wait "$CONTROL_PID" "$GRAFANA_PID" "$TELEGRAF_PID" "$TIME_SYNC_PID" \
       "$INFLUX_PID" "$MQTT_PID" 2>/dev/null || true
}
trap shutdown INT TERM

while kill -0 "$MQTT_PID" 2>/dev/null \
  && kill -0 "$INFLUX_PID" 2>/dev/null \
  && kill -0 "$TELEGRAF_PID" 2>/dev/null \
  && kill -0 "$GRAFANA_PID" 2>/dev/null \
  && kill -0 "$CONTROL_PID" 2>/dev/null; do
  sleep 2
done

echo "[steward] A child process exited; shutting down." >&2
shutdown
exit 1
