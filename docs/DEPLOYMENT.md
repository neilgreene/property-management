# Deployment

Deploying the SDI Investment Property Marketplace, with Portainer as the
primary path.

**Status of these instructions.** The compose file and the three Dockerfiles
are validated (`docker compose config` passes, the worker appears only under
its profile, the stack refuses to start without a database password). They have
**not been executed** — the environment this was built in cannot run Docker, as
image pulls are blocked there. Treat the first deployment as a test of these
instructions as much as of the software, and report anything that does not
match.

---

## 1. Before you start

| Requirement | Notes |
|---|---|
| Docker Engine 20.10+ | On the host Portainer manages |
| Portainer CE 2.19+ | Business Edition not required |
| A **standalone Docker** environment in Portainer | Not Swarm. See §6 for why, and for the Swarm path |
| ~2 GB disk, 1 GB RAM | Images plus the database |
| Outbound HTTPS from the host | To pull base images and one npm package at build time |

Nothing else. No registry account, no external services.

---

## 2. What gets deployed

| Service | Image built from | Port | Started by default |
|---|---|---|---|
| `db` | `docker/db.Dockerfile` — PostgreSQL 16 with the schema baked in | none | yes |
| `web` | `web/Dockerfile` — Node 22, the demo interface | 3000 | yes |
| `worker` | `worker/Dockerfile` — Node 22, the GoHighLevel integration | 3001 | **no** — see §5 |

Every service is **built**, not bind-mounted. This matters specifically for
Portainer: a Git stack on Portainer CE cannot populate a relative bind mount
(relative-path volumes are a Business Edition feature), so a `./sql` mount
resolves to an empty directory and PostgreSQL initialises **with no schema at
all** — silently, because an empty init directory is perfectly legal. You would
get a running stack and an empty database. Building the schema into the image
removes that failure mode entirely.

---

## 3. Deploy from Git (recommended)

1. In Portainer, choose your **standalone Docker** environment.
2. **Stacks → Add stack**.
3. Name it `sdi`.
4. Build method: **Repository**.
   - Repository URL: `https://github.com/neilgreene/property-management`
   - Reference: `refs/heads/main`
   - Compose path: `docker-compose.yml`
5. Under **Environment variables**, add:

   | Name | Value |
   |---|---|
   | `POSTGRES_PASSWORD` | something long and random |

   That one is **required** — the stack is written to refuse to start without
   it rather than fall back to a guessable default.

   Optionally also:

   | Name | Value | Effect |
   |---|---|---|
   | `WEB_PORT` | `3000` | Host port for the demo |
   | `DEMO_LOGINS` | `1` | Bakes the demo role passwords in. Set `0` for anything real |

6. **Deploy the stack.**

First deploy builds three images and takes a few minutes. Then open
`http://<host>:3000`.

### Checking it worked

- Portainer → Stacks → `sdi`: three services, `db` healthy.
- The demo page loads and the persona switcher changes what is visible.
- Pick **Not signed in** — the street address column is empty. Pick **Ruth
  Okonkwo** — it is populated. That single difference is the whole security
  model, so it is the fastest end-to-end check there is.
- `db` logs should show the schema files running in order on first start.

---

## 4. Deploy from the Web editor

If you would rather not point Portainer at GitHub:

1. Clone the repository onto the Docker host: `git clone … /opt/sdi`
2. **Stacks → Add stack → Web editor**, paste the contents of
   `docker-compose.yml`.
3. Set the same environment variables.
4. Deploy.

The build contexts (`.`, `./web`, `./worker`) resolve relative to where
Portainer runs the build. If the build cannot find them, use §3 instead — the
Git method has no such ambiguity.

---

## 5. Enabling the GoHighLevel worker

The worker sits behind a compose profile because it needs real credentials and
does nothing useful without them. To turn it on, add these to the stack
environment and redeploy:

| Name | Value |
|---|---|
| `COMPOSE_PROFILES` | `worker` |
| `GHL_TOKEN` | Private Integration Token (GoHighLevel → Settings → Private Integrations) |
| `GHL_LOCATION_ID` | The sub-account id |
| `GHL_WEBHOOK_PUBLIC_KEY` | GoHighLevel's published webhook key, PEM format |

The token grants access to an **entire GoHighLevel sub-account** — contacts,
invoices, transactions. Put it in Portainer's environment panel, never in a
file in the repository, and never anywhere a browser can reach.

Check it with `http://<host>:3001/healthz`, which reports queue depth. It
returns JSON and needs no authentication, so do not publish port 3001 beyond
your own network.

