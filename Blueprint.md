# Blueprint – Gesamtübersicht

Referenz-Implementierung einer Personen-/Adressverwaltung in drei Technologien mit **einem
gemeinsamen REST-Vertrag**:

| Projekt | Stack | Rolle |
|---|---|---|
| `NET-Blueprint` | .NET 10, EF Core 10, PostgreSQL | Backend – Controller-API **und** Minimal-API auf gemeinsamer Application/Infrastructure |
| `Java-Blueprint` | Java 21, Spring Boot 4.1, JPA, Flyway, PostgreSQL | Backend – Port des NET-Blueprints |
| `Angular-Blueprint` | Angular 21, Angular Material, Signals, Jest | Frontend – zur Laufzeit zwischen den Backends umschaltbar |

Jedes Projekt ist ein eigenes Git-Repository. Gemeinsam in `Init-Blueprint`: `docker-compose.yml`,
`build-images.sh`, `setup/postgres/init`, `setup/keycloak`. `build-images.sh` findet die Projekte im übergeordneten Ordner.

---

## 1. Gemeinsamer REST-Vertrag (`/api/v1`)

Alle drei Backends (NET Api, NET Minimal.Api, Java) sprechen exakt denselben Vertrag. Das Frontend
nutzt dafür **eine** Strategie (`blueprint-api`).

| Methode | Route | Zweck |
|---|---|---|
| `GET` | `/api/v1/persons` | alle Personen inkl. Adressen |
| `GET` | `/api/v1/persons/{id}` | eine Person |
| `POST` | `/api/v1/persons` | anlegen → `{ id }` |
| `PUT` | `/api/v1/persons/{id}` | ersetzen + Adressen synchronisieren |
| `DELETE` | `/api/v1/persons/{id}` | löschen (Adressen kaskadierend) |
| `PUT` | `/api/v1/addresses/{id}` | einzelne Adresse ändern |
| `GET` | `/api/v2/persons` | Demo für API-Versionierung |

### Person

| Feld | Typ | Pflicht | Validierung / DB |
|---|---|---|---|
| `firstName`, `lastName` | string | ja | nicht leer, max. 200 |
| `birthday` | `yyyy-MM-dd` | **nein** | nicht in der Zukunft (nur Frontend) |
| `gender` | `"Male"` \| `"Female"` | nein | varchar(20) |
| `description` | string | nein | max. 2000 |
| `email` | string | nein | E-Mail-Format, max. 254 |
| `phone` | string | nein | max. 50 |
| `type` | `"Freelancer"` \| `"Employee"` | nein | varchar(20) |
| `addresses` | Address[] | ja (darf leer sein) | – |
| `createdId/createdDate/modifiedId/modifiedDate` | Audit | – | vom Client gesendet |
| `version` | Guid | – | Optimistic Locking |

### Regeln, die alle Backends einhalten

- **Enums als Strings** im JSON mit identischer Schreibweise (`"Male"`, `"Employee"`):
  .NET über `[JsonConverter(typeof(JsonStringEnumConverter<T>))]` direkt am Enum (gilt unabhängig
  von Serializer-Optionen, auch in Tests), Java über `@JsonProperty("Male")` an den
  Enum-Konstanten (`MALE`).
- **Audit-Daten kommen vom Client** (`createdId`/`modifiedId`); das Frontend sendet die
  Keycloak-User-Id (`sub`) des angemeldeten Benutzers.
- **Optimistic Locking:** jede Änderung vergibt eine neue `version`. Ein PUT mit veralteter
  Version → `400` mit `title: "BadRequest - Entity version conflict"`.
- **Adress-Synchronisation über PUT der Person:** `addressId` = Empty-Guid → neu; bekannte Id →
  aktualisieren; fehlende → löschen.
