# Deployment

Deploying the SDI Investment Property Marketplace, with Portainer as the
primary path.

**Status of these instructions.** Both compose files and the three Dockerfiles
are validated (`docker compose config` passes, the worker appears only under
its profile, the stack refuses to start without credentials, the database port
is unpublished). They have **not been executed** — the environment this was
built in cannot run Docker, as image pulls are blocked there. Treat the first
deployment as a test of these instructions as much as of the software, and
report anything that does not match.

**Two ways in.** Deploy from published images (§3, recommended) or build on the
host from source (§4). The images are the same either way.

---

## 1. Before you start

| Requirement | Notes |
|---|---|
| Docker Engine 20.10+ | On the host Portainer manages |
| Portainer CE 2.19+ | Business Edition not required |
| ~2 GB disk, 1 GB RAM | Images plus the database |
| Outbound HTTPS from the host | To pull images from `ghcr.io` |

Nothing else. The images are public, so no registry login is needed to pull
them.

If you build on the host instead (§4) you additionally want a **standalone
Docker** environment rather than Swarm — see §6. Deploying from published
images works on either.

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

## 3. Deploy from published images (recommended)

Every push to `main` publishes three images to GitHub Container Registry, and
every `v*` tag publishes a versioned set:

| Image | Contains |
|---|---|
| `ghcr.io/neilgreene/property-management/db` | PostgreSQL 16 with the schema baked in |
| `ghcr.io/neilgreene/property-management/web` | The demo interface |
| `ghcr.io/neilgreene/property-management/worker` | The GoHighLevel integration |

Nothing is built on your host, so this also works on Swarm.

1. In Portainer, **Stacks → Add stack**, name it `sdi`.
2. Build method: **Web editor**. Paste the contents of
   `docker-compose.release.yml` from the repository.
3. Under **Environment variables**, add:

   | Name | Value | Required |
   |---|---|---|
   | `POSTGRES_PASSWORD` | long and random | **yes** |
   | `SDI_APP_PASSWORD` | long and random | **yes** |
   | `SDI_VERSION` | `latest`, or a release tag such as `1.0.0` | no |
   | `WEB_PORT` | `3000` | no |

   The two passwords have no defaults on purpose. A stack that quietly starts
   with a guessable database password is worse than one that refuses to start.

4. **Deploy the stack.**

Then open `http://<host>:3000`.

Pin `SDI_VERSION` to a release tag for anything real. `latest` moves whenever
`main` does, so a redeploy months later would not give you back what you tested.

### Where the role passwords go

The database image ships with **no credentials at all**. On first start it
reads `SDI_APP_PASSWORD` and `SDI_INTEGRATION_PASSWORD` from the environment
and grants those roles login. A role given no password stays `NOLOGIN`, which
fails visibly at connect time rather than silently allowing access.

This is why there is no demo-password flag on the published images: an image
built without credentials cannot serve the web tier, and one built with them
would ship the same password to every deployment. Runtime is the only sensible
place for that decision.

### Checking it worked

- Portainer → Stacks → `sdi`: three services, `db` healthy.
- The demo page loads and the persona switcher changes what is visible.
- Pick **Not signed in** — the street address column is empty. Pick **Ruth
  Okonkwo** — it is populated. That single difference is the whole security
  model, so it is the fastest end-to-end check there is.
- `db` logs should show the schema files running in order on first start.

---

## 4. Build on the host instead

Use this when you want to deploy a branch that has not been published, or you
would rather not depend on the registry.

1. **Stacks → Add stack**, name it `sdi`.
2. Build method: **Repository**.
   - Repository URL: `https://github.com/neilgreene/property-management`
   - Reference: `refs/heads/main`
   - Compose path: `docker-compose.yml` — note: **not** the `.release.yml` one
3. Set the same environment variables as §3, minus `SDI_VERSION`.
4. Deploy. The first build takes a few minutes.

This path needs a **standalone Docker** environment. Swarm does not build.

Locally the same file works directly:

```bash
cp .env.example .env      # then set the two passwords
docker compose up --build
```

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

Two of those three are already solved by deploying from published images (§3),
which is why that is the recommended path: there is nothing to build, so
`build` being ignored costs nothing.

The remaining two need edits to `docker-compose.release.yml` before
`docker stack deploy` will behave:

- Drop the `profiles:` line from `worker` — and simply omit the service
  entirely if you do not want it running.
- Replace the `depends_on` condition with a restart policy. `web` will
  crash-loop until the database answers, then settle:

  ```yaml
  deploy:
    restart_policy:
      condition: on-failure
      delay: 5s
  ```

