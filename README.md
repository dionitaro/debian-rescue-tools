# Backup si restore pentru discul unui VM

Scriptul `diskimager.sh` creeaza o imagine comprimata a intregului disc al
unui VM si o poate restaura ulterior. Este gandit pentru rulare ca `root`
dintr-un mediu rescue/live, cu destinatia aflata pe un NAS montat prin NFS.

E deja instalat in imaginea de rescue la `/opt/diskimager/diskimager.sh`,
cu symlink la `diskimager` (fara `.sh`) - se ruleaza direct din orice
director, ca root.

> **Atentie:** operatia `--restore` suprascrie integral discul selectat.
> Verifica de fiecare data discul tinta si arhiva selectata.

## Ce salveaza

Este citit intregul block device (implicit interactiv, sau `--disk /dev/X`),
nu doar o partitie. Astfel, imaginea include tabela de partitii, bootloaderul
si toate sistemele de fisiere. Fluxul este comprimat cu `zstd`, verificat dupa
scriere si insotit de checksum SHA-256, un fisier `.meta` (dimensiunea exacta
a discului sursa) si un log.

## Utilizare

```bash
diskimager --backup
diskimager --restore
```

Fara `--disk`, scriptul iti arata discurile disponibile (excluzand orice
disc/partitie deja montata - de exemplu mediul rescue de pe care ai bootat)
si te lasa sa alegi interactiv dintr-un meniu numerotat.

La `--restore`, lista de discuri afisate e filtrata automat: apar doar cele
cel putin la fel de mari ca discul sursa original (citit din fisierul
`.meta` al arhivei). Daca niciun disc disponibil nu e suficient de mare,
scriptul iti spune clar acest lucru si se opreste - trebuie sa maresti
discul din panoul hostingului/hypervisorului inainte sa reincerci.

Optiuni disponibile:

```
--disk /dev/sdX      sare peste selectia interactiva
--machine NUME        (implicit: vps8)
--mountpoint /cale     (implicit: /mnt/_thc_bkp)
```

## 1. Pornirea in rescue mode

Porneste VM-ul in rescue mode din panoul de control al hostingului si
conecteaza-te prin SSH.

## 2. Acces WireGuard catre reteaua NAS-ului

Configul WireGuard e deja copt in imagine (din `rescue-config/wireguard/`
la momentul build-ului ISO-ului) si tunelul porneste automat la boot.
Verifica rapid:

```bash
wg show
ip route
ping -c 3 <IP_NAS>
```

## 3. Montarea share-ului NFS

Exemplu, presupunand ca NAS-ul are IP-ul privat `10.0.0.11`:

```bash
mkdir -p /mnt/_thc_bkp
mount -t nfs -o rw,hard,proto=tcp,timeo=600,retrans=2 \
  10.0.0.11:/CALEA_EXPORTULUI /mnt/_thc_bkp
```

Verifica atent ca mount-ul este activ si ca exista suficient spatiu:

```bash
findmnt /mnt/_thc_bkp
df -h /mnt/_thc_bkp
```

## 4. Backup in tmux

`tmux` permite continuarea backup-ului dupa inchiderea conexiunii SSH:

```bash
tmux new -s backup
diskimager --backup --machine vps8
```

Alege discul din meniu (sau da `--disk /dev/vda` direct daca il stii deja).

Dupa ce transferul a inceput, apasa `Ctrl+B`, elibereaza tastele, apoi apasa
`D`. Poti inchide sesiunea SSH. La reconectare: `tmux attach -t backup`.

Un backup complet produce:

- `*.img.zst` - imaginea comprimata
- `*.img.zst.sha256` - checksum-ul
- `*.img.zst.meta` - dimensiunea exacta a discului sursa (folosita la restore)
- `*.backup.log` - logul operatiei

Un fisier `*.partial` indica un transfer intrerupt/esuat si nu trebuie
folosit pentru restore.

## 5. Restore

```bash
tmux new -s restore
diskimager --restore
```

Alegi arhiva, apoi discul tinta (doar cele suficient de mari sunt afisate).
Scriptul ii verifica integritatea si checksum-ul, afiseaza discul tinta si
cere confirmarea exacta `YES` inainte de suprascriere.

Dupa restore:

```bash
lsblk -f /dev/vda
sync
```

## Discul tinta e mai mare decat cel original - ce se intampla?

De exemplu: sursa era pe un disc de 160 GiB, iar VM-ul nou are un disc de
256 GiB. Restore-ul scrie doar cati octeti avea discul original - restul de
~96 GiB ramane neutilizat la finalul discului, exact cum era si inainte,
netusiat de restore. Scriptul iti si spune explicit cati GiB raman liberi.

Ca sa folosesti acel spatiu (de exemplu pentru a extinde un LVM), pasii sunt
manuali si depind de ce ai pe disc:

1. **Daca discul foloseste GPT** (probabil, pe majoritatea VM-urilor moderne):
   dupa restore pe un disc mai mare, structura GPT "crede" in continuare ca
   discul are dimensiunea veche - are nevoie sa fie "reparata" ca sa vada
   spatiul nou:
   ```bash
   parted /dev/vda print
   # parted detecteaza singur discrepanta si ofera sa repare/mute
   # header-ul GPT de backup la finalul real al discului - accepta (Fix)
   ```
   Sau, echivalent, cu `sgdisk`:
   ```bash
   sgdisk -e /dev/vda
   ```

2. **Extinde ultima partitie** ca sa umple spatiul nou:
   ```bash
   parted /dev/vda resizepart <NUMAR_PARTITIE> 100%
   ```

3. **Daca ultima partitie e un LVM physical volume**, spune-i lui LVM ca
   PV-ul are acum mai mult spatiu:
   ```bash
   pvresize /dev/vda<NUMAR_PARTITIE>
   lvextend -l +100%FREE /dev/<vg>/<lv>
   resize2fs /dev/<vg>/<lv>      # pentru ext4
   # sau: xfs_growfs /punct/montare   # pentru xfs
   ```

4. **Daca nu e LVM**, ci un filesystem direct pe partitie, sare peste pasul
   de LVM si mergi direct la `resize2fs`/`xfs_growfs` dupa pasul 2.

Toate astea se fac dupa ce ai pornit sistemul restaurat (sau tot din rescue,
daca preferi) - nu fac parte din `diskimager` momentan, tocmai pentru ca
depind de layout-ul exact al discului (LVM sau nu, ext4 sau xfs etc.) si o
automatizare oarba aici ar fi mai riscanta decat utila.

## Observatii

- Imaginea comprimata poate ramane apropiata de marimea discului daca datele
  nu sunt compresibile.
- `conv=noerror,sync` permite backup-ului sa continue la erori de citire,
  pastrand alinierea. Orice eroare trebuie investigata in log.
- Nu monta sistemele de fisiere de pe discul sursa in timpul backup-ului.
- Nu expune serviciul NFS direct pe internet.
