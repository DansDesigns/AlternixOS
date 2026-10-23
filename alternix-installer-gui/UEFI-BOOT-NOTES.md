# Alternix Installer: automatic UEFI boot paths and live power management

There are no device-specific patches or USB modifications.

| Firmware | Removable EFI filename | Boot menu |
| --- | --- | --- |
| IA32 (32-bit) UEFI | `EFI/BOOT/BOOTIA32.EFI` | Standalone GRUB text menu |
| x86-64 (64-bit) UEFI | `EFI/BOOT/BOOTX64.EFI` | Visor graphical menu on extracted FAT USB AND DD media (fallback GRUB if Visor build unavailable) |
| Legacy BIOS | live-build GRUB | Standard GRUB menu |

## Hybrid ISO / DD mode

The binary hook rebuilds `boot/grub/efi.img` as FAT32 (minimum 64 MiB), keeps
live-build's other boot files, and places the compiled IA32 GRUB at the standard
removable-media pathname. This image is automatically embedded in the ISO.
For compatibility, x64 on a raw/DD hybrid image uses Visor, and
both the kernel and initrd are staged on the embedded FAT32 filesystem;
GRUB remains available as a fallback EFI executable.

## Extracted FAT32 USB / ISO mode

The same IA32 GRUB loader is written at `EFI/BOOT/BOOTIA32.EFI` in the ISO
filesystem, alongside the x64 bootloader. The firmware chooses automatically;
no user intervention or separate patch is required.

## Boot diagnostics

The IA32 loader prints this message before the menu:

    Alternix: 32-bit UEFI GRUB started (64-bit firmware uses Visor).

If no GRUB message appears, the firmware has not loaded this ISO's IA32
loader. Confirm USB was completely rewritten from the **newly built** ISO,
Secure Boot is disabled, and the boot device is selected as UEFI USB.

The IA32 GRUB binary keeps the firmware console while optionally appending GOP
framebuffer-based `gfxterm` (with an embedded Unicode font) if supported. This
can reveal a menu on firmware that shows a black UEFI text console. The text
menu also contains an explicit verbose/Intel-graphics-off installer choice and
a **Diagnostics: verify GRUB and boot files (no Linux)** item, so it is possible
to test the GRUB display and USB reads without launching a Linux kernel.
This is a compatibility improvement, not a guaranteed ElitePad fix.

The builder verifies the final ISO's filesystem loader and embedded FAT32 EFI
boot image match. **This is static verification, not proof of boot on hardware.**

A 64-bit Linux live system on IA32 firmware requires a 64-bit CPU, a kernel
with `CONFIG_EFI_MIXED=y` and compatible GRUB/kernel handover support.
This is separate from successfully loading the GRUB menu.

## Resilient Devuan downloads

The builder now retries the actual `lb build` command, not a separate
`lb bootstrap` that can succeed while the main build later fails in
debootstrap. Retry is limited to package-network failures while bootstrapping.
For the official default mirror, attempts proceed through:

1. `http://deb.devuan.org/merged`
2. `https://ftp.fau.de/devuan/merged`
3. `https://ftp.fau.de/devuan/merged` (retry)
4. `https://mirror.mirohost.net/devuan/merged`

A manually selected `DEVUAN_MIRROR` is retried once without overriding it.
`lb clean --purge` preserves `config/` and removes partial build state before
changing mirrors. The final raw log is `build/lb-build.log`; the complete
per-attempt history (including selected mirrors and a diagnostic probe of a
failed .deb URL) is `build/lb-build-attempts.log`. Each failure is reported;
the ISO is never marked successful just because a retry was attempted.

This changes only the main ISO build process. IA32 GRUB and x64 Visor remain
independently selected by UEFI firmware architecture as documented above.

## 2026-10-18 — EFI FAT32 formatting failure corrected

The October 18 build reached `9998-alternix-efi.hook.binary` after
`debootstrap` and the Visor compile succeeded. It then failed with
`mkfs.fat: Label can be no longer than 11 characters` because its
embedded EFI image used `ALTERNIX_EFI` (12 characters). The embedded
FAT32 image now uses the 8-character label `ALTERNIX`, with a length
check. This does not rename the ISO or change the bootloader selection.
The unrelated, non-fatal AlternixDE package conflict remains unresolved.
A full ISO build and physical tablet boot are not verified here.