**Recommendation: use a standalone Docker environment anyway.** This is one
database holding local state plus two small stateless services. Swarm adds
orchestration it does not need, and costs you the health-gated startup ordering
that makes a first deploy clean. Published images remove the only real argument
for Swarm here, which was avoiding a build on the host.

---

## 7. Things to change before it reaches a network

The defaults are tuned for a laptop. Four changes before anything else can
reach it:

1. **PostgreSQL is not published, and should stay that way.** Neither compose
   file has a `ports:` entry for `db`. If you need to inspect it, bind to
   loopback (`127.0.0.1:5432:5432`) and tunnel over SSH — never to `0.0.0.0`.
2. **Set real role passwords.** `SDI_APP_PASSWORD` and, if you run the worker,
   `SDI_INTEGRATION_PASSWORD`. Never reuse the demo values from
   `.env.example`, which are in a public repository.
3. **Never load `worker/test/bootstrap.sql`.** It creates `sdi_test_admin`,
   which carries `BYPASSRLS` and can read past every security policy in the
   system. It is a test fixture, not a deployment script.
4. **Put TLS in front of both web and worker.** Neither terminates TLS itself
   and neither authenticates anything today — there is no login system yet, so
   anything that can reach port 3000 can select any persona, including an
   administrator. Until authentication is built (phase P1), this belongs on a
   private network or behind an authenticating proxy, not on the open internet.

---

## 7a. The media store, and a Portainer trap

`SDI_MEDIA_DIR` is the host path holding uploaded photographs. **Set it to an
absolute path**, in Portainer's environment panel:

```
SDI_MEDIA_DIR=/mnt/cephfs/sdi-media
```

Both compose files default it to `./media` when it is unset, and that default
is wrong for either way of running this — differently in each case, which is
why it is worth stating twice.

**Under Portainer** a relative bind mount is the failure described in §2: a Git
stack on Portainer CE cannot populate one, because relative-path volumes are a
Business Edition feature. The symptom is not an error. It is photographs that
upload successfully and are not there afterwards.

**Under plain `docker compose`** a relative path does resolve — against the
project directory, which is the directory of the FIRST `-f` file. So it works,
and quietly puts the media store inside your checkout rather than on the volume
you mounted for it.

The path is **per-host** and expected to differ between machines. The container
always sees `/srv/media` whatever the host path is, and the database stores
paths relative to that, so there is nothing to keep in step between nodes and
no reason to symlink one to match another.

It must be writable by uid 1000 — the web container runs as `node`.

**On a separate filesystem — CephFS, NFS, a mounted volume — set
`SDI_MEDIA_SENTINEL` too.** It names a file that exists only on the mounted
store, and the web tier refuses to start when it is missing:

```
SDI_MEDIA_SENTINEL=.sdi-media-volume
```

Create it once, while the mount is definitely up:

```bash
touch /mnt/cephfs/sdi-media/.sdi-media-volume
chown 1000:1000 /mnt/cephfs/sdi-media/.sdi-media-volume
```

Without it, a store that fails to mount is invisible: the path still exists as
an empty directory underneath the mount point, Docker binds that without
complaint, uploads land on the wrong disk, and every existing photograph is
missing from the application while the database still lists all of them. It
looks like data loss and nothing about it points at a mount. A network
filesystem has more ways to be absent than a local disk, which is why this
matters more here than on a single-machine deployment.

Leave `SDI_MEDIA_SENTINEL` empty where nothing is mounted; start-up then says
the check is off rather than saying nothing.

---

## 8. Updating

**From published images:** bump `SDI_VERSION`, or if you are tracking
`latest`, Portainer → Stacks → `sdi` → **Update the stack** with *re-pull
image* ticked.

**From a Git build:** Portainer → Stacks → `sdi` → **Pull and redeploy**, with
*re-pull image* ticked so the images rebuild.

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
| Demo loads but every persona shows no properties | The database initialised empty. Almost always a bind-mount deployment on Portainer CE — use §3 |
| `web` cannot authenticate to the database | `SDI_APP_PASSWORD` was not set at **first** start. The roles are given credentials only when the data directory is initialised, so set it and recreate the volume, or set the password by hand with `ALTER ROLE` |
| `web` restarts repeatedly | It cannot reach `db`. In Swarm, this is the dropped `depends_on` condition (§6) |
| Address visible when signed out | Stop and raise it immediately. That is the one thing the system exists to prevent, and it should be impossible — see §7 of the System Documentation |
| `worker` exits at once | Missing `GHL_TOKEN` or `GHL_LOCATION_ID`. It refuses to start rather than fail later on the first call |
| Schema changes have no effect | The volume already has data; init scripts only run on an empty one (§8) |
