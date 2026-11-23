#!/bin/sh
# Debian-Container: 11 (bullseye) -> 12 (bookworm) -> 13 (trixie)
# Ausfuehren als root. Pro Lauf nur EIN Versionssprung.
set -eu

fail() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail 'Bitte als root im Container starten.'
[ -r /etc/os-release ] || fail '/etc/os-release fehlt.'
. /etc/os-release
[ "${ID:-}" = debian ] || fail 'Nur Debian wird unterstuetzt.'
if command -v pveversion >/dev/null 2>&1; then
  fail 'Nicht auf dem Proxmox-Host ausfuehren, sondern im LXC-Container!'
fi

case "${VERSION_ID:-}" in
  11) ALT=bullseye; NEU=bookworm; NEU_VERSION=12 ;;
  12) ALT=bookworm; NEU=trixie; NEU_VERSION=13 ;;
  *) fail 'Unterstuetzt werden nur Debian 11 -> 12 und 12 -> 13.' ;;
esac

printf '\nDebian %s (%s) -> Debian %s (%s)\n' "$VERSION_ID" "$ALT" "$NEU_VERSION" "$NEU"
printf '%s\n' 'WICHTIG: Vorher ein Proxmox-Backup/Snapshot des Containers erstellen!'
printf '%s\n' 'Vorhandene APT-Quellen (auch Drittanbieter) werden gesichert und deaktiviert.'
printf 'Upgrade wirklich starten? [j/N] '
if [ -r /dev/tty ]; then
  IFS= read -r ANTWORT </dev/tty || exit 1
else
  IFS= read -r ANTWORT || exit 1
fi
case "$ANTWORT" in
  j|J|ja|JA|y|Y|yes|YES) ;;
  *) echo 'Abgebrochen.'; exit 0 ;;
esac

if [ -n "$(dpkg --audit)" ]; then
  dpkg --audit
  fail 'Erst die unvollstaendig installierten Pakete reparieren.'
fi
if [ -n "$(apt-mark showhold)" ]; then
  apt-mark showhold
  fail 'Erst die zurueckgehaltenen Pakete pruefen (apt-mark showhold).'
fi

BACKUP=$(mktemp -d "/root/debian-upgrade-${VERSION_ID}-to-${NEU_VERSION}-XXXXXX")
cp -a /etc/apt "$BACKUP/apt"
dpkg --get-selections > "$BACKUP/pakete.txt"
printf '\nBackup der APT-Konfiguration: %s\n' "$BACKUP"

# Alte APT-Quellen ausschalten, ohne sie zu loeschen.
mkdir -p /etc/apt/sources.list.d "$BACKUP/deaktivierte-quellen"
: > /etc/apt/sources.list
for QUELLE in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [ -e "$QUELLE" ] || continue
  mv "$QUELLE" "$BACKUP/deaktivierte-quellen/"
done

# Definierte Debian-Quellen im modernen deb822-Format schreiben.
schreibe_quellen() {
  VERSION=$1
  cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: $VERSION $VERSION-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: $VERSION-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

printf '\n[1/3] Alte Debian-Version aktualisieren...\n'
if [ "$VERSION_ID" = 11 ]; then
  # Bullseye ist seit August 2026 archiviert. Keine abgelaufenen
  # Security-Quellen mehr verwenden; Signaturen bleiben verpflichtend.
  cat > /etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: https://archive.debian.org/debian
Suites: bullseye
Components: main contrib non-free
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  apt-get -o Acquire::Check-Valid-Until=false update
else
  schreibe_quellen "$ALT"
  apt-get update
fi
apt-get upgrade
apt-get install debian-archive-keyring

printf '\n[2/3] Paketquellen auf %s umstellen...\n' "$NEU"
schreibe_quellen "$NEU"
apt-get update --allow-releaseinfo-change

printf '\n[3/3] Debian-Upgrade installieren...\n'
apt-get upgrade
apt-get dist-upgrade

printf '\nUpgrade abgeschlossen. Installierte Version: '
cat /etc/debian_version
printf 'APT-Backup: %s\n' "$BACKUP"
printf '%s\n' 'Jetzt den Container ueber den Proxmox-Host neu starten und Dienste pruefen.'
printf '%s\n' 'Drittanbieter-Repositories bei Bedarf kompatibel wieder aktivieren.'
