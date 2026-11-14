# Server Stack

The whole stack is one Docker Compose project. This is the real layout Edict is developed against, with secrets and host addresses replaced by placeholders.

## Directory layout

```
mdm/
├── compose.yml              # the core services
├── compose.override.yml     # the enrollments sidecar
├── .env                     # secrets + the admin bind address (mode 600)
├── build/
│   └── Dockerfile           # builds any Go service from its git tag
├── initdb/
│   ├── 00-databases.sql     # creates the 4 databases + app user
│   ├── 10-nanomdm.sql       # NanoMDM schema (fetched from upstream)
│   └── 20-kmfddm.sql        # KMFDDM schema (fetched from upstream)
├── depot/                   # SCEP CA + issued certs (created on first run)
└── enrollments-api/
    ├── Dockerfile
    └── app.py               # the read-only enrollments listing sidecar
```

## The build Dockerfile

The upstream projects' own Dockerfiles only copy a prebuilt binary, so the stack compiles each one from its pinned git tag. This single Dockerfile builds any of them — `compose.yml` passes the repo, tag, and command path as build args.

`build/Dockerfile`:

```dockerfile
# Build any micromdm/jessepeterson Go service from its pinned git tag.
FROM golang:1.22-alpine AS build
ARG REPO
ARG TAG
ARG CMD
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch "$TAG" "$REPO" . \
 && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/app "$CMD"

FROM alpine:3
RUN apk add --no-cache ca-certificates curl
COPY --from=build /out/app /usr/bin/app
ENTRYPOINT ["/usr/bin/app"]
```

## compose.yml

Note the port bindings: SCEP and NanoMDM publish on all interfaces (the reverse proxy fronts them for device traffic), while KMFDDM binds to **`${ADMIN_BIND}`** — your private interface only. Set `ADMIN_BIND` in `.env` (see below).

```yaml
name: mdm

x-build: &svc-build
  context: .
  dockerfile: build/Dockerfile

services:
  mdm-db:
    image: mysql:8.0
    container_name: mdm-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - mdm-db-data:/var/lib/mysql
      - ./initdb:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 18
      start_period: 30s
    networks: [mdm]

  scep:
    build:
      <<: *svc-build
      args:
        REPO: https://github.com/micromdm/scep.git
        TAG: v2.3.0
        CMD: ./cmd/scepserver
    image: mdm/scep:v2.3.0
    container_name: mdm-scep
    restart: unless-stopped
    command: ["-depot","/depot","-port","8080","-challenge","${SCEP_CHALLENGE}","-allowrenew","0"]
    volumes:
      - ./depot:/depot
    ports:
      - "9094:8080"          # fronted by the reverse proxy at /scep
    networks: [mdm]

  nanomdm:
    build:
      <<: *svc-build
      args:
        REPO: https://github.com/micromdm/nanomdm.git
        TAG: v0.7.0
        CMD: ./cmd/nanomdm
    image: mdm/nanomdm:v0.7.0
    container_name: mdm-nanomdm
    restart: unless-stopped
    command:
      - "-ca"
      - "/depot/ca.pem"
      - "-api"
      - "${NANOMDM_API_KEY}"
      - "-storage"
      - "mysql"
      - "-storage-dsn"
      - "mdm:${MYSQL_APP_PW}@tcp(mdm-db:3306)/nanomdm"
      - "-dm"
      - "http://kmfddm:9002/"
      - "-listen"
      - ":9000"
    volumes:
      - ./depot:/depot:ro
    depends_on:
      mdm-db:
        condition: service_healthy
    ports:
      - "9090:9000"          # fronted by the reverse proxy at /mdm
    networks: [mdm]

  kmfddm:
    build:
      <<: *svc-build
      args:
        REPO: https://github.com/jessepeterson/kmfddm.git
        TAG: v0.7.0
        CMD: ./cmd/kmfddm
    image: mdm/kmfddm:v0.7.0
    container_name: mdm-kmfddm
    restart: unless-stopped
    command:
      - "-api"
      - "${KMFDDM_API_KEY}"
      - "-enqueue"
      - "http://nanomdm:9000/v1/enqueue/"
      - "-enqueue-key"
      - "${NANOMDM_API_KEY}"
      - "-storage"
      - "mysql"
      - "-storage-dsn"
      - "mdm:${MYSQL_APP_PW}@tcp(mdm-db:3306)/kmfddm"
      - "-listen"
      - ":9002"
    depends_on:
      mdm-db:
        condition: service_healthy
    ports:
      - "${ADMIN_BIND}:9093:9002"   # admin-only — private interface
    networks: [mdm]

networks:
  mdm:
    name: mdm

volumes:
  mdm-db-data:
    name: mdm-db-data
```

