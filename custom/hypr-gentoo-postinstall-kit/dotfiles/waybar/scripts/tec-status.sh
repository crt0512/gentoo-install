#!/usr/bin/env bash
set -euo pipefail

STATUS_JSON="/var/run/intel_cryo_tec/status.json"

if [ ! -f "$STATUS_JSON" ]; then
  echo '{"text":" TEC N/A","tooltip":"TEC status file missing","class":"warn"}'
  exit 0
fi

python - <<'PY'
import json
from pathlib import Path

p = Path("/var/run/intel_cryo_tec/status.json")
try:
    d = json.loads(p.read_text())
except Exception as e:
    print(json.dumps({"text":" TEC ERR","tooltip":f"Parse error: {e}","class":"err"}))
    raise SystemExit

temp = d.get("temperature", 0.0)
power = d.get("power_level", 0)
hum = d.get("humidity", 0.0)
dew = d.get("dewpoint", 0.0)
curr = d.get("current", 0.0)
volt = d.get("voltage", 0.0)
hb = d.get("heartbeat", {})
pid_running = bool(hb.get("PID is running", False))
failsafe = bool(hb.get("Failsafe has been activated", False))

if failsafe:
    icon = ""
    cls = "err"
elif pid_running:
    icon = ""
    cls = "ok"
else:
    icon = ""
    cls = "warn"

text = f"{icon} TEC {temp:.1f}°C"
tooltip = (
    f"Intel Cryo TEC\n"
    f"Temp: {temp:.2f}°C\n"
    f"Dewpoint: {dew:.2f}°C\n"
    f"Humidity: {hum:.1f}%\n"
    f"Power: {power}%\n"
    f"Current: {curr:.2f} A\n"
    f"Voltage: {volt:.2f} V\n"
    f"PID: {'running' if pid_running else 'stopped'}\n"
    f"Failsafe: {'YES' if failsafe else 'no'}\n\n"
    f"Left-click: restart TEC\n"
    f"Right-click: run tec-status"
)

print(json.dumps({"text": text, "tooltip": tooltip, "class": cls}))
PY
