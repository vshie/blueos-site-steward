# BlueOS extension: blueos-site-steward
# One container that supersedes blueos-site-stack + blueos-site-ui: Mosquitto,
# InfluxDB 1.8, Telegraf, Grafana, a time-from-RTC sidecar, and a tabbed
# Node/Express portal on :80 (Controls / System / Graphs).
#
# Platforms: linux/arm/v7 (Pi 3B+/4 32-bit), linux/arm64/v8 (Pi 4 64-bit / Pi 5),
# linux/amd64. InfluxDB 1.8 stays as the base because 2.x has no arm/v7 image.

FROM telegraf:1.32 AS telegraf
FROM grafana/grafana-oss:11.3.0 AS grafana

FROM influxdb:1.8.10

ARG IMAGE_NAME=site-steward
ARG AUTHOR="Tony White"
ARG AUTHOR_EMAIL="tony@bluerobotics.com"
ARG MAINTAINER="Tony White"
ARG MAINTAINER_EMAIL="tony@bluerobotics.com"
ARG REPO=vshie/blueos-site-steward
ARG OWNER=vshie

# --- Preserve the upstream Influx entrypoint (creates the DB from env). -------
RUN cp /entrypoint.sh /influxdb-entrypoint.sh

# --- Base OS packages: Mosquitto, Python, Node 20 (via NodeSource nodistro). --
# nodistro packages avoid pinning to a specific Debian codename, and are
# published for arm/v7, arm64, and amd64 alike (matches this image's platforms).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      mosquitto \
      mosquitto-clients \
      python3 \
      ca-certificates \
      curl \
      gnupg \
      util-linux \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/telegraf /mosquitto/config /mosquitto/data /mosquitto/log \
             /system-www /opt/blueos

# --- Copy Telegraf binary from its own Debian image. --------------------------
COPY --from=telegraf /usr/bin/telegraf /usr/bin/telegraf

# --- Grafana OSS: copy binaries + provisioning dirs into this Debian base. ----
# The Grafana OSS image ships a self-contained Go binary at
# /usr/share/grafana/bin/grafana and a default config at
# /etc/grafana/grafana.ini. Copying those + creating uid 472 lets us run
# `grafana server --homepath ... --config ...` here without needing the Alpine
# `/run.sh` wrapper from the upstream image.
COPY --from=grafana /usr/share/grafana /usr/share/grafana
COPY --from=grafana /etc/grafana /etc/grafana
RUN groupadd --system --gid 472 grafana \
 && useradd  --system --uid 472 --gid grafana \
      --home-dir /usr/share/grafana --shell /bin/false grafana \
 && mkdir -p /var/lib/grafana /var/log/grafana /var/lib/grafana/plugins \
             /etc/grafana/dashboards \
 && chown -R grafana:grafana /usr/share/grafana /etc/grafana \
                             /var/lib/grafana /var/log/grafana \
 && ln -sf /usr/share/grafana/bin/grafana /usr/local/bin/grafana \
 && ln -sf /usr/share/grafana/bin/grafana-server /usr/local/bin/grafana-server

# --- Node control-ui dependencies (mqtt, ws, express, http-proxy-middleware). -
WORKDIR /app/control-ui
COPY control-ui/package.json control-ui/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

# --- Application config, front end, scripts, portal. --------------------------
COPY config/telegraf.conf /etc/telegraf/telegraf.conf
COPY config/influxdb.conf /etc/influxdb/influxdb.conf
COPY config/mosquitto.conf /mosquitto/config/mosquitto.conf
COPY grafana/provisioning /etc/grafana/provisioning
COPY grafana/dashboards   /etc/grafana/dashboards
COPY system-www/ /system-www/
COPY scripts/time_from_rtc.py /opt/blueos/time_from_rtc.py
COPY control-ui/server.js control-ui/devices.seed.json ./
COPY control-ui/public ./public
COPY entrypoint.sh /blueos-entrypoint.sh
RUN chmod +x /blueos-entrypoint.sh /influxdb-entrypoint.sh /opt/blueos/time_from_rtc.py \
 && chown -R grafana:grafana /etc/grafana