- **Fehler** als ProblemDetails (RFC 9457); Validierungsfehler → `400`.
- **Authentifizierung** über Keycloak (siehe [Sicherheit](#sicherheit-keycloak)): jedes Backend
  prüft das JWT-Access-Token (Signatur, Issuer, Audience `blueprint-api`, Ablauf).
  **Autorisierung nach HTTP-Methode:** `GET` für `reader`, `writer` und `admin`; `POST`/`PUT`
  für `writer` und `admin`; `DELETE` nur `admin`. Ohne/ungültiges Token → `401`, fehlende Rolle → `403`.
- **Rate Limiting** (Fixed Window): NET Minimal.Api und Java 4 Requests / 5 s, Queue 2
  (konfigurierbar); NET Controller-API fest 1 Request / 2 s (`Program.cs`). Das Frontend meldet
  `429`/`503` als Überlastung.
- Keine CORS-Freigabe → das Frontend geht im Dev-Betrieb über den Angular-Proxy.

### Sicherheit (Keycloak)

- **Keycloak 26** läuft im Compose (`blueprint-keycloak`, http://localhost:8180, Admin-Konsole
  `keycloak`/`keycloak`). Der Realm liegt wie in lereg als **vollständiger Keycloak-Export** in
  `setup/keycloak/blueprint-export.json` (inkl. Benutzer, Clients, Mapper und Signaturschlüssel)
  und wird als Datei nach `/opt/keycloak/data/import/` gemountet (`start-dev --import-realm`).
- **Jeder neu erstellte Container liest den Export neu ein:** Keycloak nutzt `KC_DB: dev-file` ohne
  Volume, die Datenbank lebt nur im Container. Ein Neustart (`docker restart`) behält Änderungen,
  `docker compose up -d --force-recreate keycloak` (oder `down`/`up`) startet wieder exakt mit
  dem Export.
- **Konfiguration ändern:** in der Admin-Konsole anpassen und neu exportieren. Die laufende Instanz
  sperrt ihre H2-Datenbank, deshalb in einem separaten Container exportieren, z. B.
  `docker run --rm --entrypoint /bin/bash -v ./setup/keycloak:/out quay.io/keycloak/keycloak:26.7.4 -c "kc.sh import --file /out/blueprint-export.json && kc.sh export --file /out/blueprint-export.json --realm blueprint --users same_file"`
  (bzw. vorher die Änderungen direkt im JSON machen). Die Realm-Id ist fest `blueprint`.
- Weil die Signaturschlüssel im Export stehen, bleiben sie beim Neuerstellen gleich – die APIs
  müssen nicht neu gestartet werden. (Ändern sich die Schlüssel, lädt .NET sie erst nach bis zu
  5 min nach → API neu starten.)
- **Benutzer:** `reader`/`reader` (Rolle `reader`), `writer`/`writer` (Rolle `writer`), `admin`/`admin` (Rolle `admin`).
- **Client** `blueprint-angular`: public, Authorization Code + PKCE (S256), Redirect
  `http://localhost:4200/*`. Zwei Protocol-Mapper: Audience `blueprint-api` und die Realm-Rollen
  als flacher Claim `roles` (die Backends lesen diesen Claim, Name via `preferred_username`).
  Direct Access Grants sind für manuelle Tests aktiv (`curl` mit `grant_type=password`).
- **Issuer vs. Backchannel:** Tokens tragen immer den Issuer `http://localhost:8180/realms/blueprint`
  (`KC_HOSTNAME`). Die API-Container holen die Schlüssel intern über `http://keycloak:8080`
  (`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`; .NET: `Authentication__Schemes__Bearer__MetadataAddress`,
  Java: `SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI`). Lokal gestartete APIs nutzen
  direkt `localhost:8180`.
- **Tests ohne Keycloak:** die Integrationstests signieren eigene Tokens mit einem pro Lauf erzeugten
  RSA-Schlüssel (`TestTokenIssuer`) und laufen durch die **echte** JWT-Validierung
  (.NET: `StaticConfigurationManager` statt Metadaten-Abruf; Java: lokaler JWK-Set-Endpunkt,
  per `DynamicPropertyRegistrar` als `jwk-set-uri` eingetragen). Abgedeckt: fremde Signatur,
  fremder Issuer, fremde Audience, abgelaufenes Token, `reader` liest, `reader` schreibt → 403,
  `writer` schreibt, `writer` löscht → 403.

---

## 2. NET-Blueprint

```
Domain           Entities (Person, Address, EntityBase), Enums (Gender, PersonType), PersonConstraints
Application      eigenes CQRS (ICommandHandler/IQueryHandler, AddCqrs()) – kein MediatR,
                 Request/Response-Records, Mapping-Extensions, IRepository
Infrastructure   BlueprintDbContext (Npgsql), Repository, Migrations, UtcDateTimeOffsetConverter
Web              JWT-Bearer (Keycloak), Policy ApiAccess, ErrorHandling, OpenAPI – geteilt von beiden Hosts
Api              Controller-API (Port 5102)
Minimal.Api      Minimal-API inkl. Rate Limiting, .AddValidation() (Port 5206)
Extensions       Helfer (JSON, DateOnly-Converter)
*.Integration.xUnit.Tests   je API ein Integrationstest-Projekt
```

**Erkenntnisse / Konventionen**

- Längen sind **einmal** in `Domain/Entities/PersonConstraints` definiert und werden sowohl in den
  DataAnnotations der Requests (`[MaxLength(PersonConstraints.EmailMaxLength)]`) als auch im
  `DbContext` (`HasMaxLength`) verwendet.
- Enums werden in der DB als String gespeichert (`HasConversion<string>().HasMaxLength(20)`).
- Positionale Records: optionale Felder als nullable Parameter (`DateOnly? Birthday`), ohne
  `[Required]`.
- `DateTimeOffset` wird beim Schreiben nach UTC normalisiert (PostgreSQL `timestamptz`).
- Migrationen werden beim API-Start angewendet. Neue Migration:
  `dotnet ef migrations add <Name> --project NET.Backend.Blueprint.Infrastructure --startup-project NET.Backend.Blueprint.Infrastructure --output-dir DataAccess/Migrations`
  (Design-Time-Factory vorhanden, kein laufender API-Host nötig).
- Migrationen: `InitialCreate`, `ExtendPersonDetails` (Birthday nullable + Gender, Description,
  Email, Phone, Type).

**Tests:** `dotnet test` – xUnit + Testcontainers (Docker nötig). Controller-Tests vergleichen
gegen eingebettete JSON-Ressourcen (`Resources/*.json`), Minimal-Tests arbeiten mit `TestData`.

> **Stolperfalle:** Findet `dotnet test` „No test is available“, ist meist eine Datei in `bin/`
> beschädigt (z. B. `xunit.runner.visualstudio.testadapter.dll` „Invalid PE signature“). Lösung:
> `bin/` und `obj/` des Testprojekts löschen und neu bauen. Skripte, die rekursiv Dateien
> ersetzen, nie über `bin/`/`obj/` laufen lassen.

---

## 3. Java-Blueprint

```
entities         Person, Address, EntityBase, Gender, PersonType (Längen-Konstanten in Person)
model            Request/Response-Records (Bean Validation: @NotBlank, @Email, @Size)
cqrs             Command-/Query-Handler
mapping          PersonMapper, AddressMapper
dataaccess       Spring-Data-Repositories, Versionsprüfung
controllers      v1 / v2
authentication, authorization, errorhandling, ratelimiting, openapi
resources/db/migration   Flyway: V1__create_schema.sql, V2__extend_person_details.sql
```

- Port 5105, DB `blueprint_java`, `spring.jpa.hibernate.ddl-auto=validate` → Entity und
  Flyway-Schema müssen exakt passen (Tests decken Abweichungen sofort auf).
- Enums: `@Enumerated(EnumType.STRING)`; in der DB steht `MALE`, im JSON `Male`.
  (NET speichert `Male` – unkritisch, da getrennte Datenbanken.)
- Jackson ist case-insensitive für Properties konfiguriert (Test-JSONs nutzen PascalCase).

**Tests:** `./mvnw test` – Integrationstests booten die App auf zufälligem Port mit
Testcontainers-PostgreSQL; ein Szenario pro Testklasse (`PostOkTest`,
`PostWithoutOptionalFieldsOkTest`, `PostInvalidEmailBadRequestTest`, …), JSON-Ressourcen unter
`src/test/resources/...`.

---

## 4. Angular-Blueprint

```
core/            Konfiguration (config.json zur Laufzeit), Backend-Auswahl (localStorage),
                 ApiErrorMapper (ProblemDetails → deutsche Meldung), Notifications, AuditContext
features/persons/
  domain/        Person, PersonProfile, PersonDraft, Gender/PersonType, Adress-Operationen (rein)
  data/          PersonApi-Abstraktion, BlueprintPersonApi (Strategy je BackendKind), Resolver
  state/         PersonsStore (Signals)
  ui/            Liste, Detail, Person-/Adress-Dialog, person-labels.ts, field-limits.ts
i18n/            de.ts/en.ts, LanguageService, provideI18n(), localDate-Pipe, Paginator-Texte
layout/          Backend- und Sprachumschalter (Toolbar)
shared/          AppDialog, ConfirmDialog, LocalizedDateAdapter, Validatoren
```

**Konventionen**

- Standalone Components, OnPush, Signals, `inject()`, neuer Control Flow (`@if`/`@for`).
- **Strategy pro Backend-Vertrag:** `PersonApiFactory` implementieren, in
  `person-api.providers.ts` registrieren, `kind` in `config.json`. Aktuell gibt es nur
  `blueprint-api` (die frühere Strategie für ein Standalone-`NET-Blueprint.Minimal` wurde
  entfernt).
- `PersonProfile` bündelt die Personendaten (ohne Id/Audit/Adressen); `toPersonProfile()` wird
  für Requests und Drafts genutzt → neue Felder nur an einer Stelle ergänzen.
- Optionale Felder sind `null` (nicht `undefined`); leere Textfelder werden beim Speichern zu
  `null`.
- Enum-Anzeige über `ui/person-labels.ts`: `genderLabelKey()` / `personTypeLabelKey()` liefern den
  Übersetzungsschlüssel (leer → `common.notSet`), im Template `| transloco`. Funktionen statt
  Record-Indexierung, weil `let row` in Tabellen `any` ist (sonst TS7053).
- Feldlängen in `ui/field-limits.ts`, identisch zu den Backends.
- **Technische Daten nie anzeigen:** `id` und `version` von Entities erscheinen nirgends in der
  Oberfläche (nur intern für Routing, Requests und Optimistic Locking). Ebenso keine Spalte
  „Anzahl Adressen“ in der Personenliste.

**Dialoge – einheitliches Layout**

- Alle Dialoge werden über `AppDialog` (`shared/dialog/app-dialog.ts`) geöffnet – nie direkt über
  `MatDialog`. Er setzt einheitlich `width: 560px` (Material begrenzt auf `100vw - 32px`) und die
  Panel-Klasse `app-dialog`.
- `styles.scss` definiert für `.app-dialog` die Abstände per `mat.dialog-overrides`
  (Titel, Content, Actions, Buttons rechtsbündig mit 8px Abstand) – keine `align`-Attribute oder
  `!important` in einzelnen Dialogen.
- Formulare nutzen `.form-grid` als **eigenes `<div>` innerhalb** von `mat-dialog-content` – nie
  als Klasse direkt auf `mat-dialog-content`: Material setzt dort zur Laufzeit `display: block`
  und überschreibt das Grid (Folge: Felder unterschiedlich breit, ohne Abstand).
- `.form-grid`: 2 gleich breite Spalten (`minmax(0, 1fr)`), Abstand 16px horizontal, jedes Feld
  füllt seine Zelle. Nur mehrzeilige Felder (Beschreibung) bekommen `.span-2` (volle Breite).
  Unter 480px einspaltig. Adressen zusätzlich `.address-grid`: 4 Spuren, `.wide`-Felder (Strasse, Ort) belegen 3,
  Nr. und PLZ je 1 → Zeilen „Strasse | Nr.“ und „PLZ | Ort“.
- Struktur jedes Dialogs: `h2[mat-dialog-title]` → `mat-dialog-content` → `mat-dialog-actions`
  (Abbrechen links, Primäraktion `mat-flat-button` rechts).

**Mehrsprachigkeit (Deutsch / Englisch)**

- **Transloco** (`@jsverse/transloco`), Sprache zur Laufzeit über den Umschalter DE/EN in der
  Toolbar; Wahl in `localStorage` (`angular-blueprint.language`), Standard Deutsch.
- Übersetzungen als **TypeScript-Objekte** `i18n/de.ts` (Referenz) und `i18n/en.ts`
  (`en: Translations` = Form von `de`) → fehlende oder überzählige Schlüssel brechen den Build.
  Statisch gebündelt über `StaticTranslocoLoader` (kein HTTP), alle Sprachen beim Start geladen.
- `LanguageService` ist die einzige Stelle, die die Sprache wechselt: Transloco, Datums-Locale
  (`DateAdapter.setLocale`) und `<html lang>`.
- **Formate folgen der Sprache:** `de` → `de-CH`, `dd.MM.yyyy`; `en` → `en-GB`, `dd/MM/yyyy`
  (`LANGUAGE_FORMATS`). Anzeige immer über die Pipe `localDate` (`'date'` / `'dateTime'`), nie über
  Angulars `DatePipe` mit festem Format. Eingabe über `LocalizedDateAdapter` (Trennzeichen aus der
  Locale, Tag zuerst).
- Texte in TypeScript (Snackbars, Fehlermeldungen, Bestätigungen) über
  `TranslocoService.translate()` zum Zeitpunkt der Ausgabe. Bestätigungsdialoge liefert
  `PersonDialogs.confirmDeletePerson()` / `confirmDeleteAddress()` fertig übersetzt.
- Filter und Sortierung der Personenliste bekommen sprachabhängige Texte über `PersonTableText`
  (übersetzter Typ, formatiertes Datum).
- Material-Texte: Paginator über `TranslatedPaginatorIntl`.
- Backend-Fehlertexte (ProblemDetails) werden unverändert angezeigt; nur eigene Meldungen sind
  übersetzt.
- Neue Texte: Schlüssel in `de.ts` **und** `en.ts` ergänzen (der Compiler erzwingt es).

**Anmeldung (Keycloak)**

- `keycloak-angular` 21 + `keycloak-js` 26. `main.ts` lädt `config.json` **vor** dem Bootstrap
  (`fetchAppConfig()`), weil `provideKeycloak()` Realm und Client beim Registrieren braucht;
  `createAppConfig(config)` baut daraus die Provider.
- `provideAuth()` (`core/auth`): `onLoad: 'login-required'` (ohne Login startet die App nicht),
  PKCE S256, automatische Token-Erneuerung, Logout nach 30 min Inaktivität.
  `includeBearerTokenInterceptor` hängt das Token **nur** an Aufrufe unter `/backend/`.
- `AuthSession` kapselt Keycloak (Benutzername, `isAdmin`, `userId` = `sub`, `logout`) und liest
  bei jedem Keycloak-Event neu. Komponenten und Store hängen nur von `AuthSession` ab.
- `PersonsStore.canWrite` = Backend schreibbar **und** Rolle `admin`; `readOnlyHint` liefert den
  passenden Tooltip-Schlüssel. Toolbar zeigt Benutzer + Abmelden (`UserMenu`). `401`/`403` werden
  als eigene Meldungen übersetzt.

**Tests:** `npm test` (Jest, jsdom). Getestet werden Domain-Logik, API-Strategien
(`HttpTestingController`), Store, Tabellen-Filter/-Sortierung, Dialoge (Feldanzahl, Vorbelegung,
einheitliche Breite) und die Mehrsprachigkeit (Texte und Datumsformate in DE/EN). Specs mit Texten
importieren `translocoTesting()` (`i18n/testing`) – echte Übersetzungen, vorgeladen.

> **Stolperfalle:** Transloco liefert `@jsverse/utils` als ESM-`.js`. `jest.config.js` muss
> `@jsverse/` in `transformIgnorePatterns` freigeben, sonst „Must use import to load ES Module“.
> Dasselbe gilt für `keycloak-js/`.

---

## 5. Betrieb

| Dienst | Port | Proxy-Pfad (Angular) |
|---|---|---|
| PostgreSQL | 5432 | – (DBs `blueprint_net`, `blueprint_java`) |
| NET Controller-API | 5102 | `/backend/net-api` |
| NET Minimal-API | 5206 | `/backend/net-minimal-api` |
| Java-API | 5105 | `/backend/java` |
| Keycloak | 8180 | – (Realm `blueprint`, Admin-Konsole `keycloak`/`keycloak`) |
| Angular Dev-Server | 4200 | – |

- in `Init-Blueprint`: `docker compose up -d` – PostgreSQL, Keycloak + alle APIs (APIs starten erst, wenn Keycloak
  gesund ist).
- `./build-images.sh [-f]` – publish/package, Images bauen, NET-Migration anwenden, Compose starten
  (podman bevorzugt, sonst docker).
- Swagger: `http://localhost:5102/swagger`, `:5206/swagger`, `:5105/swagger`.

---

## 6. Arbeitsweise

- **Test-driven:** zuerst Test bzw. JSON-Ressource anpassen (rot), dann implementieren (grün).
  Integrationstests bevorzugt, Unit-Tests für isolierte Logik.
- **Vertragsänderungen immer in allen drei Projekten** umsetzen: Entity + Migration (EF und
  Flyway), Requests/Response, Mapping, Update-Handler, Test-Ressourcen beider Backends,
  Angular-DTO + Domain + UI.
- Vor Abschluss: `dotnet test`, `./mvnw test`, `npm test`, `ng build`.

### Änderungshistorie (Auszug)

- Person um `gender`, `description`, `email`, `phone`, `type` erweitert; `birthday` optional –
  in NET (Migration `ExtendPersonDetails`), Java (`V2__extend_person_details.sql`) und Angular
  (Dialog, Liste mit Spalte „Typ“ und erweiterter Suche, Detailkarte).
- Angular-Strategie für Standalone-`NET-Blueprint.Minimal` entfernt (`BackendKind` nur noch
  `blueprint-api`).
- Einheitliches Dialog-Layout über `AppDialog` + `.app-dialog`-Styles.
- Keycloak statt Auth-Stub: Realm-Import, JWT-Validierung in allen drei Backends (`standard`
  liest, `admin` schreibt), Login/Logout in Angular; `auditUserId` aus `config.json` entfällt
  (Audit-Id = Keycloak-`sub`).
