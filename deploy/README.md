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
curl -fsSLo deploy/Caddyfile \
  https://raw.githubusercontent.com/neilgreene/property-management/claude/postgres-web-access-jznei0/deploy/Caddyfile
curl -fsSLo deploy/docker-compose.public.yml \
  https://raw.githubusercontent.com/neilgreene/property-management/claude/postgres-web-access-jznei0/deploy/docker-compose.public.yml

# The hostname and the contact address are already set for
# 172.235.60.70. Change the hostname only when a domain replaces it.

docker compose -f docker-compose.release.yml \
               -f deploy/docker-compose.public.yml up -d
```

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

**Media lives on the OS disk.** `SDI_MEDIA_DIR=/opt/sdi/media` in `.env`,
a host directory rather than a named volume — `docker compose down -v`
destroys named volumes, and a schema change needs `down -v`. Photographs
must not die with a database rebuild.

**The database publishes no port.** It never has. Adding one to debug
something is how it ends up reachable from outside; use
`docker compose exec db psql` instead.

**A firewall, if the host has no cloud-level one:**

```bash
ufw allow 22/tcp
ufw allow 80,443/tcp      # path A
# ufw allow 3099/tcp      # path B instead
ufw --force enable
```
