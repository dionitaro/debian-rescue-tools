#!/usr/bin/env bash

set -o pipefail

# Valori implicite (pot fi suprascrise cu argumente de linie de comanda)
MOUNTPOINT="/mnt/_thc_bkp"
MACHINE="vps8"
DISK=""
ZSTD_LEVEL="3"
BLOCK_SIZE="16M"

usage() {
    cat <<EOF
Utilizare:
  $0 --backup  [--disk /dev/sdX] [--machine NUME] [--mountpoint /cale]
  $0 --restore [--disk /dev/sdX] [--machine NUME] [--mountpoint /cale]

Daca --disk nu e dat, scriptul arata discurile disponibile si lasa
utilizatorul sa aleaga interactiv. La --restore sunt afisate doar
discurile suficient de mari pentru arhiva selectata.
EOF
    exit 2
}

die() {
    echo "EROARE: $*" >&2
    exit 1
}

MODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --backup) MODE="backup" ;;
        --restore) MODE="restore" ;;
        --disk) DISK="${2:-}"; shift ;;
        --machine) MACHINE="${2:-}"; shift ;;
        --mountpoint) MOUNTPOINT="${2:-}"; shift ;;
        -h|--help) usage ;;
        *) echo "Argument necunoscut: $1"; usage ;;
    esac
    shift
done

[ -n "$MODE" ] || usage

DEST="$MOUNTPOINT/$MACHINE"

is_rescue_mode() {
    grep -qwE 'boot=live|rescue' /proc/cmdline 2>/dev/null ||
        [ -e /run/live/rootfs/filesystem.squashfs ] ||
        mountpoint -q /run/live/medium 2>/dev/null
}

disk_is_mounted() {
    local dev="$1"
    lsblk -nrpo NAME,MOUNTPOINTS "$dev" 2>/dev/null | awk 'NF > 1 { f=1 } END { exit !f }'
}

check_common() {
    local cmd

    [ "$(id -u)" -eq 0 ] ||
        die "Scriptul trebuie rulat ca root."

    is_rescue_mode ||
        die "Masina nu pare pornita in rescue/live mode."

    mountpoint -q "$MOUNTPOINT" ||
        die "NAS-ul nu este montat la $MOUNTPOINT."

    for cmd in awk blockdev dd df findmnt lsblk mountpoint sha256sum tee zstd; do
        command -v "$cmd" >/dev/null ||
            die "Comanda necesara lipseste: $cmd"
    done

    mkdir -p "$DEST" ||
        die "Nu pot crea directorul $DEST."

    [ -w "$DEST" ] ||
        die "Directorul $DEST nu este writeable."
}

# NAME, SIZE, MODEL pentru discuri fizice (exclude partitii, loop, cdrom)
list_candidate_disks() {
    lsblk -dnrpo NAME,SIZE,MODEL -e7,11 2>/dev/null
}

# Selecteaza interactiv un disc si seteaza $DISK.
# $1 = mesaj afisat, $2 = minim de bytes ceruta (optional, default 0)
select_disk() {
    local prompt="$1" min_bytes="${2:-0}"
    local dev size model bytes
    local candidates=() labels=()

    while read -r dev size model; do
        [ -n "$dev" ] || continue
        disk_is_mounted "$dev" && continue
        bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
        [ "$bytes" -ge "$min_bytes" ] || continue
        candidates+=("$dev")
        labels+=("$dev  ($size${model:+, $model})")
    done < <(list_candidate_disks)

    if [ "${#candidates[@]}" -eq 0 ]; then
        if [ "$min_bytes" -gt 0 ]; then
            echo "Nu exista niciun disc liber de cel putin $(( min_bytes / 1073741824 )) GiB."
            echo "Mareste discul din panoul hostingului/hypervisorului, apoi ruleaza din nou."
        else
            echo "Nu exista niciun disc liber (neutilizat) pe aceasta masina."
        fi
        exit 1
    fi

    echo "$prompt"
    PS3="Selecteaza numarul discului (0 pentru anulare): "
    select choice in "${labels[@]}"; do
        if [ "$REPLY" = "0" ]; then
            echo "Anulat."
            exit 0
        fi
        if [ -n "${choice:-}" ]; then
            DISK="${candidates[$((REPLY-1))]}"
            return 0
        fi
        echo "Selectie invalida."
    done
}

