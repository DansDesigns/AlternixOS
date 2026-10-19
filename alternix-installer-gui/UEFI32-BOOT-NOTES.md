# Alternix ISO: firmware-selective UEFI boot paths

The ISO builder selects the boot manager **by the UEFI firmware architecture**,
not by Linux userspace or CPU word size:

| Firmware | Fallback EFI filename | Installer boot manager |
| --- | --- | --- |
| x86_64 UEFI | `EFI/BOOT/BOOTX64.EFI` | **Visor** (default when built) |
| IA32 UEFI | `EFI/BOOT/BOOTIA32.EFI` | **Standalone i386-efi GRUB text installer menu** |
| Legacy BIOS | BIOS boot image | Existing GRUB |

The 32-bit loader contains its own four-entry GRUB menu; it never chains to
64-bit Visor. On the *installed* system, 32-bit EFI uses `grub-install
--target=i386-efi`; 64-bit EFI continues to install Visor by default.

## USB writing method matters

- On a **FAT USB with extracted ISO files** (e.g. Rufus ISO mode), x64 firmware
  starts Visor and IA32 firmware starts GRUB from `EFI/BOOT`.
- On a **raw hybrid ISO image** (dd/Etcher/Rufus DD mode), firmware loads the
  embedded `boot/grub/efi.img`. It contains verified IA32 GRUB; its **x64 loader
  remains live-build's GRUB** as a compatibility fallback, because Visor expects
  its kernel/initrd on its boot FAT volume (they are not on the small embedded
  image). This does not change the default x64 Visor installer for extracted FAT media.
- The build verifies that the two copies of the IA32 GRUB loader are
  byte-identical and that the x64 `BOOTX64.EFI` on the ISO filesystem matches
  the packaged Visor executable whenever Visor is built.

## ElitePad diagnostic

If an ElitePad shows **“Visor loading”**, it did *not* execute the new
`BOOTIA32.EFI` text selector. Check whether its firmware is actually 64-bit,
whether the USB was reflashed with the new ISO, and whether the firmware boot
entry points at a different EFI loader. A 32-bit-**only CPU** also cannot start
this amd64 Alternix kernel, even if its GRUB menu appears.

For an IA32 UEFI firmware with an x86-64-capable CPU, starting the 64-bit kernel
still depends on mixed-mode EFI support in the kernel and bootloader.

Run `sudo bash build-iso.sh` on the build host, then reflash and boot with Secure
Boot disabled. These changes have been syntax/static tested but not boot-tested
on physical hardware.