KMFDDM is wired to NanoMDM's enqueue endpoint (`-enqueue` + `-enqueue-key`) so that whenever you change a declaration or a device's set membership, KMFDDM tells NanoMDM to send the `DeclarativeManagement` command automatically. NanoMDM is pointed back at KMFDDM with `-dm` so declarative checkins route there.

## compose.override.yml — enrollments sidecar

NanoMDM (v0.7.0) has **no admin endpoint to list enrollments** — they live in its database. Edict ships a tiny read-only Python sidecar that reads NanoMDM's MySQL and returns the enrollment list (joined with the logged-in user), plus a guarded purge for unenrolled devices. It authenticates with the **same** API key as NanoMDM.

```yaml
services:
  enrollments:
    build: ./enrollments-api
    image: mdm/enrollments-api:v1
    container_name: mdm-enrollments
    restart: unless-stopped
    environment:
      DB_HOST: mdm-db
      DB_USER: mdm
      DB_PASS: ${MYSQL_APP_PW}
      DB_NAME: nanomdm
      API_KEY: ${NANOMDM_API_KEY}
    depends_on:
      mdm-db:
        condition: service_healthy
    ports:
      - "${ADMIN_BIND}:9095:8080"   # admin-only — private interface
    networks: [mdm]
```

The sidecar source is [`server/mdm/enrollments-api/`](../server/mdm/enrollments-api/) in this repo: `app.py` plus a five-line `python:3.12-alpine` + `pymysql cryptography` Dockerfile. Copy that folder into your stack as `enrollments-api/`.

## Database init

MySQL runs every `.sql` in `initdb/` **once**, on first start against an empty data volume.

`initdb/00-databases.sql` creates the databases and the shared app user. **The password in the `IDENTIFIED BY` clause must equal `MYSQL_APP_PW` in your `.env`** — SQL init files can't read environment variables, so it's written literally here. Use your real value:

```sql
CREATE DATABASE IF NOT EXISTS nanomdm CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS kmfddm  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS nanodep CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS nanocmd CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'mdm'@'%' IDENTIFIED BY 'PUT_YOUR_MYSQL_APP_PW_HERE';
GRANT ALL PRIVILEGES ON nanomdm.* TO 'mdm'@'%';
GRANT ALL PRIVILEGES ON kmfddm.*  TO 'mdm'@'%';
GRANT ALL PRIVILEGES ON nanodep.* TO 'mdm'@'%';
GRANT ALL PRIVILEGES ON nanocmd.* TO 'mdm'@'%';
FLUSH PRIVILEGES;
```

The per-service schemas are maintained upstream — don't hand-write them. Fetch each project's `schema.sql` at the matching tag and save it into `initdb/` so it loads after `00-`:

- `10-nanomdm.sql` ← NanoMDM's [`storage/mysql/schema.sql`](https://github.com/micromdm/nanomdm/blob/main/storage/mysql/schema.sql)
- `20-kmfddm.sql` ← KMFDDM's [`storage/mysql/schema.sql`](https://github.com/jessepeterson/kmfddm/blob/main/storage/mysql/schema.sql)
- (If you add NanoDEP / nanocmd later, drop their schemas in too — the databases already exist.)

> **Footgun:** init scripts only run on a **fresh** data volume. If you change `00-databases.sql` after the first start, nothing happens — MySQL already initialized. To re-init, stop the stack and remove the `mdm-db-data` volume (this destroys all enrollments — back up first).

## .env

Mode `600`. Generate each key with something like `openssl rand -hex 24`. Mirror the file into your secret manager.

```dotenv
# Bind address for admin-only services (KMFDDM, enrollments sidecar).
# Use your private/tailnet interface IP, or 127.0.0.1 if the app runs on this host
# or you reverse-proxy the admin APIs locally. Do NOT use 0.0.0.0.
ADMIN_BIND=<tailnet-ip>

MYSQL_ROOT_PASSWORD=<random>
MYSQL_APP_PW=<random>          # must match initdb/00-databases.sql
NANOMDM_API_KEY=<random>
KMFDDM_API_KEY=<random>
SCEP_CHALLENGE=<random>

# Only if you add the optional services later:
NANODEP_API_KEY=<random>
NANOCMD_API_KEY=<random>
```

## Bring it up

```
docker compose up -d --build
```

First start compiles the Go services (a few minutes), initializes MySQL, and generates the SCEP CA in `./depot`. Watch it with `docker compose logs -f`.

Verify each admin API answers (from a host on your private network, using the matching key):

```
curl -u nanomdm:$NANOMDM_API_KEY http://<admin-bind>:9090/version
curl -u kmfddm:$KMFDDM_API_KEY   http://<admin-bind>:9093/version
curl -u nanomdm:$NANOMDM_API_KEY http://<admin-bind>:9095/v1/enrollments
```

A `200` from all three means the stack is healthy. Next: **[Networking & Remote Access](Networking-and-Remote-Access.md)** to expose the device-facing paths, then **[Connecting Edict](Connecting-Edict.md)**.