check_disk_not_mounted() {
    if disk_is_mounted "$DISK"; then
        echo "EROARE: discul sau una dintre partitiile sale este in uz:"
        lsblk -nrpo NAME,MOUNTPOINTS "$DISK" | awk 'NF > 1'
        exit 1
    fi
}

# Citeste disk_bytes dintr-un fisier .meta asociat unei arhive. 0 daca lipseste.
read_required_bytes() {
    local meta="$1.meta"
    if [ -f "$meta" ]; then
        awk -F= '/^disk_bytes=/ { print $2; exit }' "$meta"
    else
        echo 0
    fi
}

backup_disk() {
    local stamp disk_name disk_size_gib backup partial log meta rc
    local disk_bytes available_bytes answer

    check_common

    [ -n "$DISK" ] || select_disk "Alege discul sursa pentru backup:"

    [ -b "$DISK" ] || die "$DISK nu exista sau nu este block device."
    check_disk_not_mounted

    stamp="$(date +%F_%H-%M-%S)"
    disk_name="${DISK##*/}"
    disk_bytes="$(blockdev --getsize64 "$DISK")"
    disk_size_gib="$(( (disk_bytes + 1073741823) / 1073741824 ))"

    backup="$DEST/${MACHINE}-${disk_name}-${disk_size_gib}G-${stamp}.img.zst"
    partial="${backup}.partial"
    log="$DEST/${MACHINE}-${disk_name}-${stamp}.backup.log"
    meta="${backup}.meta"

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
    echo "Sursa:           $DISK ($disk_size_gib GiB)"
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

    cat > "$meta" <<META
disk_bytes=$disk_bytes
disk_name=$disk_name
machine=$MACHINE
created=$(date -Is)
META

    sync

    echo
    echo "Backup finalizat cu succes: $(date -Is)"
    echo "Imagine:  $backup"
    echo "Checksum: $backup.sha256"
    echo "Metadate: $meta"
    echo "Log:      $log"
}

restore_disk() {
    local archives archive checksum meta log answer rc required_bytes
    local stamp archive_name disk_size_bytes disk_bytes_now

    check_common

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
    meta="$archive.meta"

    echo
    echo "Arhiva selectata: $archive_name"
    ls -lh -- "$archive"
    echo

    required_bytes="$(read_required_bytes "$archive")"
    if [ "$required_bytes" -gt 0 ]; then
        echo "Discul sursa original: $((required_bytes / 1073741824)) GiB (exact: $required_bytes bytes)."
    else
        echo "ATENTIE: nu exista fisier .meta pentru arhiva asta - nu pot verifica"
        echo "automat daca discul tinta e suficient de mare. Verifica manual."
    fi
    echo

    [ -n "$DISK" ] || select_disk "Alege discul tinta pentru restore:" "$required_bytes"

    [ -b "$DISK" ] || die "$DISK nu exista sau nu este block device."
    check_disk_not_mounted

    [ "$(lsblk -dnro RO "$DISK")" = "0" ] ||
        die "$DISK este read-only."

    if [ "$required_bytes" -gt 0 ]; then
        disk_bytes_now="$(blockdev --getsize64 "$DISK")"
        if [ "$disk_bytes_now" -lt "$required_bytes" ]; then
            die "$DISK ($((disk_bytes_now / 1073741824)) GiB) e mai mic decat sursa originala ($((required_bytes / 1073741824)) GiB). Mareste discul si reincearca."
        fi
    fi

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
    if [ "$required_bytes" -gt 0 ] && [ "$disk_size_bytes" -gt "$required_bytes" ]; then
        echo "Spatiu neutilizat dupa restore: $(( (disk_size_bytes - required_bytes) / 1073741824 )) GiB"
        echo "(vezi README pentru extindere manuala de partitie/LVM ulterior)"
    fi
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
    echo "Tinta:  $DISK"
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

    if [ "$required_bytes" -gt 0 ] && [ "$disk_size_bytes" -gt "$required_bytes" ]; then
        echo
        echo "Discul tinta e mai mare decat sursa - spatiul suplimentar nu e"
        echo "folosit inca. Vezi README pentru pasii de extindere partitie/LVM."
    fi
}

case "$MODE" in
    backup) backup_disk ;;
    restore) restore_disk ;;
    *) usage ;;
esac
