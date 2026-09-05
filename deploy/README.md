# Internet-facing deployment

Two ways to run this with a public address. Both work; they differ in
whether the traffic is encrypted.

The choice is not cosmetic for one reason that has nothing to do with
security: **session cookies are set `Secure`**, so over plain HTTP the
browser never sends them back and sign-in silently fails. Whichever path
you take, take it deliberately.

---

## A. HTTPS, with a real certificate  (recommended)

Needs a hostname. Let's Encrypt will not issue for a bare IP, so if you
have no domain, use a wildcard DNS service that maps the IP into a real
name — `172-235-60-70.sslip.io` resolves to `172.235.60.70` with nothing
to register and no DNS to configure, and a certificate can be issued for
it because it is a real name.

```bash
cd /opt/sdi
mkdir -p deploy
BR=claude/postgres-web-access-jznei0
RAW=https://raw.githubusercontent.com/neilgreene/property-management/$BR/deploy
curl -fsSL -H 'Cache-Control: no-cache' -o deploy/Caddyfile              "$RAW/Caddyfile?$(date +%s)"
curl -fsSL -H 'Cache-Control: no-cache' -o deploy/docker-compose.public.yml "$RAW/docker-compose.public.yml?$(date +%s)"

# VERIFY BEFORE STARTING. raw.githubusercontent.com caches for around
# five minutes, so a fetch made soon after a push can return the OLD
# file with no error and no warning. The cache-buster above usually
# defeats it; this check is what proves it did.
grep Caddyfile deploy/docker-compose.public.yml   # must say ./deploy/Caddyfile
file deploy/Caddyfile                             # must say ASCII text

# The hostname and the contact address are already set for
# 172.235.60.70. Change the hostname only when a domain replaces it.

# Both -f files, every time. Run from /opt/sdi -- the paths inside the
# overlay resolve against the FIRST file's directory, not their own.
docker compose -f docker-compose.yml \
               -f deploy/docker-compose.public.yml up -d
```

If `grep` shows `./Caddyfile` without the `deploy/`, the fetch was stale.
Do not re-fetch -- patch it, which is faster and certain:

```bash
rmdir Caddyfile 2>/dev/null   # Docker creates a DIRECTORY at a missing
                              # bind source, and a directory will not
                              # mount over a file. That is the whole
                              # cause of `mount ... not a directory`.
sed -i 's|\./Caddyfile:/etc/caddy/Caddyfile|./deploy/Caddyfile:/etc/caddy/Caddyfile|' \
  deploy/docker-compose.public.yml
```

Watch the proxy until it says so:

```bash
docker compose -f docker-compose.yml -f deploy/docker-compose.public.yml logs -f proxy
```

`"msg":"certificate obtained successfully"` is the line that means it
worked. Three log lines look like failures and are not:

- `server is listening only on the HTTP port, so no automatic HTTPS` --
  the `:80` catch-all that answers 404 to anything addressing the bare
  IP. Deliberate.
- `failed to sufficiently increase receive buffer size` -- a kernel UDP
  buffer hint. HTTP/3 works regardless.
- `open /data/caddy/acme/.../neilgreene0102@gmail.com.json: no such
  file` -- there is no ACME account yet, on the run that creates one.

Ports 80 and 443 must be open to the internet: Let's Encrypt validates
over 80 and the site serves on 443. The web container stops publishing a
port of its own — it is reachable only through the proxy.

Add `TRUST_PROXY=1` to `.env` so the sign-in log records the visitor's
address rather than the proxy's. It is opt-in on purpose:
`X-Forwarded-For` is a request header anyone can send, and believing it
on a directly-exposed server would let a caller claim any address they
like.

---

## B. Plain HTTP

Simpler, and everything crosses the wire in the clear — passwords,
session cookies, whatever is on screen.

```bash
cd /opt/sdi
echo 'COOKIE_INSECURE=1' >> .env
docker compose up -d
```

`COOKIE_INSECURE=1` drops the `Secure` flag so sign-in works over HTTP.
It exists for exactly this case and is the only reason the site is usable
without TLS. Take it back out the moment there is a certificate.

