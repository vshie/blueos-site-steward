#!/usr/bin/env python3
"""True timestamps without internet: fall back to the ESP32 RTC over MQTT.

Problem: BlueOS/Raspberry Pi has no onboard battery-backed RTC. If there is
no internet NTP at boot, the host clock is whatever `fake-hwclock` restored
(stale) — every InfluxDB/Telegraf timestamp is then wrong for as long as
that lasts. Any ESPHome node with a DS3231 (e.g. blueos-relay) publishes an
accurate wall-clock epoch over MQTT regardless of internet access.

This sidecar:
  1. Watches `<prefix>+/sensor/rtc_epoch/state` (any ESPHome node following
     the blueos-relay convention) via the `mosquitto_sub` CLI already
     bundled in this image — no extra Python deps.
  2. Every `TIME_SYNC_CHECK_INTERVAL_S`, decides whether the *host* clock
     looks trustworthy: if this container can reach the internet, we assume
     the host's own NTP client (systemd-timesyncd/chrony) is doing its job
     and we do NOT touch the clock. Only when there's no internet AND we
     have a recent RTC sample AND the drift exceeds a threshold do we call
     `date -u -s @<epoch>` to correct it.
  3. `date -s` only succeeds if this container has the CAP_SYS_TIME
     capability (see README "Time sync" section) — without it, this script
     degrades to a harmless no-op that still reports status, so it's safe
     to ship as a default-on sidecar.
  4. Publishes its own status as `blueos/ext/site-steward/json` (matches the
     existing "other BlueOS extensions" JSON convention in this repo's
     README, so no telegraf.conf changes are needed to see it) — fields:
     `time_source`, `drift_seconds`, `internet`, `clock_set_ok`.
"""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time

MQTT_HOST = os.environ.get("MQTT_HOST", "127.0.0.1")
MQTT_PORT = os.environ.get("MQTT_PORT", "1883")
MQTT_TOPIC_PREFIX = os.environ.get("MQTT_TOPIC_PREFIX", "blueos/")
RTC_EPOCH_FILTER = os.environ.get("TIME_SYNC_TOPIC_FILTER", f"{MQTT_TOPIC_PREFIX}+/sensor/rtc_epoch/state")
STATUS_TOPIC = os.environ.get("TIME_SYNC_STATUS_TOPIC", f"{MQTT_TOPIC_PREFIX}ext/site-steward/json")

ENABLE = os.environ.get("TIME_SYNC_ENABLE", "true").strip().lower() not in ("0", "false", "no", "off")
CHECK_INTERVAL_S = float(os.environ.get("TIME_SYNC_CHECK_INTERVAL_S", "30"))
DRIFT_THRESHOLD_S = float(os.environ.get("TIME_SYNC_DRIFT_THRESHOLD_S", "5"))
MAX_SAMPLE_AGE_S = float(os.environ.get("TIME_SYNC_MAX_SAMPLE_AGE_S", "600"))
INTERNET_PROBES = os.environ.get("TIME_SYNC_INTERNET_HOSTS", "1.1.1.1:53,8.8.8.8:53,9.9.9.9:53")
INTERNET_TIMEOUT_S = float(os.environ.get("TIME_SYNC_INTERNET_TIMEOUT_S", "2"))

_lock = threading.Lock()
_latest_epoch = None  # float: RTC-reported unix epoch seconds
_latest_epoch_monotonic = None  # float: time.monotonic() when that sample arrived
_latest_epoch_topic = None
_clock_set_warned = False


def log(msg: str) -> None:
    print(f"[time-from-rtc] {msg}", flush=True)


def has_internet(probes: str, timeout: float) -> bool:
    for probe in probes.split(","):
        probe = probe.strip()
        if not probe:
            continue
        host, _, port_s = probe.rpartition(":")
        try:
            port = int(port_s)
        except ValueError:
            continue
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return True
        except OSError:
            continue
    return False


_NUMERIC_RE = re.compile(r"[-+]?\d+(?:\.\d+)?")


def parse_epoch_payload(payload: str):
    match = _NUMERIC_RE.search(payload)
    if not match:
        return None
    try:
        value = float(match.group(0))
    except ValueError:
        return None
    if value < 1_000_000_000:  # sanity: before ~2001, not a plausible epoch
        return None
    return value


