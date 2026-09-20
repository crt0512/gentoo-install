## About gentoo-install

This is a fork of gentoo-easy-install that I duct taped together to work with the more or less most recent archlinux installer ISOs available during 2026-09-20. All below is as original fork had it afaik.

It supports the most common disk layouts, different file systems like ext4, ZFS and btrfs as well
as additional layers such as LUKS or mdraid. It also supports both EFI (recommended) and BIOS boot,
and can be used with systemd or OpenRC as the init system. SSH can also be configured to allow using an automation framework
like [Ansible](https://github.com/ansible/ansible) or [Fora](https://github.com/oddlama/fora) to automate beyond system installation.

[Usage](#usage) |
[Overview](#overview) |
[Updating the Kernel](#updating-the-kernel) |
[Recommendations](#recommendations) |
[Security](SECURITY.md) |
[FAQ](#troubleshooting-and-faq)

![](contrib/screenshot_configure.png)

This installer might appeal to you if

- you want to try gentoo without initially investing a lot of time, or fully committing to it yet.
- you already are a gentoo expert but want an automatic and repeatable best-practices installation.

Of course, we do encourage everyone to install gentoo manually. You will learn a lot if you
haven't done so already.

## Usage

> [!WARNING]
> This installer runs as root, sources its configuration as Bash code, and can erase entire disks.
> Review the repository and configuration locally, and use a VM before installing on real hardware.

First, boot into a live environment of your choice. I recommend using an [Arch Linux](https://www.archlinux.org/download/) live ISO,
as the installer can automatically install most required programs there. ZFS tools and a module matching the live kernel must be installed from trusted packages before using a ZFS layout.
Afterwards, proceed with the following steps:

```bash
pacman -Sy git  # (Archlinux) Install git in live environment, then clone:
git clone "https://github.com/firesand/gentoo-easy-install"
cd gentoo-easy-install
./configure     # configure to your liking, save as gentoo.conf
./install       # begin installation
```

Every option is explained in detail in `gentoo.conf.example` and in the help menus of the TUI configurator.
When installing, you will be asked to review the partitioning before anything critical is done.

The installer should be able to run without any user supervision after partitioning, but depending
on the current state of the gentoo repository, you might need to intervene in case a package fails
to emerge. The critical commands will ask you what to do in case of a failure. If you encounter a
problem you cannot solve, you might want to consider getting in contact with some experienced people
on [IRC](https://www.gentoo.org/get-involved/irc-channels/) or [Discord](https://discord.com/invite/gentoolinux).

If you need to enter an installed system in a chroot to fix something (e.g. after rebooting your live system),
you can always clone the installer, mount your main drive under `/mnt` and use `./install --chroot /mnt` to
just chroot into your system.

## Overview

The installer performs the following main steps (in roughly this order),
with some parts depending on the chosen configuration:

1. Partition disks (highly dependent on configuration)
2. Download and extract stage3 tarball (with cryptographic verification)
   \[Continues in chroot from here\]
3. Setup portage (initial rsync/git sync, run mirrorselect, create zz-autounmask files)
4. Base system configuration (hostname, timezone, keymap, locales)
5. Install required packages (git, kernel, ...)
6. Make system bootable (generate fstab, build initramfs, install the selected bootloader)
7. Ensure minimal working system (automatic wired networking, install eix, set root password)
   - (Optional) Install sshd with secure config (no password logins)
   - (Optional) Install additional packages provided in config

The goal of the installer is just to setup a minimal gentoo system following best-practices.
Anything beyond that is considered out-of-scope (with the exception of configuring sshd).
Here are some things that you might want to consider doing after the system installation is finished:

1. Read the news with `eselect news read`.
2. Compile a custom kernel and remove `gentoo-kernel-bin` (or `gentoo-kernel` if you used `KERNEL_TYPE=source`)
3. Adjust `/etc/portage/make.conf`
   - Set `CFLAGS` to `<march_native_flags> -O2 -pipe` for native builds by using the `resolve-march-native` tool
   - Set `CPU_FLAGS_X86` using the `cpuid2cpuflags` tool
4. Use a safe umask like `umask 077`

### (Optional) sshd

The script can provide a fully configured ssh daemon with reasonably good security settings.
It will by default only allow ed25519 keys, restrict key exchange
algorithms to a reasonable subset, disable any password based authentication,
and only allow root to login.

You can provide keys that will be written to root's `.ssh/authorized_keys` file. This will allow
you to directly continue your setup with your favourite infrastructure management software.

### (Optional) Unprivileged user

Set `CREATE_USER` to have the installer create an unprivileged user at the end of the
installation. Its supplementary groups, login shell and authorized ssh keys are configurable,
and `CREATE_USER_SUDO` additionally installs `app-admin/sudo` and allows the `wheel` group to
use it. You will be asked for the user's password interactively, so no password is ever stored
in the configuration file. If that user is in `wheel` and has a password, the root account may
stay locked.

### (Optional) Reusing an existing partition layout

With `DETECT_EXISTING_PARTITIONS=true` (the default) the installer checks whether the disks
already carry exactly the configured partitions before it touches anything. If they do, it offers
to keep them instead of repartitioning, which saves a reboot when retrying a failed installation
on live media that will not re-read a busy partition table. You are then asked separately whether
the filesystems should be reformatted. Detection is limited to plain gpt layouts, and keeping
existing filesystems is not offered for luks, raid or zfs layouts.

### (Optional) Mirror selection

The default `GENTOO_MIRROR` is Init7 (Switzerland), which is well peered and fast for most of
Europe. Change it to whatever is close to you; it is used both for the stage3 download and for
the installed system.

`SELECT_MIRRORS` (running `mirrorselect`) is off by default, because netselect probes hundreds
of hosts and usually takes longer than the download it is meant to speed up. If you do enable
it, set `SELECT_MIRRORS_COUNTRY` to a country name from the gentoo mirror list (e.g.
`"Switzerland"`) so only the mirrors hosted there are tested. The installer falls back to the
full list if that country has no usable mirror.

### (Optional) Microarchitecture level

`CPU_MICROARCH` selects which x86-64 microarchitecture level packages are built and fetched for.
The default `auto` checks whether this machine supports `x86-64-v3` (AVX2, BMI2, FMA and the rest
of the level) and uses it if so, which is what the handbook recommends for capable hardware. It
falls back to the baseline `x86-64` otherwise, and you can pin either level explicitly.

Detection asks the dynamic loader first (`ld.so --help` reports the supported hwcaps levels) and
falls back to parsing the cpu flags. When the level resolves to `x86-64-v3`, `-march=x86-64-v3`
is added to `COMMON_FLAGS`, and with `ENABLE_BINPKG=true` the `x86-64-v3` binhost is added at a
higher priority than the baseline one. The baseline binhost stays configured, so packages which
have no v3 build are still fetched as binaries instead of being compiled.

Note that Gentoo publishes no v3 *stage3*, only v3 binary packages — the system is always
bootstrapped from a baseline stage3 and moves to v3 from there.

### (Optional) Additional packages

You can add any amount of additional packages to be installed on the target system.
These will simply be passed to a final `emerge` call before the script is done,
where autounmasking will also be done automatically. It is recommended to keep
this to a minimum, because of the quite "interactive" nature of gentoo package management ;)

## Updating the kernel

By default, the installed system uses gentoo's binary kernel distribution (`sys-kernel/gentoo-kernel-bin`)
together with an initramfs generated by dracut. This ensures that the installed system works on all common hardware configurations.
Alternatively, you can set `KERNEL_TYPE=source` to build the kernel from source using `sys-kernel/gentoo-kernel`
(same distribution config, compiled locally).
Feel free to replace this with a custom-built kernel (and possibly remove/adjust the initramfs) when the system is booted.

The installer will provide the convenience script `generate_initramfs.sh` in `/boot/efi/`
or `/boot/bios` which may be used to generate a new initramfs for the given kernel version.
The selected bootloader reads the kernel and initramfs from the boot filesystem:

```bash
# EFI
kernel="/boot/efi/vmlinuz-current"
initrd="/boot/efi/initramfs.img"
# BIOS
kernel="/boot/bios/vmlinuz-current"
initrd="/boot/bios/initramfs.img"
```

In both cases, the update procedure is as follows:

1. Emerge new kernel
2. `eselect kernel set <kver>`
3. Backup old kernel and initramfs (`mv "$kernel"{,.bak}`, `mv "$initrd"{,.bak}`)
4. Generate new initramfs for this kernel `generate_initramfs.sh <kver> "$initrd"`
5. Copy new kernel `cp /boot/kernel-<kver> "$kernel"` (for systemd) or `cp /boot/vmlinuz-<kver> "$kernel"` (for openrc)

## Recommendations

This project started out as a way of documenting a best-practices installation for myself.
As the project grew larger, I've added more configuration options to suit legacy needs.
Below I've outlined several decisions I've made for this project, or decisions you
have during configuration. If you intend on setting up a modern system, you might want
to check them out. Please keep in mind that those are all based on my personal opinions and
experience. Your mileage may vary.

#### EFI vs BIOS

Use EFI. BIOS is old and deprecated for a long time now.
Only certain VPS hosters may require you to use BIOS still (time to write to them about that!)

#### Bootloader choice

Set `BOOTLOADER` in `gentoo.conf` to choose the bootloader:

- `grub`: supported by this installer for EFI installs.
- `limine`: supported for EFI and BIOS installs. The Gentoo package is keyworded, so the installer adds a narrow package keyword for `sys-boot/limine`.
- `systemd-boot`: EFI only. On OpenRC systems the installer uses `sys-apps/systemd-utils[boot]`; on systemd systems it enables `sys-apps/systemd[boot]`.

For EFI installs, the installer also creates firmware boot entries with `efibootmgr` for the selected loader. For BIOS installs, this installer currently supports Limine and rejects GRUB/systemd-boot instead of forcing an unsafe install.

#### Modern file systems

I recommend using a modern file system like ZFS, both on desktops and servers.
It provides transparent block-level compression, instant snapshots and full-disk encryption.
Generally, encrypting your root fs doesn't cost you anything and protects your data in case you lose your device.

#### Systemd vs OpenRC

I will not entertain the religious eternal debate here. Both are fine init systems, and
I've been using both *a lot*. If you cannot decide, here are some objective facts:

- OpenRC is a service manager. Setting up all the other services is a lot of work, but you will learn a lot.
- Systemd is an OS-level software suite. It brings an insane amount of features with a steep learning curve.

Here's a non-exhaustive list of things you will ~do manually~ learn when using OpenRC,
that are already provided for in systemd: udev, dhcp, acpi events (power/sleep button),
cron jobs, reliable syslog, logrotate, process sandboxing, persistent backlight setting, persistent audio mute-status, user-owned login sessions, ...

Make of this what you will, both have their own quirks. Choose your poison.

#### Miscellaneous

- Use the newer iwd for WiFi instead of wpa_supplicant
- (If systemd) Use timers instead of cron jobs

## Troubleshooting and FAQ

After the initial sanity check, the script should be able to finish unattendedly.
But given the unpredictability of future gentoo versions, you might still run into issues
once in a while.

The script checks every command for success, so if anything fails during installation,
you will be given a proper message of what went wrong. Inside the chroot,
most commands will be executed in a checked loop, and allow you to interactively
fix problems with a shell, to retry, or to skip the command. You can report
issues specific to this script on the issue tracker. To seek help
regarding gentoo in general, visit the official [IRC](https://www.gentoo.org/get-involved/irc-channels/)
or [Discord](https://discord.com/invite/gentoolinux).

If you experience any issues after rebooting and need to fix something inside the chroot,
you can use the installer to chroot into an existing system. Run `./install --help` for more infos.

#### Q: ZFS cannot be installed in the chroot due to an unsupported kernel version

**A:** The newest stable ZFS module may require a kernel version that is newer than what is provided on gentoo stable.
If you encounter this problem, you might be able to fix the problem by switching to testing by dropping to a shell temporarily:

```
# Press S<Enter> when asked about what to do next.
# This opens an emergency shell in the chroot.
echo 'ACCEPT_KEYWORDS="~amd64"' >> /etc/portage/make.conf # Enable testing for your architecture.
emerge -v gentoo-kernel-bin                               # Update kernel to newest version (or gentoo-kernel if KERNEL_TYPE=source)
exit # Ctrl-D
# Now select 'retry' when asked about what to do next.
```

#### Q: I get errors after partitioning about blkid not being able to find a UUID

**A:** Be sure that all devices are unmounted and not in use before starting the script.
Use `wipefs -a <DEVICE>` on your partitions or fully wipe the disk before use.
The new partitions probably align with previously existing partitions that had
filesystems on them. Some filesystems signatures like those of ZFS can coexist with
other signatures and may cause blkid to find ambiguous information.

## References

* [Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64)
* [Sakaki's EFI Install Guide](https://wiki.gentoo.org/wiki/Sakaki%27s_EFI_Install_Guide)
