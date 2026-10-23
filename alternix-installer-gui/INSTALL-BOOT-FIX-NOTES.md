# Alternix eMMC installation checks

- Linux eMMC **boot0** and **boot1** are reserved hardware areas and are hidden from disk selection, rejected by the installer even in unattended mode. The normal user-storage disk is `/dev/mmcblkN`.
- EFI, /boot and /home formatting/mounting failures now stop the install.
- The copied-rootfs installer requires removal of live-boot, regeneration of a matching disk initramfs and checks for common eMMC storage modules.
- Installed fstab, root UUID, GRUB config, and EFI fallback loader are checked before displaying Installation complete.
- GRUB and Visor receive `rootdelay=5` for eMMC installations only.
- A failed install exits nonzero to the GUI instead of falsely reporting success.

This does not repair an already failing install automatically. Boot the current live USB and inspect `/tmp/alternix-install.log`, or the saved log on the USB if available. A recovery shell labelled `(initramfs)` strongly suggests a root discovery/initramfs problem; a GRUB prompt indicates a different earlier failure.
