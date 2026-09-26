# Secure Boot

The Omarchy installer needs Secure Boot off, but an installed Omarchy can turn it back on with signing keys that belong to your machine rather than to Microsoft. Once it's on, the firmware only starts a Limine loader and kernel images signed with your keys, and Limine refuses a `limine.conf` that was changed behind its back. Kernel updates, Limine upgrades and snapshots keep working: every one of them is signed and sealed again as it happens.

Run it from _Setup > Security > Secure Boot_ in the Omarchy menu, or with `omarchy secureboot enable`. It's the only command you need, and you run it again after each restart it asks for.

_This is new. The engine behind it has a full hardware record on one laptop so far. Try it on a machine you can recover, and keep your Windows recovery key at hand if you dual boot._

## Turning it on

Secure Boot is off after installing, so the first run prepares the boot files and the next ones walk the firmware through three steps, one per run:

1. **First run.** Creates your signing keys, turns on Limine's config sealing, signs the loader and kernel images, and backs up the firmware's current keys to `/var/lib/omarchy-secureboot/firmware-backup/`. Then it tells you to restart into the firmware (`systemctl reboot --firmware-setup`) and **delete only the Platform Key (PK)**. Keep KEK, db and dbx, and leave Secure Boot disabled when you save. Deleting the Platform Key is what puts the firmware in Setup Mode.
2. **Second run, in Setup Mode.** Adds your certificates next to the ones already there and makes your key the Platform Key. The manufacturer's and Microsoft's certificates stay, so a graphics card's firmware and Windows keep starting.
3. **Third run, after a restart.** Tells you to turn Secure Boot on in the firmware.

`omarchy secureboot status` then shows every check green. It's also what to run whenever you're unsure: it ends with the command that fixes what it found.

If your firmware wipes every key when you delete the Platform Key, the second run notices and offers to rebuild the lists from your keys, Microsoft's and the firmware's defaults, listing anything it can't bring back before it writes.

## Dual booting Windows

Changing the firmware's keys and turning Secure Boot on or off changes what Windows measures at boot, so BitLocker or Device Encryption may ask for its recovery key afterwards. Have the key before you start. `omarchy secureboot windows preflight` looks for encrypted Windows volumes and prints what to do in Windows first.

To pick Windows from Limine's menu, run `omarchy secureboot windows setup`. The entry restarts the machine into the firmware's own Windows Boot Manager instead of chainloading it through Limine, which keeps BitLocker quiet. _System > Reboot to Windows_ in the Omarchy menu does the same without the menu: it asks the firmware to start Windows once, then reboots.

## Updates

The Limine hook signs and seals every new kernel and loader during the update itself, and never fails the update. If it couldn't prove the result, `omarchy update` ends with a red _Secure Boot needs attention_ line. Run `omarchy secureboot status` and fix what it says before you restart.

A firmware update or a CMOS reset can put the factory keys back. `status` says so; turn Secure Boot off and run `omarchy secureboot enable` again.

## If the machine doesn't start

Turning Secure Boot off in the firmware always gets you back in. If the loader itself refuses to start because `limine.conf` no longer matches its seal:

1. Turn Secure Boot off in the firmware.
2. Pick the fallback loader (`EFI/BOOT/BOOTX64.EFI`, which some firmware lists as "UEFI OS") in the firmware's boot menu. It isn't sealed, so it boots.
3. Run `omarchy secureboot sign`, then turn Secure Boot back on.

A dual-boot install starts without a fallback loader, and the first run offers to add one. If there's none, boot the Omarchy installer USB and put a raw loader back:

```bash
mount /dev/<your EFI system partition> /mnt
tar -xf /mnt/EFI/limine/limine_x64.bak -C /mnt/EFI/limine limine_x64.efi
umount /mnt
```

Snapshot entries from before you turned Secure Boot on are unsigned, and the firmware refuses them while it's on. Snapshots taken afterwards boot normally.

## Turning it off

Turn Secure Boot off in the firmware first, then run _Remove > Security > Secure Boot_ or `omarchy secureboot disable`. It returns Limine's settings and boot files to stock and takes the Windows entry out. Your signing keys stay in `/var/lib/sbctl`, and your certificates stay in the firmware until you restore the factory keys from its own key menu.

## Keep a copy of your keys

Your signing keys (`/var/lib/sbctl`) and the firmware backup (`/var/lib/omarchy-secureboot/firmware-backup/`) live on the root filesystem, so a snapshot restore takes them back in time with everything else. Keep a copy of both somewhere off the machine.

## Commands

| Command | What it does |
| --- | --- |
| `omarchy secureboot enable` | Set up, one firmware step per run |
| `omarchy secureboot status` | Report the state and the next step; `--quiet` gives an exit status only |
| `omarchy secureboot sign` | Seal and sign the boot files again; safe at any time |
| `omarchy secureboot disable` | Return to stock (Secure Boot must be off first) |
| `omarchy secureboot windows preflight\|setup\|remove\|status\|bootnext` | Windows beside Secure Boot |

The engine is [OmaSecBoot](https://github.com/peregrinus879/omasecboot) by peregrinus879 (MIT), shipped inside Omarchy. Its design documents, including every firmware quirk it works around, are in `docs/secureboot/` in the Omarchy repository.
