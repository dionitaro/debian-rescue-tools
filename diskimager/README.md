# Backup si restore pentru discul unui VM

Scriptul `thc-disk-backup.sh` creeaza o imagine comprimata a intregului disc al
unui VM si o poate restaura ulterior. Este gandit pentru rulare ca `root` dintr-un
mediu rescue/live, cu destinatia aflata pe un NAS montat prin NFS.

> **Atentie:** operatia `--restore` suprascrie integral discul configurat in
> script. Verifica de fiecare data discul tinta si arhiva selectata.

## Ce salveaza

Este citit intregul block device (implicit `/dev/vda`), nu doar o partitie. Astfel,
imaginea include tabela de partitii, bootloaderul si toate sistemele de fisiere.
Fluxul este comprimat cu `zstd`, verificat dupa scriere si insotit de checksum
SHA-256 si log.

## 1. Pornirea in rescue mode

Porneste VM-ul in rescue mode din panoul [controller.thc.ro](https://controller.thc.ro/)
si conecteaza-te prin SSH. Confirma numele discului inainte sa editezi configuratia:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
```

Scriptul refuza sa lucreze daca discul sau una dintre partitiile lui este montata.

## 2. Instalarea utilitarelor

Pe un rescue Debian/Ubuntu:

```bash
apt-get update
apt-get install -y tmux wireguard-tools nfs-common zstd
```

Instalarile din mediul rescue sunt de regula temporare si dispar la reboot.

## 3. Acces WireGuard catre reteaua NAS-ului

NFS nu ar trebui expus direct pe internet. Foloseste un tunel WireGuard intre VM
si reteaua de acasa. Ai nevoie de configuratia reala furnizata de peer-ul/serverul
WireGuard de acasa.

Creeaza `/etc/wireguard/wg0.conf` cu permisiuni restrictive:

```bash
install -d -m 700 /etc/wireguard
nano /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf
```

Exemplu orientativ (nu introduce chei reale in Git):

```ini
[Interface]
PrivateKey = <CHEIA_PRIVATA_A_CLIENTULUI>
Address = 10.111.0.253/24

[Peer]
PublicKey = <CHEIA_PUBLICA_A_SERVERULUI>
PresharedKey = <OPTIONAL_PRESHARED_KEY>
Endpoint = <IP_SAU_DNS_ACASA>:51820
AllowedIPs = 10.0.0.0/24, 10.111.0.0/24
PersistentKeepalive = 25
```

Porneste tunelul si verifica ruta/conectivitatea:

```bash
wg-quick up wg0
wg show
ip route
ping -c 3 10.0.0.11
```

Adresele si retelele de mai sus sunt doar exemple si trebuie adaptate. Cheia
privata trebuie generata si pastrata in afara repository-ului.

## 4. Montarea share-ului NFS

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

Nu continua daca `mountpoint -q /mnt/_thc_bkp` esueaza. Altfel, datele ar putea
ajunge pe filesystem-ul temporar al mediului rescue in loc de NAS.

## 5. Configurarea scriptului

Editeaza variabilele de la inceputul `thc-disk-backup.sh`:

```bash
MOUNTPOINT="/mnt/_thc_bkp"
MACHINE="vps8"
DISK="/dev/vda"
```

Apoi instaleaza sau ruleaza direct scriptul:

```bash
chmod +x thc-disk-backup.sh
bash -n thc-disk-backup.sh
```

## 6. Backup in tmux

`tmux` permite continuarea backup-ului dupa inchiderea conexiunii SSH:

```bash
tmux new -s thc-backup
./thc-disk-backup.sh --backup
```

Dupa ce transferul a inceput, apasa `Ctrl+B`, elibereaza tastele, apoi apasa `D`.
Poti inchide sesiunea SSH.

La reconectare:

```bash
tmux ls
tmux attach -t thc-backup
```

Un backup complet produce:

- `*.img.zst` - imaginea comprimata;
- `*.img.zst.sha256` - checksum-ul;
- `*.backup.log` - logul operatiei.

Un fisier `*.partial` indica un transfer intrerupt sau esuat si nu trebuie folosit
pentru restore.

## 7. Restore

Porneste tot din rescue mode, conecteaza WireGuard si monteaza NFS, apoi:

```bash
tmux new -s thc-restore
./thc-disk-backup.sh --restore
```

Scriptul permite alegerea arhivei, ii verifica integritatea si checksum-ul, afiseaza
din nou discul tinta si cere confirmarea exacta `YES` inainte de suprascriere.

Dupa restore:

```bash
lsblk -f /dev/vda
sync
```

Opreste VM-ul din rescue mode si selecteaza din panou boot-ul normal de pe disc.

## Observatii

- Imaginea comprimata poate ramane apropiata de marimea discului daca datele nu
  sunt compresibile.
- `conv=noerror,sync` permite backup-ului sa continue la erori de citire, pastrand
  alinierea. Orice eroare trebuie investigata in log.
- Restore-ul necesita un disc cel putin la fel de mare ca discul sursa.
- Nu monta sistemele de fisiere de pe discul sursa in timpul backup-ului.
- Nu expune serviciul NFS direct pe internet.
