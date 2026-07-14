# Site Steward — one BlueOS extension for MQTT + history + controls + Grafana

**`vshie/blueos-site-steward`** merges the two legacy BlueOS extensions
[`blueos-site-stack`](https://github.com/vshie/blueos-site-stack) (MQTT +
InfluxDB + Telegraf) and [`blueos-site-ui`](https://github.com/vshie/blueos-site-ui)
(Grafana + control page) into a **single container** with a tabbed portal so
operators install one extension instead of two.

```text
+---------------------- Site Steward (one container) ----------------------+
|                                                                          |
|  Mosquitto :1883/:9001  <---MQTT---  ESPHome boards (blueos-site-esphome)|
|         |                                                                |
|         v                                                                |
|      Telegraf ---> InfluxDB 1.8 :8086 ---> Grafana :3000                 |
|                                                     ^                    |
|         time_from_rtc.py -->  blueos/ext/site-steward/json               |
|                                                                          |
|                        Portal :80 (Express + tabs)                       |
|                        ├─ Controls (device grid, schedules, labels)      |
|                        ├─ System   (broker/Influx/Telegraf/time status)  |
|                        └─ Graphs   (full-height Grafana embed)           |
+--------------------------------------------------------------------------+
```

The old two-repo split — `blueos-site-stack` and `blueos-site-ui` — is now
**deprecated**; both READMEs point here. The `blueos-site-esphome` extension is
unchanged (still separate) and pairs with Site Steward as the MQTT broker.

## What's inside

| Component | Source |
|-----------|--------|
| MQTT broker | Debian `mosquitto` on ports `1883` (TCP) + `9001` (WebSockets) |
| Time-series DB | Official [`influxdb:1.8.10`](https://hub.docker.com/_/influxdb) — DB `esphome`, HTTP API on `:8086` |
| Metrics agent | Binary copied from official [`telegraf:1.32`](https://hub.docker.com/_/telegraf) |
| Dashboards | [`grafana/grafana-oss:11.3.0`](https://hub.docker.com/r/grafana/grafana-oss) binaries + provisioning, on `:3000` |
| Portal | Node 20 (via NodeSource) + Express + `mqtt.js` + `ws` + `http-proxy-middleware`, on `:80` |
| Time sidecar | `scripts/time_from_rtc.py` — corrects host clock from ESP DS3231 when there's no internet, requires `CAP_SYS_TIME` |

All services run in the same container and talk over `127.0.0.1`; the only
network dependency is the ESP boards on the LAN publishing MQTT to the Pi.

## Coexistence warning

Site Steward binds the same host ports the legacy extensions used (`1883`,
`9001`, `8086`, `3000`). **You cannot run Site Steward alongside `blueos-site-stack`
or `blueos-site-ui`** — remove/disable both before installing this one, or the
container will fail to bind ports.

## Manual install on BlueOS (copy-paste)

Install **only** through BlueOS → **Extensions** → **Installed** → **+**. Do
**not** use a bare `docker run` — that skips Kraken registration and the
extension won't respawn on BlueOS reboot.

### 1. Uninstall the legacy pair first

If the Pi already has them installed, remove or disable:

| Old extension | Conflict |
|---------------|----------|
| `vshie/blueos-site-stack` | `:1883`, `:9001`, `:8086` |
| `vshie/blueos-site-ui`    | `:80` (dynamic), `:3000` |

Data volumes on disk are **not** migrated automatically — see
[Data migration](#data-migration-from-the-legacy-extensions) below if you want
to keep history.

### 2. Fill the install form

Open BlueOS → **Extensions** → **Installed** → **+** (bottom right) and enter:

| Field | Value |
|-------|--------|
| **Extension Identifier** | `vshie.sitesteward` |
| **Extension Name** | `Site Steward` |
| **Docker image** | `vshie/blueos-site-steward` |
| **Docker tag** | `main` |

### 3. Custom settings (permissions JSON)

Paste this JSON verbatim into **Custom settings**:

```json
{
  "ExposedPorts": {
    "80/tcp": {},
    "1883/tcp": {},
    "9001/tcp": {},
    "8086/tcp": {},
    "3000/tcp": {}
  },
  "HostConfig": {
    "ExtraHosts": ["host.docker.internal:host-gateway"],
    "CapAdd": ["SYS_TIME"],
    "PortBindings": {
      "80/tcp": [
        {
          "HostPort": ""
        }
      ],
      "1883/tcp": [
        {
          "HostPort": "1883"
        }
      ],
      "9001/tcp": [
        {
          "HostPort": "9001"
        }
      ],
      "8086/tcp": [
        {
          "HostPort": "8086"
        }
      ],
      "3000/tcp": [
        {
          "HostPort": "3000"
        }
      ]
    },
    "Binds": [
      "/usr/blueos/extensions/site-steward/mosquitto:/mosquitto/data",
      "/usr/blueos/extensions/site-steward/influxdb:/var/lib/influxdb",
      "/usr/blueos/extensions/site-steward/grafana:/var/lib/grafana"
    ]
  }
}
```

Then confirm / install and wait for the image pull.

### 4. Verify

1. **Installed tab** — you should see **Site Steward** listed and enabled.
2. Click **Open** → the portal loads with three tabs: **Controls**, **System**,
   **Graphs**.
3. From a laptop on the same LAN:

   ```bash
   mosquitto_sub -h <blueos-ip> -t '#' -v
   curl "http://<blueos-ip>:8086/query?db=esphome" --data-urlencode "q=SHOW MEASUREMENTS"
   curl "http://<blueos-ip>:3000/api/health"
   ```

## Ports

| Port | Binding | Use |
|------|---------|-----|
| `80` | Dynamic (`HostPort: ""`) | Portal — Controls / System / Graphs (BlueOS sidebar "Open") |
| `1883` | Host `1883` | MQTT TCP (ESPHome, `mosquitto_sub`, other extensions) |
| `9001` | Host `9001` | MQTT over WebSockets |
| `8086` | Host `8086` | InfluxDB HTTP API |
| `3000` | Host `3000` | Grafana UI (also embedded in Graphs tab) |

## Data migration from the legacy extensions

Site Steward doesn't auto-migrate at runtime — the container will happily start
with empty volumes. If you had `blueos-site-stack` + `blueos-site-ui`
installed and want to keep MQTT retained topics / Influx history / Grafana
state, copy the directories on the BlueOS host **before** first-installing
Site Steward:

```bash
# On the Pi (as root or via BlueOS terminal):
mkdir -p /usr/blueos/extensions/site-steward
cp -a /usr/blueos/extensions/site-stack/mosquitto \
      /usr/blueos/extensions/site-steward/mosquitto
cp -a /usr/blueos/extensions/site-stack/influxdb \
      /usr/blueos/extensions/site-steward/influxdb
cp -a /usr/blueos/extensions/site-ui \
      /usr/blueos/extensions/site-steward/grafana
chown -R 472:472 /usr/blueos/extensions/site-steward/grafana
```

Then install Site Steward as above. ESP boards **do not** need reflashing —
they still publish to `blueos/<device>/…` on `:1883`, which Site Steward's
Mosquitto owns.

## Portal — three tabs

| Tab | Content |
|-----|---------|
| **Controls** | The former Site Controls: device grid (relays / sensors / RTC sync), per-relay daily schedules, friendly-label rename, board list. |
| **System** | Live health of the broker / Influx / Telegraf / time source (from `/api/health` + `/system/runtime.json`), plus the topic convention cheat-sheet. |
| **Graphs** | Full-height iframe of the provisioned Grafana dashboard (`blueos-esp-sensors`, kiosk mode). |

The portal exposes `/register_service` so **Site Steward** appears in the
BlueOS sidebar under [`/extensionv2/sitesteward/`](https://blueos.cloud/docs/latest/development/extensions/#web-interface-http-server)
with `works_in_relative_paths: true`, and API calls use the `extBase()`/`api()`
helpers so relative-path prefixing keeps working under BlueOS's proxy.

The `/grafana/*` route reverse-proxies to `127.0.0.1:3000` (via
`http-proxy-middleware`, WS-aware). For the highest fidelity the **Graphs** tab
loads Grafana directly from `location.hostname:3000` (host-port `3000` bind);
the reverse proxy is a fallback for embeds and deep-linked API calls that need
to stay under the extension prefix.

## MQTT topic convention

The steward's Telegraf subscribes to `blueos/#` with these patterns — any
publisher that follows this shape is auto-ingested into the `esphome` DB with
no config changes. The prefix (`blueos/`) is configurable via
`MQTT_TOPIC_PREFIX`.

### ESPHome devices (default ESPHome MQTT topics)

| Topic pattern | Meaning | Influx measurement |
|----------------|---------|---------------------|
| `blueos/<node_id>/sensor/<object_id>/state` | Numeric sensor | `esphome_sensor` |
| `blueos/<node_id>/switch/<object_id>/state` | ON/OFF | `esphome_switch` |
| `blueos/<node_id>/binary_sensor/<object_id>/state` | ON/OFF | `esphome_switch` |
| `blueos/<node_id>/status` | Online/offline (LWT) | `esphome_status` |

### Other BlueOS extensions

| Topic pattern | Meaning | Auto-ingested? |
|----------------|---------|-----------------|
| `blueos/ext/<slug>/<metric>/state` | One numeric metric | Yes → `blueos_ext_metric` |
| `blueos/ext/<slug>/json` | Structured JSON (multiple fields) | Yes → `blueos_ext_json` |
| `blueos/ext/<slug>/status` | Online/offline | Yes → `esphome_status` |

The steward publishes its own time-sync status on
`blueos/ext/site-steward/json` (formerly `blueos/ext/site-stack/json`) — that
rename is the reason ESP firmware needs no changes, but any downstream
consumers hard-coding the old topic must update.

## Time sync — true timestamps without internet

Same design as the legacy `blueos-site-stack`: Raspberry Pi has no RTC, so
if there's no internet at boot every Telegraf/Influx timestamp is wrong. The
`scripts/time_from_rtc.py` sidecar (stdlib-only, no pip deps):

1. Subscribes to `blueos/+/sensor/rtc_epoch/state` (any ESPHome node with a
   DS3231, e.g. `blueos-relay`).
2. Every 30 s, checks whether the container can reach the internet. If yes,
   trusts the host's NTP and leaves the clock alone.
3. If there's no internet and a fresh RTC sample is available and drift > 5 s,
   corrects the host clock with `date -u -s @<epoch>` (needs `CAP_SYS_TIME` —
   this extension's default permissions request it).
4. Publishes status to `blueos/ext/site-steward/json` (fields: `time_source`,
   `internet`, `drift_seconds`, `rtc_sample_age_seconds`, `clock_set_ok`).

Tunables (env vars, all optional): `TIME_SYNC_ENABLE` (`true`),
`TIME_SYNC_DRIFT_THRESHOLD_S` (`5`), `TIME_SYNC_CHECK_INTERVAL_S` (`30`),
`TIME_SYNC_MAX_SAMPLE_AGE_S` (`600`), `TIME_SYNC_INTERNET_HOSTS`,
`TIME_SYNC_TOPIC_FILTER`, `TIME_SYNC_STATUS_TOPIC`.

## Auth (LAN v0.1)

- **Grafana**: default admin login is `admin` / `admin` (change on first
  login). `GF_AUTH_ANONYMOUS_ENABLED=true` also grants anonymous **Admin**
  viewers on the LAN — acceptable for a single-site LAN v0.1 install, **not**
  for anything internet-exposed. Set `GF_AUTH_ANONYMOUS_ENABLED=false` in the
  container env to require login.
- **MQTT / InfluxDB**: anonymous LAN access. Do **not** expose ports `1883`
  or `8086` to the public internet.
- **Portal**: no auth. Mirrors Home Assistant's local network trust model —
  add a reverse-proxy / auth layer before exposing beyond LAN.

## Pairing with `blueos-site-esphome`

Install [`vshie/blueos-site-esphome`](https://github.com/vshie/blueos-site-esphome)
only when you need to flash / re-configure an ESP32 board. Its wizard reads
BlueOS Beacon to compute the MQTT broker hostname automatically, then flashes
`blueos-relay.yaml`, and the board will show up under **Controls** here. See
that extension's README for the recommended install order (Site Steward first,
then ESPHome Site).

## Building / releasing

Pushing to `main` (or a git tag) triggers `.github/workflows/deploy.yml`,
which uses [`BlueOS-community/Deploy-BlueOS-Extension@v1.2.0`](https://github.com/BlueOS-community/Deploy-BlueOS-Extension)
to build + push multi-arch images to Docker Hub.

| Platform | Hardware |
|----------|----------|
| `linux/arm/v7` | Raspberry Pi 3B+, Pi 4 32-bit BlueOS |
| `linux/arm64/v8` | Raspberry Pi 4 64-bit, **Raspberry Pi 5** |
| `linux/amd64` | Desktop / CI smoke |

**Repository secrets required:** https://github.com/vshie/blueos-site-steward/settings/secrets/actions

- `DOCKER_USERNAME` = `vshie`
- `DOCKER_PASSWORD` = Docker Hub [access token](https://hub.docker.com/settings/security)
  (same token used by `blueos-site-stack` / `blueos-site-ui` can be reused —
  it just needs push access to the new `vshie/blueos-site-steward` repo).

Until those secrets are added to *this* repo's Actions secrets, CI will fail
at the push-to-Docker-Hub step. The Dockerfile and Node app are still fully
usable for a local build in the meantime.

Published as: **`vshie/blueos-site-steward:<branch-or-tag>`**.

## Local development

```bash
docker build -t blueos-site-steward:local .
docker run --rm \
  --cap-add=SYS_TIME \
  --add-host=host.docker.internal:host-gateway \
  -p 1883:1883 -p 9001:9001 -p 8086:8086 -p 3000:3000 -p 8080:80 \
  blueos-site-steward:local
# open http://localhost:8080 for the portal
# open http://localhost:3000 for direct Grafana
# open http://localhost:8086/query?q=SHOW+DATABASES for Influx
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MQTT_HOST` | `127.0.0.1` | Broker host (leave localhost — the broker is in this same container) |
| `MQTT_PORT` | `1883` | Broker port |
| `MQTT_ROOT` | `blueos` | Topic root to subscribe/discover (`<root>/#`) |
| `MQTT_TOPIC_PREFIX` | `blueos/` | Prefix for Telegraf / RTC sidecar substitution |
| `CONTROL_PORT` | `80` | Portal HTTP+WS port (internal) |
| `GF_SERVER_HTTP_PORT` / `GRAFANA_PORT` | `3000` | Grafana port |
| `GF_AUTH_ANONYMOUS_ENABLED` | `true` | LAN v0.1 default; set `false` to require login |
| `GF_SECURITY_ALLOW_EMBEDDING` | `true` | Required for the Graphs tab iframe |
| `INFLUXDB_DB` | `esphome` | Auto-created database |
| `TIME_SYNC_ENABLE` | `true` | Disable the RTC time sidecar entirely |
| `TIME_STATUS_TOPIC` | `blueos/ext/site-steward/json` | Time sidecar status topic (portal subscribes here) |

## License

Extension packaging: community BlueOS extension conventions.  
Mosquitto (upstream): [EPL-2.0](https://www.eclipse.org/legal/epl-2.0/) /
[EDL-1.0](https://www.eclipse.org/org/documents/edl-v10.php).  
InfluxDB and Telegraf: upstream MIT.  
Grafana OSS: [AGPLv3](https://github.com/grafana/grafana/blob/main/LICENSE).  
Portal app: MIT (this repo).
