#!/usr/bin/env bash

set -o pipefail

# Configurare
MOUNTPOINT="/mnt/_thc_bkp"
MACHINE="vps8"
DEST="$MOUNTPOINT/$MACHINE"
DISK="/dev/vda"
ZSTD_LEVEL="3"
BLOCK_SIZE="16M"

usage() {
    echo "Utilizare:"
    echo "  $0 --backup"
    echo "  $0 --restore"
    exit 2
}

die() {
    echo "EROARE: $*" >&2
    exit 1
}

is_rescue_mode() {
    grep -qwE 'boot=live|rescue' /proc/cmdline 2>/dev/null ||
        [ -e /run/live/rootfs/filesystem.squashfs ] ||
        mountpoint -q /run/live/medium 2>/dev/null
}

check_common() {
    local cmd

    [ "$(id -u)" -eq 0 ] ||
        die "Scriptul trebuie rulat ca root."

    is_rescue_mode ||
        die "Masina nu pare pornita in rescue/live mode."

    [ -b "$DISK" ] ||
        die "$DISK nu exista sau nu este block device."

    mountpoint -q "$MOUNTPOINT" ||
        die "NAS-ul nu este montat la $MOUNTPOINT."

    for cmd in awk blockdev dd df findmnt lsblk mountpoint sha256sum tee zstd; do
        command -v "$cmd" >/dev/null ||
            die "Comanda necesara lipseste: $cmd"
    done

    # Nu cream directorul local daca NAS-ul nu este montat.
    mkdir -p "$DEST" ||
        die "Nu pot crea directorul $DEST."

    [ -w "$DEST" ] ||
        die "Directorul $DEST nu este writeable."
}

check_disk_not_mounted() {
    local mounted

    mounted="$(
        lsblk -nrpo NAME,MOUNTPOINTS "$DISK" |
            awk 'NF > 1 { print }'
    )"

    if [ -n "$mounted" ]; then
        echo "EROARE: discul sau una dintre partitiile sale este folosita:"
        echo "$mounted"
        exit 1
    fi
}

backup_disk() {
    local stamp disk_name disk_size_gib backup partial log rc
    local disk_bytes available_bytes answer

    check_common
    check_disk_not_mounted

    stamp="$(date +%F_%H-%M-%S)"
    disk_name="${DISK##*/}"
    disk_bytes="$(blockdev --getsize64 "$DISK")"
    disk_size_gib="$(( (disk_bytes + 1073741823) / 1073741824 ))"

    backup="$DEST/${MACHINE}-${disk_name}-${disk_size_gib}G-${stamp}.img.zst"
    partial="${backup}.partial"
    log="$DEST/${MACHINE}-${disk_name}-${stamp}.backup.log"

    available_bytes="$(df --output=avail -B1 "$DEST" | awk 'NR == 2 { print $1 }')"

    if [ "$available_bytes" -lt "$disk_bytes" ]; then
        echo "ATENTIE: NAS-ul are mai putin spatiu liber decat dimensiunea raw."
        echo "Disc:       $disk_size_gib GiB"
        echo "Disponibil: $((available_bytes / 1073741824)) GiB"
        echo
        echo "Compresia poate fi suficienta, dar backup-ul se poate opri."
        read -r -p "Continui? Scrie YES: " answer

        [ "$answer" = "YES" ] || die "Backup anulat."
    fi

    exec > >(tee -a "$log") 2>&1

    echo "Pornire backup:  $(date -Is)"
    echo "Sursa:           $DISK"
    echo "Destinatie:      $backup"
    echo "Fisier temporar: $partial"
    echo

    dd if="$DISK" \
        bs="$BLOCK_SIZE" \
        iflag=fullblock \
        status=progress \
        conv=noerror,sync |
        zstd -T0 "-$ZSTD_LEVEL" -o "$partial"

    rc=$?

    echo
    echo "Transfer terminat: $(date -Is), cod: $rc"

    if [ "$rc" -ne 0 ]; then
        echo "EROARE: backup-ul a esuat."
        echo "Fisierul partial a fost pastrat: $partial"
        sync
        exit "$rc"
    fi

    echo "Verificare arhiva..."
    if ! zstd -t "$partial"; then
        echo "EROARE: verificarea arhivei a esuat."
        echo "Fisierul partial a fost pastrat: $partial"
        sync
        exit 1
    fi

    mv -- "$partial" "$backup" ||
        die "Nu pot redenumi fisierul final."

    echo "Calculare SHA-256..."
    sha256sum "$backup" | tee "$backup.sha256"

    sync

    echo
    echo "Backup finalizat cu succes: $(date -Is)"
    echo "Imagine:  $backup"
    echo "Checksum: $backup.sha256"
    echo "Log:      $log"
}

