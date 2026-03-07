# Hyprland Gentoo Post-Install Kit

This kit is for **post-minimal Gentoo installs**.
It assumes your base system is already installed and bootable.

## What this does

- Installs Hyprland desktop stack and daily tools
- Applies Portage snippets (`package.use`, optional keywords)
- Enables required services for OpenRC or systemd
- Applies user dotfiles/config into `~/.config`
- Ensures a polkit agent launcher is present in Hypr autostart
- Sets Thunar as default file manager (`inode/directory`) and starts `thunar --daemon`
- Runs verification checks
- Applies hardware-aware defaults:
  - writes GPU-safe `VIDEO_CARDS` defaults into `/etc/portage/make.conf`
  - TEC module is optional (off by default)
  - laptop profile adds battery/power support and battery module in Waybar
  - laptop profile adds Bluetooth support/module
  - network menu includes airplane mode toggle controls

## What this assumes already exists (minimal Gentoo baseline)

- Bootable Gentoo system with kernel/bootloader/network working
- A user account with sudo access
- Basic kernel/network stack already functional (GPU userspace is handled by this kit)

## Folder layout

- `scripts/01-system-bootstrap.sh` -> run as root
- `scripts/02-user-setup.sh` -> run as normal user
- `scripts/03-verify.sh` -> run as normal user
- `packages/base.txt` -> package list used by bootstrap script
- `packages/profile-nvidia.txt` -> NVIDIA extras
- `packages/profile-amd.txt` -> AMD extras
- `packages/profile-laptop.txt` -> laptop extras (power, battery, bluetooth utilities)
- `portage/package.use/hypr-postinstall` -> USE flags snippet
- `portage/package.use/gpu-nvidia` -> NVIDIA USE snippet
- `portage/package.use/gpu-amd` -> AMD USE snippet
- `portage/package.use/gpu-intel` -> Intel USE snippet (placeholder for future overrides)
- `portage/package.accept_keywords/hyproverlay` -> optional keyword snippet
- `dotfiles/` -> put your final config set here (`hypr`, `waybar`, `wofi`, `mako`, etc.)

## Usage

1) Optional: update package list/snippets for your target machine.

2) As root:

```bash
cd hypr-gentoo-postinstall-kit
chmod +x scripts/*.sh
sudo ./scripts/01-system-bootstrap.sh
```

Recommended for a laptop with NVIDIA:

```bash
sudo ./scripts/01-system-bootstrap.sh --with-hyproverlay --machine laptop --gpu nvidia
```

Recommended for a desktop with AMD:

```bash
sudo ./scripts/01-system-bootstrap.sh --machine desktop --gpu amd
```

Auto GPU detection is enabled by default. Override manually if needed:

```bash
sudo ./scripts/01-system-bootstrap.sh --gpu nvidia
sudo ./scripts/01-system-bootstrap.sh --gpu amd
```

Machine profile auto-detection is enabled by default. Override manually:

```bash
sudo ./scripts/01-system-bootstrap.sh --machine laptop
sudo ./scripts/01-system-bootstrap.sh --machine desktop
```

Preview actions without changing anything:

```bash
./scripts/01-system-bootstrap.sh --dry-run
./scripts/01-system-bootstrap.sh --with-hyproverlay --gpu nvidia --machine laptop --dry-run
```

3) As your desktop user:

```bash
./scripts/02-user-setup.sh
./scripts/03-verify.sh
```

`02-user-setup.sh` behavior:

- TEC module is **disabled by default** (optional hardware)
- laptop auto-detection adds battery module in Waybar
- laptop auto-detection adds Bluetooth module in Waybar
- use `--with-tec` if your machine has that hardware
- sets Thunar as default file manager and enables `thunar --daemon` in Hypr autostart
- ensures a fallback polkit agent launcher is present in Hypr autostart
- network menu includes airplane mode toggle (`nmcli radio all off/on`)
- launcher shortcuts are configurable to exactly 3 or 5 apps

Examples:

```bash
./scripts/02-user-setup.sh
./scripts/02-user-setup.sh --machine laptop
./scripts/02-user-setup.sh --machine desktop --with-tec
./scripts/02-user-setup.sh --launchers 3 --launcher-apps "firefox,kitty,thunar"
./scripts/02-user-setup.sh --launchers 5 --launcher-apps "firefox,steam,obs,code,dolphin"
```

Supported launcher app IDs:

- `firefox`
- `steam`
- `scanner`
- `obs`
- `zoom`
- `thunar`
- `kitty`
- `dolphin`
- `code`

## Optional overlay mode

If your target machine uses `hyproverlay`, run:

```bash
sudo ./scripts/01-system-bootstrap.sh --with-hyproverlay
```

If your network cannot reach `codeberg.org`, you can keep `hyproverlay` installed
but disable auto-sync in your repos config and sync other repos only.

## Notes

- Scripts are idempotent-ish (safe to re-run).
- Existing config files are backed up before overwrite.
- You can keep this kit in git and evolve it as your setup changes.
- To check where installed Hyprland came from on a machine:

```bash
cat /var/db/pkg/gui-wm/hyprland-*/repository
```