## Live installer power management

The live installer (shared by 32-bit UEFI GRUB and 64-bit UEFI Visor)
ships masks for `sleep.target`, `suspend.target`, `hibernate.target`,
`hybrid-sleep.target`, and `suspend-then-hibernate.target`. Because Devuan
uses elogind instead of systemd for seat/power management, the ISO also
sets `AllowSuspend=no`, `AllowHibernation=no`, `AllowHybridSleep=no`, and
`AllowSuspendThenHibernate=no` in its elogind sleep configuration.
The installer ignores suspend/hibernate keys, lid actions, and idle sleep.

Fast installs copy the live system, so `installer/install_copy.sh` explicitly
removes these installer-only settings from the installed system. The
installer does not impose permanent sleep restrictions on the user.

## Boot parity and touchscreen input (October 2026)

For x64 firmware, Visor is the direct BOOTX64.EFI loader in BOTH the
ordinary ISO filesystem and the FAT32 EFI image used by raw/DD-written
USB devices. The embedded image includes `EFI/visor/boot.conf`,
`live/vmlinuz`, `live/initrd.img`, and a saved GRUB fallback at
`EFI/BOOT/grubx64-alternix.efi`. IA32 firmware still receives standalone
GRUB at BOOTIA32.EFI.

The touchscreen keyboard now retains the last visible QLineEdit target
when a touch temporarily steals focus, handles Backspace directly for Qt
line edits, and the Network page includes a Clear button. Passwords are
cleared when leaving/re-entering Network and when SSID/interface changes.

This is build-layout validation, not a hardware boot guarantee; test the
resulting ISO on both the ElitePad 1000 G2 and a known working Linx.

## October 2026 — Verification progress after IA32 GRUB check

After the builder prints `IA32 GRUB matches in ISO tree and embedded EFI image`,
it continues verifying the x64 Visor EFI loader, boot.conf, kernel and large
initrd. Previously all FAT32 read-back and comparisons were silent, so a large
initrd could make the builder appear to hang. The builder now announces each
file, prints a heartbeat every 15 seconds for long operations, and records
start, finish and failure markers in `build/iso-verification.log`. An individual
operation times out after 30 minutes by default; the limit can be adjusted
with `ALTERNIX_VERIFY_TIMEOUT_SECONDS` for unusually slow machines.

The finished ISO copy also reports its activity. Full FAT32 read-back and
byte-for-byte kernel/initrd comparison are retained. No bootloader, ISO boot
layout, installer keyboard or power-management changes were made here.


## 2026-10-18: Devuan Excalibur firmware packaging fix

`lb chroot_firmware` automatically scans packages that contain `/lib/firmware`
when `LB_FIRMWARE_CHROOT=true`. This pulled in `firmware-b43legacy-installer`
even though Alternix's package list did not request it. Its post-install
script tried to fetch `wl_apsta-3.130.20.0.o` from OpenWrt, redirected to
`sources.openwrt.org`, and failed because that host timed out. `dpkg` then
aborted and the ISO was never created.

The ISO builder now passes `--firmware-chroot false` and
`--firmware-binary false` and forces the corresponding config values.
Instead, the package list specifies firmware packages which your build log
confirmed were available in Devuan Excalibur. Intel, AMD, Realtek, Atheros,
Broadcom `firmware-brcm80211`, Mediatek, and additional firmware are included.

The **legacy B43 installer packages are intentionally not included** because
they download firmware during their post-installation step; those specific
old Broadcom chips may require firmware installation after boot via another
method. This change does not touch x64 Visor, IA32 GRUB, or the installer's
sleep/hibernation and keyboard corrections.

The zstd and mdadm warnings shown in the log were not fatal. A full ISO build
and physical hardware boot test remain necessary.

## Noninteractive firmware package compatibility

The live ISO is built without an interactive dpkg/debconf frontend. The
`firmware-ipw2x00` (Intel PRO/Wireless 2100/2200/2915) and `firmware-ivtv`
(Hauppauge/Conexant capture-device) packages require users to accept their
licences in `preinst`. With a noninteractive frontend they fail with
`agree question could not be asked` and exit status 2. The main ISO builder
excludes them, alongside the existing excluded Broadcom B43 downloader
packages. It never silently accepts end-user licence agreements.