---

## Either way

**Media lives on a host path, and the path is per-host.** Set
`SDI_MEDIA_DIR` in `.env` — `/opt/sdi/media` on the OS disk, or a separate
filesystem such as `/mnt/sdi-media`. It is *expected* to differ between
machines and there is nothing to keep in step: the container always sees
`/srv/media` whatever the host path is, and the database stores paths
relative to that. Moving the store is this one line plus moving the files.
**Do not symlink one host's path to match another's** — it makes two
machines look identical while adding a resolution step that can break, and
the variable exists precisely so they need not match.

A host directory rather than a named volume on purpose: `docker compose
down -v` destroys named volumes, and a schema change needs `down -v`.
Photographs must not die with a database rebuild.

Two things a separate filesystem needs:

```bash
chown -R 1000:1000 /mnt/sdi-media   # the web container runs as `node`
grep sdi-media /etc/fstab           # must be there
```

**The fstab line is not optional** — but on its own it does not close the
hole, because it will carry `nofail`, and it should. Without `nofail` a
volume that fails to attach makes the machine fail to boot and takes SSH
with it, which is far worse than missing photographs. With it, an absent
volume simply stops being an error: the host boots, the mount point stays
an empty directory on the OS disk, Docker bind-mounts that without
complaint, and there is no failed container and no warning anywhere.
Uploads land on the wrong disk and every existing photograph is missing
from the application while the database still lists all of them. It looks
like data loss. Nothing about it points at a mount.

So keep `nofail`, and close it a layer up — with a file that exists only
on the volume:

```bash
touch /mnt/sdi-media/.sdi-media-volume
chown 1000:1000 /mnt/sdi-media/.sdi-media-volume
echo 'SDI_MEDIA_SENTINEL=.sdi-media-volume' >> /opt/sdi/.env
```

The web tier now refuses to start when that file is not there, and says
why:

```
FATAL: the media store at /srv/media has no .sdi-media-volume.
The filesystem holding the photographs is almost certainly not mounted...
```

The container will restart-loop, which is the point: a stopped service is
a smaller harm than one quietly writing to the wrong disk, and five
seconds of logs beats a bug report about missing photographs weeks later.
Leave `SDI_MEDIA_SENTINEL` empty on a host with nothing mounted; start-up
then says the check is off rather than saying nothing.

**The database publishes no port.** It never has. Adding one to debug
something is how it ends up reachable from outside; use
`docker compose exec db psql` instead.

**`SDI_INTEGRATION_PASSWORD is not set` is expected.** It is the
worker's database login, and the worker sits behind a compose profile
that is not started. Compose interpolates the whole file at parse time
whatever the profiles say, so it warns about a service that will not
run. Nothing is broken. Set it in `.env` before enabling
`COMPOSE_PROFILES=worker`, and note that role passwords are handed out
by a database init script that runs **once**, at first start on an empty
volume -- adding the variable later leaves `sdi_integration` NOLOGIN
until you `ALTER ROLE` it by hand or rebuild the volume.

**A firewall.** A cloud-level one is better than a host one, because it
drops traffic before it reaches the host: on Linode, Cloud Firewall with
inbound `22/tcp`, `80,443/tcp` accepted and a default inbound policy of
Drop. That is the whole job -- skip the rest of this section.

Only if there is no cloud firewall, on the host. `ufw` is not installed
on a minimal image (`ufw: command not found`), so install it first:

```bash
apt-get update && apt-get install -y ufw
ufw allow 22/tcp          # BEFORE enabling, or you lock yourself out
ufw allow 80,443/tcp      # path A
# ufw allow 3099/tcp      # path B instead
ufw --force enable
```

And know its limit: **Docker bypasses ufw for published ports.** It
writes its own iptables rules in the `DOCKER` chain, ahead of ufw's, so
a `ports:` entry is reachable from the internet whether or not ufw has a
rule for it. ufw protects the host's own services; it does not protect
containers. Not publishing a port is what protects a container -- which
is why path A gives the web container `ports: !override []`.
