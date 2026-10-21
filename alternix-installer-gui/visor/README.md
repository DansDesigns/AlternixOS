# Known-working Visor executable

The ISO builder normally compiles Visor from the current upstream main branch.
Some firmware can fail **before Visor's menu appears**, so toggling `boot.conf`
cannot necessarily fix the black screen.

If an older installed AlternixOS boots Visor on the same tablet, copy its
**actual x86-64 EFI application** (not GRUB, an ISO or a configuration file):

```bash
./import-working-visor.sh /mnt/old-esp/EFI/visor/visor_x64.efi
sudo bash build-iso.sh
```

Replace `/mnt/old-esp` with the mounted EFI System Partition of the **working**
installed OS. Alternative source is `.../EFI/BOOT/BOOTX64.EFI`, **only after
confirming that it is actually Visor**, not GRUB or a Windows boot manager.

The import validates x86-64 PE32+ EFI application structure; it cannot prove
that the executable is Visor or that it boots on the hardware. Obtain it from
a source you trust. The ISO maker copies these bytes unchanged into BOTH
`EFI/BOOT/BOOTX64.EFI` and the embedded FAT32 boot image, with comparisons.

To return to automatically compiling the upstream Visor version:

```bash
rm -f visor/visor_x64.efi
sudo bash build-iso.sh
```

To test a specific upstream git **tag or commit** instead:

```bash
VISOR_GIT_REF=v1.2.1 sudo -E bash build-iso.sh
```

For a commit hash, use the full hash. Upstream tags/branches and commits must
exist and be fetchable. Do not combine this with a local imported executable:
local binaries take precedence. The ISO records its Visor source revision or
binary SHA256 in `EFI/visor/SOURCE-REVISION.txt`.

Neither the imported working executable nor firmware boot success is bundled
with this source ZIP. They must be tested on the ElitePad itself.
