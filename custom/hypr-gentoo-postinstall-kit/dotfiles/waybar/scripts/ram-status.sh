#!/usr/bin/env bash
set -euo pipefail

mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
mem_used=$((mem_total - mem_avail))
ram=$((100 * mem_used / mem_total))

printf '{"text":" %s%%","tooltip":"RAM usage: %s%%"}\n' "$ram" "$ram"
