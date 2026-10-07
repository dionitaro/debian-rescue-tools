#!/bin/bash
# ============================================================================
# Build script pentru un Debian 13 (trixie) rescue ISO minimal.
# Ruleaza ca root pe VM-ul de build (NU aici), din radacina acestui repo.
#
# Structura asteptata:
#   rescue-config/packages.list           - lista de pachete (unul pe linie)
#   rescue-config/wireguard/wg0.conf       - config WireGuard (obligatoriu)
#   rescue-config/ssh/authorized_keys      - optional, cheie SSH publica root
#   rescue-config/ssh/sshd_config.d/*.conf - drop-in-uri sshd (sursa de adevar)
#   rescue-config/sysctl.d/*.conf          - sysctl custom
#   rescue-config/shell/aliases.sh         - aliasuri shell (optional)
#   tools/<nume>/<nume>.sh                 - orice tool suplimentar; fiecare
#                                             folder devine /opt/<nume>/ in
#                                             imagine, cu symlink automat in
#                                             /usr/local/bin/<nume> (fara .sh)
#
# INAINTE SA RULEZI:
#   1. Editeaza ROOT_PASSWORD mai jos.
#   2. Verifica ca rescue-config/wireguard/wg0.conf e configul real.
#
# Rulare:
#   chmod +x debian-rescue-iso-build.sh
#   ./debian-rescue-iso-build.sh
#
# Rezultat: ./live-image-amd64.hybrid.iso
# ============================================================================
set -euo pipefail

# Fix pentru VM-uri unde /usr/sbin lipseste din PATH
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ====================== CONFIG - EDITEAZA AICI =============================
ROOT_PASSWORD="CHANGE_ME"
WORKDIR="$(pwd)"
# =============================================================================

PACKAGES_LIST="$WORKDIR/rescue-config/packages.list"
WG_CONF="$WORKDIR/rescue-config/wireguard/wg0.conf"
AUTHORIZED_KEYS="$WORKDIR/rescue-config/ssh/authorized_keys"
SSHD_DROPINS_DIR="$WORKDIR/rescue-config/ssh/sshd_config.d"
SYSCTL_DIR="$WORKDIR/rescue-config/sysctl.d"
ALIASES_FILE="$WORKDIR/rescue-config/shell/aliases.sh"
TOOLS_DIR="$WORKDIR/tools"

if [ "$ROOT_PASSWORD" = "CHANGE_ME" ]; then
  echo "!!! Editeaza ROOT_PASSWORD in scriptul asta inainte sa rulezi. Iesire."
  exit 1
fi

if [ ! -f "$PACKAGES_LIST" ]; then
  echo "!!! Nu am gasit $PACKAGES_LIST"
  exit 1
fi

if [ ! -f "$WG_CONF" ]; then
  echo "!!! Nu am gasit $WG_CONF"
  echo "!!! Pune configul tau WireGuard acolo si ruleaza din nou."
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

echo ">>> Pachete din $PACKAGES_LIST..."
mkdir -p config/package-lists
grep -v '^\s*#' "$PACKAGES_LIST" | grep -v '^\s*$' > config/package-lists/rescue.list.chroot

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

echo ">>> Bag drop-in-urile sshd (sursa de adevar pentru config SSH)..."
mkdir -p config/includes.chroot/etc/ssh/sshd_config.d
if [ -d "$SSHD_DROPINS_DIR" ]; then
  cp "$SSHD_DROPINS_DIR"/*.conf config/includes.chroot/etc/ssh/sshd_config.d/ 2>/dev/null || true
fi

if [ -f "$AUTHORIZED_KEYS" ]; then
  echo ">>> Adaug cheia SSH publica pentru root..."
  mkdir -p config/includes.chroot/root/.ssh
  cp "$AUTHORIZED_KEYS" config/includes.chroot/root/.ssh/authorized_keys
fi

echo ">>> Bag sysctl custom..."
if [ -d "$SYSCTL_DIR" ]; then
  mkdir -p config/includes.chroot/etc/sysctl.d
  cp "$SYSCTL_DIR"/*.conf config/includes.chroot/etc/sysctl.d/ 2>/dev/null || true
fi

echo ">>> Bag aliasuri shell..."
if [ -f "$ALIASES_FILE" ]; then
  mkdir -p config/includes.chroot/etc/profile.d
  cp "$ALIASES_FILE" config/includes.chroot/etc/profile.d/rescue-aliases.sh
fi

echo ">>> Bag tool-urile din tools/..."
mkdir -p config/includes.chroot/opt
TOOL_SYMLINKS=""
if [ -d "$TOOLS_DIR" ]; then
  for tooldir in "$TOOLS_DIR"/*/; do
    [ -d "$tooldir" ] || continue
    toolname="$(basename "$tooldir")"
    mainscript="$tooldir$toolname.sh"
    if [ ! -f "$mainscript" ]; then
      echo "    !!! sar peste '$toolname': nu am gasit $toolname.sh in interior"
      continue
    fi
    rm -rf "config/includes.chroot/opt/$toolname"
    cp -r "$tooldir" "config/includes.chroot/opt/$toolname"
    chmod +x "config/includes.chroot/opt/$toolname/$toolname.sh"
    TOOL_SYMLINKS="$TOOL_SYMLINKS $toolname"
    echo "    adaugat: $toolname -> /opt/$toolname/$toolname.sh"
  done
fi

echo ">>> Creez hook-ul de configurare (parola root, servicii, symlink-uri)..."
mkdir -p config/hooks/live
cat > config/hooks/live/9000-rescue-setup.hook.chroot <<'HOOKEOF'
#!/bin/bash
set -e

echo "root:__ROOT_PASSWORD__" | chpasswd

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

for tool in __TOOL_SYMLINKS__; do
  ln -sf "/opt/$tool/$tool.sh" "/usr/local/bin/$tool"
done

# Autologin root pe consola locala (nu afecteaza securitatea SSH)
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF2'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF2
HOOKEOF

# Injectez parola reala si lista de tool-uri (fara sa fie in shell history)
sed -i "s/__ROOT_PASSWORD__/${ROOT_PASSWORD}/" config/hooks/live/9000-rescue-setup.hook.chroot
sed -i "s/__TOOL_SYMLINKS__/${TOOL_SYMLINKS}/" config/hooks/live/9000-rescue-setup.hook.chroot
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

  find config/bootloaders \( -path '*isolinux*' -o -path '*syslinux*' \) -name '*.cfg' 2>/dev/null | while read -r f; do
    sed -i 's/^timeout .*/timeout 150/' "$f"
  done

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
