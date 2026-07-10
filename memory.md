# Memory

Dokumen ini menyimpan konteks kerja agar pembahasan berikutnya bisa lanjut tanpa mengulang audit dari awal.

## Status proyek

- Repo kerja: `/home/edo/gentoo-easy-install`.
- Fokus terakhir: perbaikan safety installer Gentoo, penghapusan Hyprland support, penghapusan kernel linux-tkg, dan penambahan pilihan bootloader.
- File tips `tips1.md` sampai `tips5.md` tetap dianggap sebagai sumber masukan lokal dan belum dihapus.
- Belum ada commit atau push yang dibuat.

## Keputusan yang sudah diambil

- Hyprland support dihapus dari repo karena terlalu melebar dari scope installer minimal.
- Opsi kernel linux-tkg dihapus. Kernel yang didukung tinggal:
  - `KERNEL_TYPE=bin` untuk `sys-kernel/gentoo-kernel-bin`.
  - `KERNEL_TYPE=source` untuk `sys-kernel/gentoo-kernel`.
- Stage3 harus diverifikasi dengan signature Gentoo dan SHA512 sebelum disk disentuh.
- Operasi disk destruktif harus memakai konfirmasi exact phrase `WIPE <device...>`.
- Config tetap Bash trusted code, bukan format data aman. Dokumentasi harus terus menyebutkan risiko ini.

## Bootloader

Pilihan baru ada di `BOOTLOADER`:

- `grub`: didukung untuk EFI installs.
- `limine`: didukung untuk EFI dan BIOS installs.
- `systemd-boot`: EFI only.

Catatan penting:

- `systemd-boot` pada BIOS ditolak sejak validasi.
- GRUB BIOS juga ditolak untuk saat ini. Layout BIOS lama repo memakai partisi FAT untuk boot, sedangkan GRUB BIOS biasanya membutuhkan area embed yang berbeda. Memaksa `grub-install --force` dianggap terlalu rawan.
- Untuk BIOS, pilihan yang aman saat ini adalah `BOOTLOADER=limine`.
- Untuk EFI, installer menulis kernel dan initramfs ke boot filesystem sebagai:
  - `/boot/efi/vmlinuz-current`
  - `/boot/efi/initramfs.img`
- Untuk BIOS:
  - `/boot/bios/vmlinuz-current`
  - `/boot/bios/initramfs.img`

## File penting

- `scripts/functions.sh`: validasi config, termasuk `validate_kernel_type` dan `validate_bootloader`.
- `scripts/main.sh`: install kernel, initramfs, dan bootloader.
- `scripts/config.sh`: helper layout disk.
- `configure`: TUI configurator dan generator `gentoo.conf`.
- `gentoo.conf.example`: template konfigurasi manual.
- `README.md`: dokumentasi user-facing.
- `SECURITY.md`: catatan security/safety.
- `tests/run.sh`: runner test regresi.

## Test yang tersedia

- `tests/bootloader-validation.sh`
- `tests/configure-cli-validation.sh`
- `tests/create-vm-gentoo-test.sh`
- `tests/disk-config-validation.sh`
- `tests/install-cli-validation.sh`
- `tests/recovery-cleanup.sh`
- `tests/stage3-verification.sh`

Perintah validasi umum:

```bash
bash -n install configure gentoo.conf gentoo.conf.example scripts/*.sh tests/*.sh
./tests/run.sh
```

## Sisa risiko

- Belum dilakukan full E2E VM install sampai reboot nyata.
- Belum ada `--dry-run` atau `--plan-json` installer-level.
- Belum ada automated VM matrix untuk kombinasi bootloader, filesystem, LUKS, RAID, systemd/OpenRC.
- Limine di Gentoo saat ini memakai keyword package, jadi installer menambahkan keyword sempit untuk `sys-boot/limine` saat opsi itu dipilih.
- systemd-boot pada OpenRC memakai `sys-apps/systemd-utils[boot]`; jika profile target punya blocker lokal, operator masih perlu intervensi Portage.

## Cara lanjut yang disarankan

1. Jalankan test lokal setelah perubahan apa pun.
2. Prioritaskan E2E VM untuk kombinasi:
   - EFI + GRUB + ext4 + LUKS.
   - EFI + systemd-boot + ext4 + LUKS.
   - EFI + Limine + Btrfs.
   - BIOS + Limine + ext4.
3. Setelah E2E lolos, baru pertimbangkan commit.
