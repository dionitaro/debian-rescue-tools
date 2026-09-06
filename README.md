# debian-rescue-tools

A minimal Debian 13 (trixie) rescue live ISO, plus a growing collection of
rescue/recovery tools that ship inside it.

The ISO itself is deliberately kept small: SSH, WireGuard, NFS, and a
handful of disk-recovery utilities. Anything heavier (a task-specific tool,
a script) lives under `tools/` and gets baked into the image automatically
by the build script.

Sorry for Romanian messages... english messages will be implemented soon.

## Repository layout

```
debian-rescue-iso-build.sh       - builds the ISO (run this)
rescue-config/
  packages.list                  - one Debian package per line
  wireguard/wg0.conf.example     - template; real file is gitignored
  ssh/
    authorized_keys.example      - template; real file is gitignored
    sshd_config.d/*.conf         - sshd drop-ins, the source of truth for SSH config
  sysctl.d/*.conf                - custom sysctl settings
  shell/aliases.sh               - shell aliases loaded at login
tools/
  <name>/<name>.sh               - each folder becomes /opt/<name>/ in the
                                    image, with a symlink at
                                    /usr/local/bin/<name> (no .sh)
  diskimager/                    - block-level backup/restore tool
```

Anything under `tools/` follows the same convention: a folder named `foo`
must contain a `foo.sh` entry point. The build script picks it up
automatically — no changes needed anywhere else.

## Configure

1. **Packages** — edit `rescue-config/packages.list`, one package per line.
   Comments (`#`) and blank lines are ignored.

2. **WireGuard** — copy the template and fill in your real values:
   ```bash
   cp rescue-config/wireguard/wg0.conf.example rescue-config/wireguard/wg0.conf
   ```
   This file is **required** — the build refuses to run without it. It's
   gitignored on purpose: it contains a private key and must never be
   committed to this (public) repository.

3. **SSH access** — root is the only user in this rescue environment.
   - `rescue-config/ssh/sshd_config.d/00-rescue.config` is the source of
     truth for sshd behavior (both key and password login are allowed by
     default).
   - Optionally add your public key:
     ```bash
     cp rescue-config/ssh/authorized_keys.example rescue-config/ssh/authorized_keys
     # then paste your real public key into it
     ```
     Also gitignored — never commit a real key here either.

4. **sysctl / shell aliases** — `rescue-config/sysctl.d/` and
   `rescue-config/shell/aliases.sh` are optional and applied as-is.

5. **Root password** — open `debian-rescue-iso-build.sh` and set
   `ROOT_PASSWORD` near the top. The script refuses to run while it's left
   at the default placeholder.

## Build

Run as root, on a Debian machine with internet access (the mirrors, not
this repo, are what actually needs the network):

```bash
chmod +x debian-rescue-iso-build.sh
./debian-rescue-iso-build.sh
```

This installs `live-build` and its dependencies, configures a hybrid
BIOS+UEFI image for `amd64`/trixie, and produces
`live-image-amd64.hybrid.iso` in the repo root. A full build takes roughly
10-20 minutes depending on link speed.

Write it to a USB stick:

```bash
dd if=live-image-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

### What the image does at boot

- Boots to the "Live system" entry automatically after 15 seconds (hybrid
  BIOS/UEFI boot menu).
- Brings up networking via DHCP on any wired interface.
- Connects the WireGuard tunnel automatically (`wg-quick@wg0`).
- Starts SSH automatically; root login is allowed (key or password).
- Auto-logs in to a root shell on the local console (tty1) as well.

## Tools

Every tool under `tools/` ships inside the ISO at `/opt/<name>/`, with a
plain `<name>` command available system-wide (symlinked into
`/usr/local/bin`, no `.sh` needed).

### diskimager

Block-level backup/restore for an entire disk (partition table, bootloader,
everything), compressed with `zstd`, verified with SHA-256, destination on
an NFS share reached over the WireGuard tunnel.

```bash
diskimager --backup
diskimager --restore
```

Without `--disk`, it lists the disks currently visible on the machine and
lets you pick interactively — handy since the same physical disk can show
up as `/dev/vda`, `/dev/sda`, etc. depending on the hypervisor/host. On
restore, only disks large enough for the selected archive are shown
(exact source size is recorded in a `.meta` file at backup time).

Flags: `--disk /dev/sdX`, `--machine NAME`, `--mountpoint /path`.

More tools will be added under `tools/` over time (a SMART-check helper is
one likely candidate) — each with its own short usage note either inline
here or in its own `tools/<name>/README.md` as the list grows.

## Security notes

- `rescue-config/wireguard/wg0.conf` and `rescue-config/ssh/authorized_keys`
  are gitignored. Never force-add or commit the real versions — this repo
  is public.
- `diskimager --restore` is destructive by design: it overwrites the
  entire target disk. It requires typing `YES` to confirm, and refuses to
  run against a disk (or any of its partitions) that's currently mounted.

## License

The original scripts, configuration templates, and documentation in this
repository are licensed under the [MIT License](LICENSE).

Debian and other third-party software included in a generated ISO retain
their own licenses. The MIT License does not relicense those components;
redistributing an ISO requires complying with their respective license
terms, including any applicable source-code and notice requirements.

These tools are provided without warranty. Disk restore operations overwrite
data; verify the target disk and keep independent backups before use.