For webhooks to arrive, GoHighLevel needs to reach port 3001 over HTTPS from
the internet. Put a reverse proxy in front of it; do not publish it directly.

---

## 6. Swarm

If your Portainer environment is a Swarm cluster (for example two nodes named
`docker01` / `docker02`), this compose file will not behave as written.
`docker stack deploy` silently ignores several things it uses:

| Ignored in Swarm | Consequence |
|---|---|
| `depends_on` with `condition: service_healthy` | `web` starts before the database is ready and crash-loops until it is |
| `profiles` | The worker starts whether you wanted it or not |
| `build` | Swarm does not build; it only pulls |

The fix is to build the images once and push them to a registry, then deploy a
compose file that references them by tag instead of building:

```bash
docker build -t <registry>/sdi-db:1.0     -f docker/db.Dockerfile .
docker build -t <registry>/sdi-web:1.0    ./web
docker build -t <registry>/sdi-worker:1.0 ./worker
docker push <registry>/sdi-db:1.0
docker push <registry>/sdi-web:1.0
docker push <registry>/sdi-worker:1.0
```

Then replace each `build:` block with `image: <registry>/…:1.0`, drop the
`profiles:` line, and replace the `depends_on` condition with a
`restart_policy` — `web` will retry until the database answers.

**Recommendation: use a standalone Docker environment for this.** The stack is
one database with local state and two small stateless services. Swarm adds
orchestration this does not need, and costs you the health-gated startup
ordering that makes a first deploy clean.

---

## 7. Things to change before it reaches a network

The defaults are tuned for a laptop. Four changes before anything else can
reach it:

1. **PostgreSQL is not published, and should stay that way.** The compose file
   deliberately has no `ports:` entry for `db`. If you need to inspect it, bind
   to loopback (`127.0.0.1:5432:5432`) and tunnel over SSH — never to `0.0.0.0`.
2. **Set `DEMO_LOGINS=0`.** `sql/99_local_logins.sql` gives the application
   roles passwords that are published in a public repository. With it off, they
   take credentials from the deployment instead.
3. **Never load `worker/test/bootstrap.sql`.** It creates `sdi_test_admin`,
   which carries `BYPASSRLS` and can read past every security policy in the
   system. It is a test fixture, not a deployment script.
4. **Put TLS in front of both web and worker.** Neither terminates TLS itself
   and neither authenticates anything today — there is no login system yet, so
   anything that can reach port 3000 can select any persona, including an
   administrator. Until authentication is built (phase P1), this belongs on a
   private network or behind an authenticating proxy, not on the open internet.

---

## 8. Updating

**From Git:** Portainer → Stacks → `sdi` → **Pull and redeploy**. Tick
*re-pull image* so the images rebuild.

**Schema changes** need a rebuild, because the schema is baked into the image.
Note that PostgreSQL only runs the init scripts **when the data directory is
empty** — on an existing volume, a rebuilt image changes nothing. To reset the
database in a demo environment, remove the stack *and its volume*:

```bash
docker compose down -v
```

In anything holding data you care about, apply changes as migrations against
the running database instead. There is no migration runner in the project yet;
that arrives with phase P11.

---

## 9. Backups

Set this up before there is anything worth backing up — that is the only time
it is easy.

```bash
docker compose exec -T db pg_dump -U postgres sdi | gzip > sdi-$(date +%F).sql.gz
```

Restore into an empty database:

```bash
gunzip -c sdi-2026-08-31.sql.gz | docker compose exec -T db psql -U postgres -d sdi
```

Rehearse the restore at least once. An untested backup is a belief, not a
backup.

---

## 10. Troubleshooting

| Symptom | Cause |
|---|---|
| Stack will not deploy, complains about `POSTGRES_PASSWORD` | It is required and has no default. Add it to the stack environment |
| Demo loads but every persona shows no properties | The database initialised empty. Almost always a bind-mount deployment on Portainer CE — use the built images in §3 |
| `web` restarts repeatedly | It cannot reach `db`. In Swarm, this is the dropped `depends_on` condition (§6) |
| Address visible when signed out | Stop and raise it immediately. That is the one thing the system exists to prevent, and it should be impossible — see §7 of the System Documentation |
| `worker` exits at once | Missing `GHL_TOKEN` or `GHL_LOCATION_ID`. It refuses to start rather than fail later on the first call |
| Schema changes have no effect | The volume already has data; init scripts only run on an empty one (§8) |
