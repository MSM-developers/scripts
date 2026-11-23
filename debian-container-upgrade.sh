#!/bin/sh
# Debian LXC/Container: 11 -> 12 oder 12 -> 13
# Vollautomatisch, ohne Rueckfragen. Ein Upgrade pro Lauf.
# ACHTUNG: Nach erfolgreicher Pruefung wird der Container neu gestartet.
set -eu
umask 077

BACKUP=''
LOGFILE=''
SCHRITT='Vorpruefung'
LOCK_DIR='/run/debian-container-upgrade.lock'
LOCK_AKTIV=0

meldung() {
    printf '%s\n' "$*"
    if [ -n "$LOGFILE" ]; then
        printf '%s\n' "$*" >> "$LOGFILE"
    fi
}

abbruch() {
    printf '\n[FEHLER] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    STATUS=$?
    trap - 0 HUP INT TERM

    if [ "$STATUS" -ne 0 ]; then
        printf '\n[ABBRUCH] Schritt: %s (Exit-Code: %s)\n' "$SCHRITT" "$STATUS" >&2
        if [ -n "$LOGFILE" ] && [ -f "$LOGFILE" ]; then
            printf '\nLetzte 35 Log-Zeilen:\n' >&2
            tail -n 35 "$LOGFILE" >&2 || :
            printf '\nVollstaendiges Log: %s\n' "$LOGFILE" >&2
        fi
        if [ -n "$BACKUP" ]; then
            printf 'APT-Backup: %s/apt\n' "$BACKUP" >&2
            printf 'Kein automatischer Rollback der installierten Pakete. KEIN Neustart.\n' >&2
        fi
    fi

    if [ "$LOCK_AKTIV" -eq 1 ]; then
        rm -f "$LOCK_DIR/pid" || :
        rmdir "$LOCK_DIR" || :
    fi
}

trap 'cleanup' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

schritt() {
    SCHRITT=$1
    shift
    meldung ""
    meldung "==> $SCHRITT"
    if "$@" >> "$LOGFILE" 2>&1; then
        meldung "[OK] $SCHRITT"
    else
        CODE=$?
        printf '[FEHLER] %s (Exit-Code: %s)\n' "$SCHRITT" "$CODE" >&2
        exit "$CODE"
    fi
}

schreibe_quellen() {
    CODENAME=$1
    cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: $CODENAME $CODENAME-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: $CODENAME-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

schreibe_bullseye_archiv() {
    # Debian 11 ist EOL: archivierte, weiterhin signierte Quellen.
    # Keine globalen Abschaltungen der Signaturpruefung.
    cat > /etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: https://archive.debian.org/debian
Suites: bullseye
Components: main contrib non-free
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no

Types: deb
URIs: https://archive.debian.org/debian-security
Suites: bullseye-security
Components: main contrib non-free
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no
EOF
}

# Proxmox-Host duerfen wir nicht automatisch neu starten.
[ "$(id -u)" -eq 0 ] || abbruch 'Bitte als root IM Container ausfuehren.'
[ -r /etc/os-release ] || abbruch '/etc/os-release fehlt.'
. /etc/os-release
[ "${ID:-}" = debian ] || abbruch 'Unterstuetzt wird nur Debian.'
if command -v pveversion >/dev/null 2>&1; then
    abbruch 'Proxmox-Host erkannt! Bitte nur im LXC-Container ausfuehren.'
fi

case "${VERSION_ID:-}" in
    11) ALT='bullseye'; NEU='bookworm'; ZIEL='12' ;;
    12) ALT='bookworm'; NEU='trixie'; ZIEL='13' ;;
    *) abbruch 'Nur Debian 11 -> 12 und Debian 12 -> 13 werden unterstuetzt.' ;;
esac

for WERKZEUG in apt-get apt-mark dpkg dpkg-query cp mv mktemp df awk tail; do
    command -v "$WERKZEUG" >/dev/null 2>&1 || abbruch "Benoetigtes Kommando fehlt: $WERKZEUG"
done
[ -r /usr/share/keyrings/debian-archive-keyring.gpg ] || \
    abbruch 'Debian-Archive-Keyring fehlt; zuerst reparieren.'

# Sicherheitscheck: keine halb installierten oder bewusst blockierten Pakete.
AUDIT=$(dpkg --audit 2>&1) || abbruch "dpkg --audit fehlgeschlagen: $AUDIT"
[ -z "$AUDIT" ] || abbruch "Unvollstaendige Pakete vorhanden:
$AUDIT"
HOLDS=$(apt-mark showhold 2>&1) || abbruch "apt-mark showhold fehlgeschlagen: $HOLDS"
[ -z "$HOLDS" ] || abbruch "Zurueckgehaltene Pakete vorhanden:
$HOLDS"

# Mindestreserve. Achtung: apt kann je nach Paketbestand mehr benoetigen.
FREI_KB=$(df -Pk / | awk 'NR==2 {print $4}')
case "$FREI_KB" in
    ''|*[!0-9]*) abbruch 'Freien Speicherplatz konnte ich nicht ermitteln.' ;;
esac
[ "$FREI_KB" -ge 1048576 ] || abbruch 'Weniger als 1 GiB frei auf /: Upgrade abgebrochen.'