# --- Runtime defaults ---------------------------------------------------------
# All services talk over 127.0.0.1 in-container. MQTT/Influx/Grafana/portal
# ports are host-bound in the permissions JSON below.
ENV INFLUXDB_DB=esphome \
    INFLUXDB_HTTP_AUTH_ENABLED=false \
    INFLUXDB_REPORTING_DISABLED=true \
    MQTT_HOST=127.0.0.1 \
    MQTT_PORT=1883 \
    MQTT_TOPIC_PREFIX=blueos/ \
    MQTT_ROOT=blueos \
    MOSQUITTO_DATA=/mosquitto/data \
    STATUS_PORT=80 \
    CONTROL_PORT=80 \
    GRAFANA_PORT=3000 \
    GF_SERVER_HTTP_PORT=3000 \
    GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
    GF_PATHS_DATA=/var/lib/grafana \
    GF_PATHS_LOGS=/var/log/grafana \
    GF_PATHS_PLUGINS=/var/lib/grafana/plugins \
    GF_AUTH_ANONYMOUS_ENABLED=true \
    GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
    GF_AUTH_DISABLE_LOGIN_FORM=false \
    GF_SECURITY_ALLOW_EMBEDDING=true \
    GF_ANALYTICS_REPORTING_ENABLED=false \
    GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    TIME_SYNC_ENABLE=true \
    TIME_SYNC_DRIFT_THRESHOLD_S=5 \
    TIME_SYNC_CHECK_INTERVAL_S=30 \
    TIME_STATUS_TOPIC=blueos/ext/site-steward/json \
    TIME_SYNC_STATUS_TOPIC=blueos/ext/site-steward/json

EXPOSE 80/tcp 1883/tcp 9001/tcp 8086/tcp 3000/tcp

LABEL version="0.1.0"
LABEL type="other"
LABEL tags='["mqtt","broker","influxdb","telegraf","grafana","esphome","timeseries","automation","iot","site-steward"]'
LABEL requirements="core >= 1.1"

LABEL permissions='\
{\
  "ExposedPorts": {\
    "80/tcp": {},\
    "1883/tcp": {},\
    "9001/tcp": {},\
    "8086/tcp": {},\
    "3000/tcp": {}\
  },\
  "HostConfig": {\
    "ExtraHosts": ["host.docker.internal:host-gateway"],\
    "CapAdd": ["SYS_TIME"],\
    "PortBindings": {\
      "80/tcp": [{"HostPort": ""}],\
      "1883/tcp": [{"HostPort": "1883"}],\
      "9001/tcp": [{"HostPort": "9001"}],\
      "8086/tcp": [{"HostPort": "8086"}],\
      "3000/tcp": [{"HostPort": "3000"}]\
    },\
    "Binds": [\
      "/usr/blueos/extensions/site-steward/mosquitto:/mosquitto/data",\
      "/usr/blueos/extensions/site-steward/influxdb:/var/lib/influxdb",\
      "/usr/blueos/extensions/site-steward/grafana:/var/lib/grafana"\
    ]\
  }\
}'

LABEL authors='[{"name": "Tony White", "email": "tony@bluerobotics.com"}]'
LABEL company='{\
  "about": "Site Steward: MQTT hub, history, Grafana, and controls in one BlueOS extension.",\
  "name": "Community",\
  "email": "tony@bluerobotics.com"\
}'
LABEL readme="https://raw.githubusercontent.com/${REPO}/{tag}/README.md"
LABEL links='{\
  "source": "https://github.com/vshie/blueos-site-steward",\
  "documentation": "https://github.com/vshie/blueos-site-steward/blob/main/README.md"\
}'

LABEL org.blueos.image-name="${IMAGE_NAME}"
LABEL org.blueos.authors="[{\"name\": \"${AUTHOR}\", \"email\": \"${AUTHOR_EMAIL}\"}]"
LABEL org.blueos.company="{\"about\": \"Site Steward — merged MQTT/Influx/Telegraf/Grafana/portal for BlueOS\", \"name\": \"${MAINTAINER}\", \"email\": \"${MAINTAINER_EMAIL}\"}"

WORKDIR /app/control-ui
ENTRYPOINT ["/blueos-entrypoint.sh"]
