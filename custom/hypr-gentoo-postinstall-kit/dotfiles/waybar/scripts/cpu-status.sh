#!/usr/bin/env bash
set -euo pipefail

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
idle1=$((idle + iowait))
sleep 0.15
read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
idle2=$((idle + iowait))
dt=$((total2 - total1))
di=$((idle2 - idle1))
cpu=$(( (100 * (dt - di)) / (dt == 0 ? 1 : dt) ))

cpu_temp="N/A"
if command -v sensors >/dev/null 2>&1; then
  cpu_temp="$(sensors 2>/dev/null | awk '
    /Package id [0-9]+:/ {
      gsub(/\+|°C/, "", $4);
      printf("%d°C", $4);
      found=1;
      exit
    }
    END {
      if (!found) print "N/A"
    }')"
fi

tooltip="CPU usage: ${cpu}%\nCPU temp: ${cpu_temp}"
printf '{"text":" %s%%","tooltip":"%s"}\n' "$cpu" "$tooltip"