All remaining firmware packages from the curated list, including modern Intel,
AMD, Realtek, Atheros, MediaTek, Broadcom, and sound firmware, remain included.
For hardware that specifically requires the two excluded legacy packages, the
end user can install them interactively after boot (subject to the package's
licence terms and available network access).

This policy applies to the single universal installer ISO regardless of
whether it was started via IA32 GRUB, x64 Visor, or legacy BIOS GRUB.

### Unattended FAT32 EFI verification

The final verifier extracts BOOTX64.EFI, Visor boot.conf, the kernel and initrd to unique, initially empty temporary paths with noninteractive `mcopy -o`; checks no longer create their destination as an existing `mktemp` file. The monitored command also has stdin closed to interactive replies (`/dev/null`). A FAT extractor error and a verified file mismatch are reported separately. The x64 Visor / IA32 GRUB selection is unchanged.

## FAT32 x64-loader filename collision fix

The embedded EFI image now saves its original GRUB x64 loader under
`EFI/BOOT/grubx64-alternix.efi`, deletes any differently-cased original
`bootx64.efi` names, then inserts one canonical `EFI/BOOT/BOOTX64.EFI`
containing Visor. Without this, Linux could stage both names, allowing
the case-insensitive FAT32 copy to overwrite the desired Visor executable.
The binary hook now reads the newly created FAT image and compares its x64
loader against Visor **before** the ISO is generated; final verification also
prints hashes when mismatched. This affects the universal ISO, not individual
USB sticks, and leaves the IA32 GRUB path unchanged.

## October 2026 — ElitePad / removable-ESP Visor startup

A Visor binary on an installed OS's writable ESP working does not prove the
same binary will initialize on a hybrid ISO's embedded FAT ESP. Visor's
upstream `boot.conf.example` explicitly advises `log=0` when startup stops
after `Visor loading...` on firmware with an unreliable ESP write path.
The **live ISO** Visor menu now sets `log=0`, `selfheal=0`,
`restore_fallback=0`, `quiet=0`, `autoboot=0`, `resolution=native`,
and `text_menu=0`. The menu stays graphical; it does not try to write
a log or repair firmware entries on a removable installer. An arbitrary
GRUB-branded PNG is no longer forced as Visor's live-ISO background.
The first Linux entry no longer uses `quiet`, and a verbose diagnostic
entry can be selected when the menu itself appears. The **installed**
Visor configuration is left unchanged.

This addresses a documented potential black-screen cause, but the device
must still be tested. If the display remains black, determine whether
`Visor loading...` appears, the menu appears, and/or the kernel starts.

## 2026-10-19 — Visor upstream startup compatibility / known-good binary

The upstream Visor repository documents the ESP layout as
`EFI/visor/visor_x64.efi` plus `EFI/visor/boot.conf` and the standard fallback
path `EFI/BOOT/BOOTX64.EFI`. The upstream [issue #8](https://github.com/IO-ZetZor/Visor-BootManager/issues/8)
tracks firmware that shows a black screen *before* the Visor menu or logging;
the maintainer identifies firmware PE loading and gnu-efi startup as possible
failure points. Hence repeatedly changing kernel options and `boot.conf` is
not a reliable solution if the menu never appears.

The builder now accepts a **known-working Visor EFI executable** from an older
installed OS (`./import-working-visor.sh /path/to/visor_x64.efi`) and uses the
EXACT supplied bytes in the live ISO instead of pulling a potentially newer,
incompatible revision. Its PE32+ / x86-64 / EFI-application headers are checked
up front, and final FAT/ISO byte comparisons still run. Its provenance is
recorded in `EFI/visor/SOURCE-REVISION.txt` inside the ISO. An override is
never bundled with the source ZIP because the older binary is not available.

Without an override the default behaviour remains: build Visor from upstream
GitHub HEAD. Optionally supply `VISOR_GIT_REF=<tag-or-commit>` to build a known
specific revision, which is also recorded; a non-resolvable explicit revision
stops the build instead of silently compiling a different one. The installed
OS bootloader still uses whichever Visor binary is included in the ISO.

This is a controlled way to test a confirmed regression, **not** evidence that
an untested Visor build has fixed the HP ElitePad 1000 G2. On upstream builds,
if the screen stays completely black before `Visor loading...`, upstream
recommends treating that as an early firmware/PE-loader startup issue rather
than a Linux graphics issue.
