#!/usr/bin/env bash
set -euo pipefail

python - <<'PY'
import json
import re
import subprocess

def clean_model(name: str) -> str:
	text = re.sub(r"\b(Corp\.?|Inc\.?|Ltd\.?|Co\.?|Company|Technology|Computer)\b", "", name, flags=re.IGNORECASE)
	text = re.sub(r"\s+", " ", text).strip(" -")
	return text or name.strip() or "USB device"


def external_label(name: str):
	text = re.sub(r"\s+", " ", name).strip()
	lower = text.lower()

	exclude_keywords = [
		"root hub", "usb hub", " hub", "bluetooth", "aura led", "led controller",
		"ax211", "internal", "chipset"
	]
	if any(k in lower for k in exclude_keywords):
		return None

	model = clean_model(text)

	if any(k in lower for k in ["printer", "deskjet", "laserjet", "epson", "canon", "brother"]):
		return f"Printer · {model}"
	if any(k in lower for k in ["webcam", "camera", "video", "capture"]):
		return f"Webcam/Camera · {model}"
	if any(k in lower for k in ["gamepad", "controller", "joystick", "xbox", "dualsense", "dualshock"]):
		return f"Gamepad/Controller · {model}"
	if any(k in lower for k in ["keyboard", "keychron", "kbd"]):
		return f"Keyboard · {model}"
	if any(k in lower for k in ["mouse", "receiver", "viper", "logitech", "mx"]):
		return f"Mouse · {model}"
	if any(k in lower for k in ["storage", "mass storage", "flash", "disk", "ssd", "hdd", "card reader", "sandisk", "kingston"]):
		return f"Storage · {model}"
	if any(k in lower for k in ["android", "iphone", "phone", "pixel", "samsung"]):
		return f"Phone · {model}"

	return None

raw = subprocess.check_output(["lsusb"], text=True, stderr=subprocess.DEVNULL)
devices = []
for line in raw.splitlines():
	match = re.search(r"ID\s+[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\s+(.+)$", line)
	name = match.group(1) if match else line
	label = external_label(name)
	if label:
		devices.append(label)

count = len(devices)
if count == 0:
	text = "USB 0"
	tooltip = "No external USB devices detected"
else:
	text = f"USB {count}"
	preview = devices[:6]
	extra = count - len(preview)
	lines = [f"External USB devices: {count}"]
	lines.extend([f"• {name}" for name in preview])
	if extra > 0:
		lines.append(f"• +{extra} more")
	tooltip = "\n".join(lines)

print(json.dumps({"text": text, "tooltip": tooltip}))
PY