def mqtt_subscriber_loop() -> None:
    """Runs `mosquitto_sub` forever, feeding the latest rtc_epoch sample."""
    global _latest_epoch, _latest_epoch_monotonic, _latest_epoch_topic
    cmd = [
        "mosquitto_sub",
        "-h", MQTT_HOST,
        "-p", str(MQTT_PORT),
        "-t", RTC_EPOCH_FILTER,
        "-v",
    ]
    while True:
        try:
            log(f"subscribing to {RTC_EPOCH_FILTER} on {MQTT_HOST}:{MQTT_PORT}")
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in proc.stdout:
                line = line.strip()
                if not line or " " not in line:
                    continue
                topic, _, payload = line.partition(" ")
                value = parse_epoch_payload(payload)
                if value is None:
                    continue
                with _lock:
                    _latest_epoch = value
                    _latest_epoch_monotonic = time.monotonic()
                    _latest_epoch_topic = topic
            proc.wait()
            log(f"mosquitto_sub exited (code {proc.returncode}), retrying in 5s")
        except FileNotFoundError:
            log("mosquitto_sub not found on PATH — time-from-RTC disabled")
            return
        except Exception as exc:  # noqa: BLE001 - keep the thread alive
            log(f"mosquitto_sub subscriber error: {exc}")
        time.sleep(5)


def current_rtc_estimate():
    """Returns (estimated_current_epoch, sample_age_s, topic) or (None, None, None)."""
    with _lock:
        epoch, mono, topic = _latest_epoch, _latest_epoch_monotonic, _latest_epoch_topic
    if epoch is None:
        return None, None, None
    age = time.monotonic() - mono
    return epoch + age, age, topic


def set_system_clock(epoch_seconds: float) -> bool:
    global _clock_set_warned
    target = int(epoch_seconds)
    try:
        result = subprocess.run(
            ["date", "-u", "-s", f"@{target}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            log(f"host clock corrected from ESP RTC -> {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(target))} UTC")
            return True
        if not _clock_set_warned:
            log(
                "could not set system clock (permission denied?) — "
                "add \"CapAdd\": [\"SYS_TIME\"] to this extension's custom "
                f"settings to enable. stderr: {result.stderr.strip()}"
            )
            _clock_set_warned = True
        return False
    except Exception as exc:  # noqa: BLE001
        if not _clock_set_warned:
            log(f"could not set system clock: {exc}")
            _clock_set_warned = True
        return False


def publish_status(payload: dict) -> None:
    try:
        subprocess.run(
            [
                "mosquitto_pub",
                "-h", MQTT_HOST,
                "-p", str(MQTT_PORT),
                "-t", STATUS_TOPIC,
                "-m", json.dumps(payload),
            ],
            capture_output=True,
            timeout=5,
        )
    except Exception as exc:  # noqa: BLE001
        log(f"could not publish status: {exc}")


def main_loop() -> None:
    log(
        f"time-from-RTC sidecar started (check every {CHECK_INTERVAL_S:.0f}s, "
        f"drift threshold {DRIFT_THRESHOLD_S:.0f}s, max sample age {MAX_SAMPLE_AGE_S:.0f}s)"
    )
    while True:
        internet = has_internet(INTERNET_PROBES, INTERNET_TIMEOUT_S)
        rtc_now, sample_age, topic = current_rtc_estimate()
        local_now = time.time()

        drift = None
        time_source = "unknown"
        clock_set_attempted = False
        clock_set_ok = False

        if internet:
            time_source = "ntp"
        elif rtc_now is not None and sample_age is not None and sample_age <= MAX_SAMPLE_AGE_S:
            drift = local_now - rtc_now
            if abs(drift) > DRIFT_THRESHOLD_S:
                time_source = "esp-rtc-correcting"
                clock_set_attempted = True
                clock_set_ok = set_system_clock(rtc_now)
                if clock_set_ok:
                    time_source = "esp-rtc"
            else:
                time_source = "esp-rtc-ok"
        elif rtc_now is not None:
            time_source = "esp-rtc-stale"
        else:
            time_source = "unknown"

        publish_status(
            {
                "time_source": time_source,
                "internet": internet,
                "drift_seconds": round(drift, 2) if drift is not None else None,
                "rtc_sample_age_seconds": round(sample_age, 1) if sample_age is not None else None,
                "rtc_sample_topic": topic,
                "clock_set_attempted": clock_set_attempted,
                "clock_set_ok": clock_set_ok,
            }
        )
        time.sleep(CHECK_INTERVAL_S)


def main() -> None:
    if not ENABLE:
        log("TIME_SYNC_ENABLE=false — sidecar idle")
        while True:
            time.sleep(3600)
    threading.Thread(target=mqtt_subscriber_loop, daemon=True).start()
    try:
        main_loop()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
