# Init-Blueprint – Gemeinsame Laufzeitumgebung

Compose-Umgebung und Build-Skript für die Blueprint-Projekte: PostgreSQL, Keycloak und alle
Backend-APIs. Gesamtübersicht (REST-Vertrag, Architektur, Konventionen) in [Blueprint.md](Blueprint.md).

## Ordnerstruktur

Die Projekte liegen als Geschwister neben `Init-Blueprint`:

```
Blueprint/
├── Init-Blueprint/      docker-compose.yml, build-images.sh, setup/
├── NET-Blueprint/
├── Java-Blueprint/
└── Angular-Blueprint/
```

`build-images.sh` findet die Projekte im übergeordneten Ordner – die Ordnernamen müssen so bleiben.

## Starten

```bash
./build-images.sh       # fehlende Images bauen, NET-Migration anwenden, Compose starten
./build-images.sh -f    # alle Images neu bauen
docker compose up -d    # nur starten (Images müssen existieren)
docker compose down     # stoppen
```

Einzelner Service (Namen: `postgres`, `keycloak`, `net-api`, `net-minimal-api`, `java-api`):

```bash
docker compose down java-api       # stoppen und Container entfernen
docker compose stop java-api       # nur stoppen, Container bleibt
docker compose up -d java-api      # wieder starten
```

`docker compose down <service>` ist ab Docker Compose 2.20 verfügbar. Abhängige Services werden
nicht mitgestoppt; Volumes bleiben erhalten.

Voraussetzungen: Docker (oder Podman + `podman-compose`, wird bevorzugt), .NET 10 SDK mit
`dotnet-ef`, Java 21. Das Skript führt `dotnet publish` und `./mvnw package` selbst aus.

## Dienste

| Dienst | URL | Hinweis |
|---|---|---|
| PostgreSQL | `localhost:5432` | DBs `blueprint_net`, `blueprint_java`; `blueprint`/`blueprint` |
| Keycloak | http://localhost:8180 | Realm `blueprint`, Admin-Konsole `keycloak`/`keycloak` |
| NET Controller-API | http://localhost:5102/swagger | |
| NET Minimal-API | http://localhost:5206/swagger | |
| Java-API | http://localhost:5105/swagger | |

Benutzer: `reader`/`reader` (lesen), `writer`/`writer` (anlegen, ändern), `admin`/`admin`
(zusätzlich löschen). Das Frontend (`Angular-Blueprint`, `npm start`) greift über seinen
Dev-Proxy auf diese Ports zu.

## Setup-Dateien

- `setup/postgres/init/` – SQL-Skripte, die beim **ersten** Start des Postgres-Volumes laufen
  (legt `blueprint_java` an). Für einen Neustart mit leerer DB: `docker compose down -v`.
- `setup/keycloak/blueprint-export.json` – vollständiger Realm-Export. Keycloak hat kein Volume:
  jeder neu erstellte Container (`docker compose up -d --force-recreate keycloak`) startet wieder
  exakt mit dem Export. Neu exportieren siehe [Blueprint.md](Blueprint.md#sicherheit-keycloak).
