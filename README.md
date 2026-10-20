# Init-Blueprint – Gemeinsame Laufzeitumgebung

Compose-Umgebung und Build-Skript für die Blueprint-Projekte: PostgreSQL, Keycloak, alle
Backend-APIs, Ollama (lokales LLM) und das KI-Gateway (`Python-Blueprint`) für den KI-Assistenten. Gesamtübersicht (REST-Vertrag, Architektur, Konventionen) in [Blueprint.md](Blueprint.md).

## Voraussetzungen

| Software | Version | Wofür |
|---|---|---|
| Docker Desktop (oder Podman + `podman-compose`) | Compose ≥ 2.20 | Container; Podman wird bevorzugt, falls installiert |
| .NET SDK | 10 | `dotnet publish` der NET-APIs |
| `dotnet-ef` | 10 | EF-Core-Migration (`dotnet tool install --global dotnet-ef`) |
| Java JDK | 21 | `./mvnw package` der Java-API (Maven lädt der Wrapper selbst) |
| Python | 3.13 | nur für die lokale Entwicklung von `Python-Blueprint` (das Image baut ohne) |
| Bash | – | `build-images.sh`; unter Windows Git Bash |
| Node.js | `^20.19.0`, `^22.12.0` oder `>=24.0.0` | nur für das Frontend (`Angular-Blueprint`, Angular 21) |
| NVIDIA-GPU + Treiber | ≥ 6 GB VRAM empfohlen | Ollama nutzt die GPU über die NVIDIA-Runtime von Docker Desktop (WSL2) |

## Ordnerstruktur

Die Projekte liegen als Geschwister neben `Init-Blueprint`:

```
Blueprint/
├── Init-Blueprint/      docker-compose.yml, build-images.sh, setup/
├── NET-Blueprint/
├── Java-Blueprint/
├── Python-Blueprint/
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

Einzelner Service (Namen: `postgres`, `keycloak`, `net-api`, `net-minimal-api`, `java-api`,
`ollama`, `ollama-pull`, `ai-api`):

```bash
docker compose down java-api       # stoppen und Container entfernen
docker compose stop java-api       # nur stoppen, Container bleibt
docker compose up -d java-api      # wieder starten
```

`docker compose down <service>` ist ab Docker Compose 2.20 verfügbar. Abhängige Services werden
nicht mitgestoppt; Volumes bleiben erhalten.

Das Skript führt `dotnet publish` und `./mvnw package` selbst aus.

## Dienste

| Dienst | URL | Hinweis |
|---|---|---|
| PostgreSQL | `localhost:5432` | DBs `blueprint_net`, `blueprint_java`; `blueprint`/`blueprint` |
| Keycloak | http://localhost:8180 | Realm `blueprint`, Admin-Konsole `keycloak`/`keycloak` |
| NET Controller-API | http://localhost:5102/swagger | |
| NET Minimal-API | http://localhost:5206/swagger | |
| Java-API | http://localhost:5105/swagger | |
| Ollama | http://localhost:11434 | Modell `qwen3:8b`, OpenAI-kompatibel unter `/v1` |
| KI-Gateway | http://localhost:5300/docs | leitet an Ollama/OpenAI weiter, Keycloak-geschützt |

### OpenAI-Key (KI-Gateway)

Neben `docker-compose.yml` eine `.env` (git-ignoriert) mit der Zeile `OPENAI_API_KEY=sk-…`
anlegen. Compose liest die Datei automatisch und gibt den Key nur an
`ai-api` weiter; nach einer Änderung `docker compose up -d ai-api`. Ohne Key funktioniert nur das
lokale Modell (OpenAI antwortet mit 401).

### Ollama (KI-Assistent)

- `ollama-pull` lädt beim Start einmalig `qwen3:8b` (~5 GB) ins Volume `ollama-data` und beendet
  sich dann; ist das Modell schon da, ist es ein No-op. Fortschritt: `docker logs -f blueprint-ollama-pull`.
- Kontext 8192 Tokens (`OLLAMA_CONTEXT_LENGTH`), Modell bleibt 30 min geladen (`OLLAMA_KEEP_ALIVE`).
  Die erste Anfrage nach dem Start dauert ~1 min (Laden ins VRAM), danach wenige Sekunden.
- Ohne NVIDIA-GPU: den `deploy`-Block beim Service `ollama` entfernen – läuft dann auf der CPU
  (deutlich langsamer).
- Anderes Modell: in `ollama-pull`, in der Allowlist von `ai-api` (`OLLAMA_MODELS`) und in
  `Angular-Blueprint/public/config.json` (`chat.providers`) ändern.

Benutzer: `reader`/`reader` (lesen), `writer`/`writer` (anlegen, ändern), `admin`/`admin`
(zusätzlich löschen). Das Frontend (`Angular-Blueprint`, `npm start`) greift über seinen
Dev-Proxy auf diese Ports zu.

## Setup-Dateien

- `setup/postgres/init/` – SQL-Skripte, die beim **ersten** Start des Postgres-Volumes laufen
  (legt `blueprint_java` an). Für einen Neustart mit leerer DB: `docker compose down -v`.
- `setup/keycloak/blueprint-export.json` – vollständiger Realm-Export. Keycloak hat kein Volume:
  jeder neu erstellte Container (`docker compose up -d --force-recreate keycloak`) startet wieder
  exakt mit dem Export. Neu exportieren siehe [Blueprint.md](Blueprint.md#sicherheit-keycloak).
