# Custom Hyprland Integration (Local Kit)

This repository is prepared to use your local Hyprland postinstall kit with `oddlama/gentoo-install`.

## What is already wired

- `gentoo.conf` contains an active `after_install()` hook.
- The hook copies `custom/hypr-gentoo-postinstall-kit` into the target system at `/root/hypr-gentoo-postinstall-kit`.
- The hook runs `scripts/01-system-bootstrap.sh` automatically (configurable).
- The hook installs helper command `hypr-postinstall-user-setup` in the target system.

## Keep the local kit in sync

Run this before installation whenever your local kit changes:

```bash
cd /home/edo/Downloads/custom-gentoo-install/base-gentoo-install
rsync -a --delete /home/edo/Downloads/omarchy/hypr-gentoo-postinstall-kit/ custom/hypr-gentoo-postinstall-kit/
```

## Tune the behavior

Edit these variables in `gentoo.conf`:

- `HYPR_POSTINSTALL_ENABLE=true`
- `HYPR_POSTINSTALL_RUN_BOOTSTRAP=true`
- `HYPR_POSTINSTALL_WITH_HYPROVERLAY=false`
- `HYPR_POSTINSTALL_GPU_PROFILE="auto"`
- `HYPR_POSTINSTALL_MACHINE_PROFILE="auto"`
- `HYPR_POSTINSTALL_TARGET_USER=""` (optional hint only)
- `CUSTOM_KERNEL_PIPELINE_ENABLE=false`
- `CUSTOM_KERNEL_SCRIPT_RELATIVE_PATH=""`
- `CUSTOM_KERNEL_SCRIPT_ARGS=()`

## Optional linux-tkg kernel pipeline

You can plug a custom kernel flow (including linux-tkg) into the installer via `after_install()`.

Template file provided:

```bash
custom/kernel/install-linux-tkg.example.sh
```

Ready-to-run starter script provided:

```bash
custom/kernel/install-linux-tkg.sh
```

This hook now auto-loads project-local customization:

```bash
custom/kernel/linux-tkg.customization.cfg
```

You can replace that file with your preferred tuning profile.

The hook also auto-detects CPU and applies a tuning profile override:

- `intel-alderlake` for newer Intel Alder/Raptor Lake class CPUs
- `intel-generic` for other Intel CPUs
- `amd-generic` for AMD CPUs

Set in `gentoo.conf`:

```bash
CUSTOM_KERNEL_PIPELINE_ENABLE=true
CUSTOM_KERNEL_SCRIPT_RELATIVE_PATH="custom/kernel/install-linux-tkg.sh"
CUSTOM_KERNEL_SCRIPT_ARGS=()
```

Optional arguments example:

```bash
CUSTOM_KERNEL_SCRIPT_ARGS=(
	--action install
	--cpusched eevdf
	--compiler gcc
	--tuning-profile auto
	--force-running-config auto
	--module-rebuild false
)
```

If you want to use another customization file explicitly:

```bash
CUSTOM_KERNEL_SCRIPT_ARGS=(
	--customization-source /path/to/customization.cfg
)
```

You can also force a specific profile:

```bash
CUSTOM_KERNEL_SCRIPT_ARGS=(
	--tuning-profile amd-generic
)
```

Notes:

- Keep default kernel (`KERNEL_TYPE`) as fallback until linux-tkg boots successfully.
- The custom script runs inside the target system near the end of installation.

## Install flow

```bash
cd /home/edo/Downloads/custom-gentoo-install/base-gentoo-install
./configure gentoo.conf   # optional, to review disk/system settings
./install -c gentoo.conf
```

After first boot into the new Gentoo system, run:

```bash
hypr-postinstall-user-setup <your-username>
```

Or manually:

```bash
su - <your-username> -c '/root/hypr-gentoo-postinstall-kit/scripts/02-user-setup.sh'
su - <your-username> -c '/root/hypr-gentoo-postinstall-kit/scripts/03-verify.sh'
```

## Important notes

- The base installer does not create your regular desktop user automatically.
- Create your user and grant wheel/sudo access before running user setup.
- `I_HAVE_READ_AND_EDITED_THE_CONFIG_PROPERLY` in `gentoo.conf` must be set to `true` after you finish editing.