restore_disk() {
    local archives archive checksum log answer rc disk_size_bytes
    local stamp archive_name

    check_common
    check_disk_not_mounted

    [ "$(lsblk -dnro RO "$DISK")" = "0" ] ||
        die "$DISK este read-only."

    shopt -s nullglob
    archives=("$DEST"/*.img.zst)
    shopt -u nullglob

    [ "${#archives[@]}" -gt 0 ] ||
        die "Nu exista arhive .img.zst in $DEST."

    echo "Arhive disponibile:"
    echo

    PS3="Selecteaza numarul arhivei sau 0 pentru anulare: "

    select archive in "${archives[@]}"; do
        if [ "$REPLY" = "0" ]; then
            echo "Restore anulat."
            exit 0
        fi

        if [ -n "${archive:-}" ]; then
            break
        fi

        echo "Selectie invalida."
    done

    archive_name="${archive##*/}"
    checksum="$archive.sha256"

    echo
    echo "Arhiva selectata: $archive_name"
    ls -lh -- "$archive"
    echo

    echo "Verificare integritate zstd..."
    zstd -t "$archive" ||
        die "Arhiva este corupta sau incompleta."

    if [ -f "$checksum" ]; then
        echo "Verificare SHA-256..."
        sha256sum -c "$checksum" ||
            die "Checksum-ul SHA-256 nu corespunde."
    else
        echo "ATENTIE: nu exista fisier checksum:"
        echo "$checksum"
        read -r -p "Continui fara checksum? Scrie YES: " answer

        [ "$answer" = "YES" ] || die "Restore anulat."
    fi

    disk_size_bytes="$(blockdev --getsize64 "$DISK")"

    echo
    echo "============================================================"
    echo "ATENTIE: URMEAZA O OPERATIE DISTRUCTIVA"
    echo
    echo "Arhiva:     $archive"
    echo "Disc tinta: $DISK"
    echo "Dimensiune: $((disk_size_bytes / 1073741824)) GiB"
    echo
    echo "TOATE DATELE DE PE $DISK VOR FI SUPRASCRISE."
    echo "============================================================"
    echo

    read -r -p "Pentru confirmare scrie exact YES: " answer

    [ "$answer" = "YES" ] || die "Restore anulat."

    # Verificam din nou imediat inainte de scriere.
    check_disk_not_mounted

    stamp="$(date +%F_%H-%M-%S)"
    log="$DEST/${MACHINE}-${DISK##*/}-${stamp}.restore.log"

    exec > >(tee -a "$log") 2>&1

    echo "Pornire restore: $(date -Is)"
    echo "Arhiva: $archive"
    echo "Tinta:   $DISK"
    echo

    zstd -dc -- "$archive" |
        dd of="$DISK" \
            bs="$BLOCK_SIZE" \
            iflag=fullblock \
            status=progress \
            conv=fsync

    rc=$?

    echo
    echo "Restore terminat: $(date -Is), cod: $rc"

    if [ "$rc" -ne 0 ]; then
        echo "EROARE: restore-ul a esuat."
        echo "Discul tinta poate contine o imagine incompleta."
        exit "$rc"
    fi

    sync

    echo "Informare kernel despre noua tabela de partitii..."
    if command -v partprobe >/dev/null; then
        partprobe "$DISK" || true
    fi

    echo
    echo "Restore finalizat cu succes: $(date -Is)"
    echo "Log: $log"
    echo "Poti verifica structura discului cu:"
    echo "  lsblk -f $DISK"
}

case "${1:-}" in
    --backup)
        backup_disk
        ;;
    --restore)
        restore_disk
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage
        ;;
esac
