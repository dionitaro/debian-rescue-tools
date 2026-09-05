# thc-tools

Colectie de utilitare si proceduri pentru administrarea VM-urilor gazduite la
[thc.ro](https://thc.ro/) si gestionate prin
[controller.thc.ro](https://controller.thc.ro/), platforma powered by
[VirtFusion](https://virtfusion.com/).

## Utilitare

### [backup-restore](backup-restore/)

Backup si restore la nivel de block device din rescue mode, cu imagine comprimata
`zstd`, verificare SHA-256, destinatie NFS prin WireGuard si rulare persistenta in
`tmux`.

## Directii viitoare

Repository-ul poate fi extins cu automatizari pentru ciclul de viata al VM-urilor,
inventariere si integrare cu API-ul platformei. Credentialele, cheile private si
tokenurile API nu trebuie incluse in Git.

## Siguranta

Citeste documentatia fiecarui utilitar inainte de rulare. Operatiile de restore,
partitionare sau reprovisionare pot distruge date si trebuie executate numai dupa
verificarea explicita a resursei tinta si a backup-urilor disponibile.
