# Unattended Installs

The Omarchy ISO can install itself with nobody at the keyboard. Describe the install in one file, `install.toml`, put it on a second drive labeled `cidata`, and the installer skips the setup wizard, installs exactly what the file says, and reboots into the finished system on its own. No special ISO build, no extra boot menu entry. With no such drive attached, nothing changes and you get the normal wizard.

This makes Omarchy great as a base image for disposable dev environments: create a VM in Proxmox or with Packer, boot it, walk away, SSH in. `cidata` is the cloud-init `NoCloud` label, so all the common virtualization tooling already knows how to attach such a drive.

Every install is described this way, even a clicked one: the wizard writes its answers as an `install.toml` and installs that. The installed system keeps the file it was installed from, with every password and key removed, at `/etc/chefs-kitchen/install.toml`. That makes a good starting point for your own.

## install.toml

```toml
schema = 1

[system]
hostname = "marvin"
timezone = "America/Toronto"
keyboard = "us"

[[users]]
name      = "kevin"
full_name = "Kevin"                              # optional, used for git
email     = "kevin@example.com"                  # optional, used for git
password  = { file = "kevin.pass" }              # or password_hash = "$6$…"
ssh_authorized_keys = ["ssh-ed25519 AAAA… you@host"]

[disk]
target = { serial = "S69ENX0T812345" }           # or { by_id = "…" }, { wwn = "…" }, { path = "/dev/vda" }
mode = "wipe"                                    # or "free-space", alongside what's already there
on_existing_data = "abort"                       # "wipe" to erase a disk that has anything on it
# expect_fingerprint = "sha256:…"                # wipe only if the disk still looks like this

[disk.home]
location = "same"                                # "disk" puts /home on its own disk:
# disk = { serial = "S69ENX0T899999" }

[swap]
strategy = "zram+hibernate"                      # or "zram", or "none"

[encryption]
enabled    = true
passphrase = { same_as_user = "kevin" }          # or { file = "luks.pass" }, { prompt = true }

[desktop]
theme = "Tokyo Night"                            # any theme the ISO ships
agent = "claude"                                 # installs at first login

[packages]
extra = []                                       # from the ISO's offline package mirror

[network]
tailscale_authkey = { file = "tailscale.key" }

[provisioning]
defer = false
```

Only `schema`, one `[[users]]` entry and `disk.target` are required; everything else has the defaults shown.

**Secrets never go in the file itself.** Passwords, passphrases and keys are `{ file = "…" }`, a file next to `install.toml` on the same drive. The installer won't take a plain string where a secret belongs. `{ insecure_plaintext = "…" }` works if you really mean it, with a warning every time.

**Name the disk by something that can't change.** Its serial number, its `/dev/disk/by-id` name, or its WWN; `lsblk -o NAME,MODEL,SERIAL,WWN` shows them. `{ path = "/dev/vda" }` is fine in a VM, where device names don't move around.

## Checking a file before you use it

The ISO has a `chefs-kitchen` command. You can run it from a second console on the live ISO (Ctrl+Alt+F2, log in as `root`):

```bash
chefs-kitchen validate install.toml               # typos, missing keys, secrets in the wrong place
chefs-kitchen plan --config install.toml --yes    # which disk, what's on it, what would be erased
```

`validate` needs nothing but the file, so it also works in CI. Any unknown key is an error, because a typo in a file that decides which disk gets erased must never be ignored.

`plan` touches nothing. It prints the same summary the wizard shows before erasing a disk: every partition, what's on it (Windows, another Linux, BitLocker, an encrypted volume), the drives that won't be touched, and what gets created. It ends with the disk's fingerprint.

## Unattended installs never erase data by default

An unattended install stops with the summary on screen, and in the install log, if the target disk has anything on it at all. To install over it anyway, say so in the file:

```toml
[disk]
target = { serial = "S69ENX0T812345" }
on_existing_data = "wipe"
expect_fingerprint = "sha256:84d9256d…"
```

`expect_fingerprint` is what `chefs-kitchen plan` printed for that disk. It pins the erase to the exact partition layout you looked at: if the disk has changed since, the install refuses rather than erase something you haven't seen.

## Encryption

An encrypted unattended install needs its passphrase without anyone typing it. With the default `passphrase = { same_as_user = "kevin" }`, that means giving the user's password as a file (`password = { file = "kevin.pass" }`) rather than as a `password_hash`. Or give the passphrase its own file.

Encrypted unattended installs still aren't fully unattended: someone has to type the passphrase at every boot. And the drive now carries that passphrase, so treat it as the secret it is.

With `[disk.home] location = "disk"`, `/home` goes on a second disk. When the install is encrypted that disk gets its own encryption, unlocked at boot by a key kept on the encrypted system disk, so there's still one passphrase to type. Snapshots and factory reset keep covering the system as before.

## SSH and Tailscale

When the user has `ssh_authorized_keys`, the install sets them up as the user's `~/.ssh/authorized_keys`, enables `sshd`, and opens the firewall for it. (A stock Omarchy install ships openssh with the service disabled and the port closed, so an unattended machine would otherwise be unreachable.) The install only adds your keys; it doesn't loosen any of the SSH daemon's other authentication settings.

When `tailscale_authkey` is set, the machine joins your tailnet on first boot instead: Tailscale is installed from the ISO's bundled packages, the firewall allows the tailnet interface, and a background job runs the join as soon as the machine actually has network, retrying until it succeeds. Use a reusable, pre-authorized key so one drive can serve many machines.

## Installing for someone else

`[provisioning] defer = true`, with no `[[users]]`, runs the same [prepare-for-another-owner install](02-getting-started.md) you can trigger interactively. The machine installs with no personal details, and whoever boots it first picks their keyboard and creates their account. That's the mode for imaging rigs, where the drive shouldn't carry anyone's credentials at all.

## Building the cidata drive

Any filesystem with the right label works. A tiny ISO is the easy way:

```bash
mkdir cidata
cp install.toml kevin.pass cidata/
genisoimage -output cidata.iso -volid cidata -joliet -rock cidata/
```

Then attach it to the VM alongside the Omarchy ISO. Here's a full Proxmox example:

```bash
qm create 101 --name my-omarchy \
  --bios ovmf --machine q35 --cpu host --cores 4 --memory 8192 \
  --ostype l26 --scsihw virtio-scsi-single \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 \
  --scsi0 local-lvm:40,discard=on,iothread=1 \
  --net0 virtio,bridge=vmbr0 --vga virtio --serial0 socket \
  --ide2 local:iso/omarchy.iso,media=cdrom \
  --ide3 local:iso/cidata.iso,media=cdrom \
  --boot order='scsi0;ide2'

qm start 101
```

The boot order lists the disk first on purpose: the empty disk falls through to the ISO on the first boot, and the installed system boots from disk ever after.

## From a USB drive, with someone at the keyboard

An `install.toml` on an ordinary USB drive works too. On the installer's first screen, type `L` and press Return instead of just Return. The installer finds the file, shows the same summary as always, and asks you to type the disk's name before it erases anything, or asks for the passphrase if the file says `{ prompt = true }`.

## Older cidata drives

Drives made for earlier ISOs carry the wizard's own output files instead (`user_configuration.json`, `user_credentials.json`, and optionally `user_full_name.txt`, `user_email_address.txt`, `authorized_keys`, `tailscale_authkey` or an empty `defer-provisioning`). Those still work. When a drive has both, `install.toml` wins.
