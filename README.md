# Debian Container Upgrade

Ein einfaches Shell-Skript zum Upgrade von Debian-Containern (z. B. **Proxmox LXC**) auf die jeweils nächste Debian-Hauptversion.

**Repository:** [MSM-developers/scripts](https://github.com/MSM-developers/scripts) (privat)  
**Skript:** [`debian-container-upgrade.sh`](https://github.com/MSM-developers/scripts/blob/main/debian-container-upgrade.sh)

## Unterstützte Upgrades

| Ausgangsversion | Zielversion |
| --- | --- |
| Debian 11 (Bullseye) | Debian 12 (Bookworm) |
| Debian 12 (Bookworm) | Debian 13 (Trixie) |

Pro Ausführung erfolgt **genau ein Versionssprung**. Für Debian 11 → 13 das Skript nach erfolgreichem Upgrade, Neustart und Überprüfung erneut ausführen.

## Voraussetzungen

- Debian 11 oder 12 im Container
- `root`-Zugriff im Container
- `curl` und eine funktionierende Internetverbindung
- Ausreichend freier Speicherplatz
- **Vorher ein Proxmox-Backup oder einen Snapshot erstellen**
- Bei privatem GitHub-Repository: ein [Fine-grained Personal Access Token](https://github.com/settings/personal-access-tokens) mit Zugriff auf `MSM-developers/scripts` und **Contents: Read-only**

> **Wichtig:** Das Skript ändert Paketquellen und installiert zahlreiche Systempakete. Prüfe vorab die Kompatibilität deiner Anwendungen. Es erstellt selbst keinen Proxmox-Snapshot und führt keinen automatischen Neustart durch.

## Installation und Ausführung (privates GitHub-Repository)

Den folgenden **Einzeiler als `root` in einer interaktiven Bash-Shell im Debian-Container** ausführen:

```bash
read -rsp 'GitHub-Token: ' GH_TOKEN; echo; if [ -n "$GH_TOKEN" ]; then curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github.raw+json' 'https://api.github.com/repos/MSM-developers/scripts/contents/debian-container-upgrade.sh?ref=main' -o /tmp/debian-container-upgrade.sh && sh /tmp/debian-container-upgrade.sh; fi; unset GH_TOKEN
```

Der Befehl fragt das Token verdeckt ab, lädt die **Raw-Datei über die GitHub-API** herunter und startet sie anschließend. Durch `&&` wird das Skript nur gestartet, wenn der Download erfolgreich war. Das Token muss nicht in die Befehlszeile eingefügt werden und landet dadurch nicht als Klartext in der Shell-History.

**Token erstellen:** GitHub → *Settings* → *Developer settings* → *Personal access tokens* → *Fine-grained tokens*. Als Repository `MSM-developers/scripts` auswählen und für **Contents** nur **Read-only** vergeben. Token nicht in Git committen oder in Skripten hinterlegen. Beachte, dass ein Token während der `curl`-Ausführung kurzzeitig in Prozessargumenten sichtbar sein kann.

### Alternative: Manuell aus einer lokalen Datei

Wenn du das Skript bereits heruntergeladen hast:

```bash
sh debian-container-upgrade.sh
```

## Ablauf

1. Prüft `root`-Rechte und die installierte Debian-Version (11 oder 12).
2. Fragt vor dem Upgrade nach einer Bestätigung.
3. Prüft den Paketstatus und zurückgehaltene Pakete.
4. Sichert `/etc/apt` sowie eine Paketliste unter `/root/debian-upgrade-...`.
5. Deaktiviert bestehende Paketquellen, darunter Drittanbieter-Repositories.
6. Aktualisiert die alte Debian-Version; für Debian 11 wird das Debian-Archiv verwendet.
7. Stellt die Debian-Paketquellen auf die nächste Version um und führt das Paket-Upgrade aus.
8. Gibt die installierte Version und den Speicherort des APT-Backups aus.

**Hinweis:** Die Installation kann interaktive Rückfragen von APT oder `dpkg` enthalten. Das Skript deaktiviert Drittanbieter-Repositories, aktiviert sie aber nicht automatisch wieder.

## Nach dem Upgrade

Prüfe zunächst die angezeigte Ausgabe auf Fehler. Starte den Container dann **auf dem Proxmox-Host** neu (hier ist `101` nur eine Beispiel-CT-ID):

```bash
pct reboot 101
```

Anschließend im Container prüfen:

```bash
cat /etc/os-release
apt-get update
systemctl --failed
```

Kontrolliere deine Anwendungen und aktiviere erforderliche Drittanbieter-Repositories **erst nach Prüfung der Kompatibilität** wieder. Falls du von Debian 11 direkt auf Debian 13 möchtest, wiederhole das Upgrade erst, wenn Debian 12 nach dem Neustart stabil funktioniert.

## Sicherheit und Fehlerbehebung

- **Kein Backup, kein Upgrade:** Sichere den Container auf dem Proxmox-Host vor dem Start.
- **Downloadfehler 401/403/404:** Prüfe Token, Token-Berechtigungen, Repository-Freigabe und Branch `main`.
- **APT-/Paketfehler:** Fehlermeldungen prüfen und nicht blind ein weiteres Upgrade starten. Das APT-Backup liegt unter `/root/debian-upgrade-...`.
- **Proxmox-Host:** Das Skript ist für die Ausführung **im Container** gedacht und verweigert die Ausführung, wenn `pveversion` vorhanden ist.
- **Keine vollständige Kompatibilitätsprüfung:** Anwendungsspezifische Repositories, installierte Dienste und Konfigurationsdateien müssen ggf. manuell angepasst werden.

## Technische Hinweise

- Shell: POSIX `sh` für das Upgrade-Skript, **Bash** für den obigen Token-Einzeiler
- Das Skript ist **nicht für unbeaufsichtigte Upgrades** vorgesehen.
- Die Ausführung erfolgt auf eigene Verantwortung; der Upgrade-Prozess sollte zunächst an einem Testcontainer geprüft werden.

Weitere Informationen: [Debian-Release-Notes](https://www.debian.org/releases/), [GitHub REST API: Repository contents](https://docs.github.com/en/rest/repos/contents).