# Doppelte Starts verhindern. Das Lock liegt im fluechtigen /run.
mkdir -p /run
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    abbruch "Ein Upgrade laeuft bereits oder ein Lock ist uebrig: $LOCK_DIR"
fi
LOCK_AKTIV=1
printf '%s\n' "$$" > "$LOCK_DIR/pid"

BACKUP=$(mktemp -d "/root/debian-upgrade-${VERSION_ID}-to-${ZIEL}-XXXXXXXX")
cp -a /etc/apt "$BACKUP/apt"
dpkg --get-selections > "$BACKUP/pakete-vorher.txt"
LOGFILE="$BACKUP/upgrade.log"
: > "$LOGFILE"

# Keine Changelog-Pager, keine Ja/Nein-Fragen und keine dpkg-Konfigurationsdialoge.
# Bestehende lokale Konfigurationsdateien werden bei Konflikten beibehalten.
export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
export APT_LISTCHANGES_FRONTEND=none
export APT_LISTBUGS_FRONTEND=none
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1
export PAGER=cat
export SYSTEMD_PAGER=cat

apt_automatisch() {
    apt-get -y \
        -o 'Dpkg::Options::=--force-confdef' \
        -o 'Dpkg::Options::=--force-confold' \
        -o 'DPkg::Lock::Timeout=120' \
        "$@"
}

apt_update() {
    # Auch Warnungen ueber unerreichbare Indizes als Fehler behandeln.
    apt_automatisch -o 'APT::Update::Error-Mode=any' update --allow-releaseinfo-change
}

meldung '============================================================'
meldung " Debian $VERSION_ID ($ALT) -> Debian $ZIEL ($NEU)"
meldung ' AUTOMATISCHER UPGRADE-MODUS (inklusive Container-Neustart)'
meldung '============================================================'
meldung "APT-Backup: $BACKUP/apt"
meldung "Logdatei:   $LOGFILE"
meldung 'Ein externes Proxmox-Backup/Snapshot muss bereits vorhanden sein!'

# Nur eine definierte, offizielle Debian-Quelle je Upgrade-Phase aktiv lassen.
SCHRITT='Alte Paketquellen sichern und deaktivieren'
mkdir -p /etc/apt/sources.list.d "$BACKUP/deaktivierte-quellen"
rm -f /etc/apt/sources.list
: > /etc/apt/sources.list
for QUELLE in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -e "$QUELLE" ] || [ -L "$QUELLE" ] || continue
    mv "$QUELLE" "$BACKUP/deaktivierte-quellen/"
done
meldung '[OK] Originale APT-Quellen gesichert und deaktiviert.'

SCHRITT='Alte Debian-Paketquellen konfigurieren'
if [ "$VERSION_ID" = 11 ]; then
    schreibe_bullseye_archiv
    meldung 'Debian 11: archivierte Bullseye- und Security-Quellen aktiv.'
else
    schreibe_quellen "$ALT"
fi

schritt '[1/8] Paketlisten der alten Debian-Version laden' apt_update
schritt '[2/8] Installierte Pakete der alten Version aktualisieren' apt_automatisch upgrade
schritt '[3/8] Debian-Archive-Keyring aktualisieren' apt_automatisch install debian-archive-keyring

SCHRITT="Paketquellen auf $NEU umstellen"
schreibe_quellen "$NEU"
meldung "[OK] Paketquellen auf Debian $ZIEL ($NEU) umgestellt."

schritt '[4/8] Paketlisten der neuen Version laden' apt_update
schritt '[5/8] Minimales Versions-Upgrade' apt_automatisch upgrade --without-new-pkgs
schritt '[6/8] Abhaengigkeiten des Voll-Upgrades pruefen' apt_automatisch -s dist-upgrade
schritt '[7/8] Vollstaendiges Versions-Upgrade' apt_automatisch dist-upgrade
schritt '[8/8] APT-Paketkonsistenz pruefen' apt_automatisch check

SCHRITT='Abschlusskontrolle'
NACH_AUDIT=$(dpkg --audit 2>&1) || abbruch 'dpkg --audit nach dem Upgrade fehlgeschlagen.'
[ -z "$NACH_AUDIT" ] || abbruch "Paketstatus unvollstaendig: $NACH_AUDIT"

# /etc/os-release neu laden: base-files muss die neue Version melden.
. /etc/os-release
[ "${VERSION_ID:-}" = "$ZIEL" ] || \
    abbruch "Upgrade-Pruefung fehlgeschlagen: erwartete Debian $ZIEL, erkannt ${VERSION_ID:-unbekannt}."

dpkg --get-selections > "$BACKUP/pakete-nachher.txt"
meldung "[ERFOLG] Debian $ZIEL ($NEU) installiert. Alle Paketpruefungen bestanden."
meldung "Log und Backup bleiben erhalten: $BACKUP"
meldung 'Drittanbieter-Paketquellen bleiben zur Sicherheit deaktiviert.'
meldung 'Automatischer Neustart des Containers wird jetzt eingeleitet.'

SCHRITT='Automatischer Neustart'
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    if systemctl reboot >> "$LOGFILE" 2>&1; then
        exit 0
    fi
    meldung 'WARNUNG: systemctl reboot fehlgeschlagen, versuche reboot.'
fi
if command -v reboot >/dev/null 2>&1; then
    if reboot >> "$LOGFILE" 2>&1; then
        exit 0
    fi
fi
abbruch 'Automatischer Neustart nicht moeglich. Bitte den Container manuell rebooten.'
