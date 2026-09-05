#!/bin/bash
# ============================================================================
# Build script pentru un Debian 13 (trixie) rescue ISO minimal
# Ruleaza ca root pe VM-ul tau (10.0.0.231), NU aici la mine.
#
# INAINTE SA RULEZI:
#   1. Editeaza ROOT_PASSWORD mai jos.
#   2. Pune configul tau WireGuard la: /$WORKDIR/debian-rescue/wg0.conf
#   3. (optional) Pune cheia ta SSH publica la: /root/debian-rescue/authorized_keys
#
# Rulare:
#   chmod +x build-rescue-iso.sh
#   ./build-rescue-iso.sh
#
# Rezultat: /$WORKDIR/live-image-amd64.hybrid.iso
# Dureaza ~10-20 minute, in functie de viteza internetului pe VM.
# ============================================================================
set -euo pipefail

# Fix pentru VM-uri unde /usr/sbin lipseste din PATH (cazul debootstrap "not found")
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ====================== CONFIG - EDITEAZA AICI =============================
ROOT_PASSWORD="CHANGE_ME"
WORKDIR="$(pwd)"
# =============================================================================

WG_CONF="$WORKDIR/wg0.conf"
AUTHORIZED_KEYS="$WORKDIR/authorized_keys"

if [ "$ROOT_PASSWORD" = "CHANGE_ME" ]; then
  echo "!!! Editeaza ROOT_PASSWORD in scriptul asta inainte sa rulezi. Iesire."
  exit 1
fi

mkdir -p "$WORKDIR"

if [ ! -f "$WG_CONF" ]; then
  echo "!!! Nu am gasit $WG_CONF"
  echo "!!! Pune configul tau WireGuard acolo (cu numele wg0.conf) si ruleaza din nou."
  exit 1
fi

echo ">>> Instalez live-build si uneltele necesare..."
apt update
apt install -y live-build debootstrap xorriso syslinux-common isolinux \
  grub-efi-amd64-bin grub-pc-bin mtools dosfstools

cd "$WORKDIR"
rm -rf config .build

echo ">>> Configurez live-build (Debian trixie, amd64, boot hibrid BIOS+UEFI)..."
lb config \
  --distribution trixie \
  --architectures amd64 \
  --binary-images iso-hybrid \
  --bootloaders "syslinux,grub-efi" \
  --archive-areas "main contrib non-free non-free-firmware" \
  --debian-installer none

mkdir -p config/package-lists
cat > config/package-lists/rescue.list.chroot <<'EOF'
openssh-server
sudo
tmux
curl
wget
rsync
wireguard-tools
systemd-resolved
nfs-common
nfs-kernel-server
disktype
parted
gddrescue
testdisk
tree
mc
EOF

echo ">>> Adaug utilitarul pentru disk bakup-restore"
mkdir -p config/includes.chroot/opt/diskimager
cp -r diskimager config/includes.chroot/opt/diskimager
mkdir -p config/includes.chroot/usr/local/bin
ln -s config/includes.chroot/usr/local/bin /opt/backup-restore/

echo ">>> Bag configul WireGuard in imagine..."
mkdir -p config/includes.chroot/etc/wireguard
cp "$WG_CONF" config/includes.chroot/etc/wireguard/wg0.conf

echo ">>> Configurez retea (DHCP automat pe orice interfata cu fir)..."
mkdir -p config/includes.chroot/etc/systemd/network
cat > config/includes.chroot/etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

if [ -f "$AUTHORIZED_KEYS" ]; then
  echo ">>> Adaug cheia SSH publica pentru root..."
  mkdir -p config/includes.chroot/root/.ssh
  cp "$AUTHORIZED_KEYS" config/includes.chroot/root/.ssh/authorized_keys
fi

echo ">>> Creez hook-ul de configurare (SSH, parola, servicii auto-start)..."
mkdir -p config/hooks/live
cat > config/hooks/live/9000-rescue-setup.hook.chroot <<'HOOKEOF'
#!/bin/bash
set -e

echo "root:__ROOT_PASSWORD__" | chpasswd

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

systemctl enable ssh
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable wg-quick@wg0

if [ -f /etc/wireguard/wg0.conf ]; then
  chmod 600 /etc/wireguard/wg0.conf
fi

if [ -d /root/.ssh ]; then
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys || true
fi

# Autologin root pe consola locala (nu afecteaza securitatea SSH)
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF2'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF2
HOOKEOF

# Injectez parola reala in hook (fara sa o scriu in shell history/apt logs)
sed -i "s/__ROOT_PASSWORD__/${ROOT_PASSWORD}/" config/hooks/live/9000-rescue-setup.hook.chroot
chmod +x config/hooks/live/9000-rescue-setup.hook.chroot

echo ">>> Configurez timeout boot (auto-pornire Live system dupa 15 secunde)..."
BOOTLOADER_TEMPLATES=""
for TPL_DIR in /usr/share/live/build/bootloaders /usr/lib/live/build/bootloaders; do
  if [ -d "$TPL_DIR" ]; then
    BOOTLOADER_TEMPLATES="$TPL_DIR"
    break
  fi
done

if [ -z "$BOOTLOADER_TEMPLATES" ]; then
  echo "!!! Nu am gasit templateurile de bootloader ale live-build (verifica manual calea)."
  echo "!!! Sar peste configurarea timeout-ului, restul buildului continua normal."
else
  echo ">>> Folosesc templateuri din: $BOOTLOADER_TEMPLATES"
  mkdir -p config/bootloaders
  for BL in isolinux syslinux grub-efi grub-pc; do
    if [ -d "$BOOTLOADER_TEMPLATES/$BL" ] && [ ! -d "config/bootloaders/$BL" ]; then
      cp -r "$BOOTLOADER_TEMPLATES/$BL" "config/bootloaders/$BL"
      echo "    copiat: $BL"
    fi
  done

  # isolinux/syslinux: timeout e in zecimi de secunda (150 = 15s)
  find config/bootloaders \( -path '*isolinux*' -o -path '*syslinux*' \) -name '*.cfg' 2>/dev/null | while read -r f; do
    sed -i 's/^timeout .*/timeout 150/' "$f"
  done

  # grub: timeout e in secunde
  find config/bootloaders -path '*grub*' -name '*.cfg' 2>/dev/null | while read -r f; do
    sed -i 's/^set timeout=.*/set timeout=15/' "$f"
    sed -i 's/^timeout=.*/timeout=15/' "$f"
  done
fi

echo ">>> Pornesc build-ul (descarca pachete de pe mirror Debian, dureaza cateva minute)..."
lb build

echo ""
echo "=============================================================="
echo " Gata! ISO-ul e la: $WORKDIR/live-image-amd64.hybrid.iso"
echo " Scrie-l pe un stick USB cu:"
echo "   dd if=live-image-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress conv=fsync"
echo " (inlocuieste /dev/sdX cu device-ul corect al stick-ului!)"
echo "=============================================================="