'use strict';
// Every setting the web tier reads actually reaches the web container.
//
// Compose reads `.env` to INTERPOLATE a compose file. That is not the same
// as putting a variable into the container: a name only reaches the
// process if the service lists it under `environment:`. The two look
// identical from the outside, and the failure is silent -- an option that
// never arrives behaves exactly like an option deliberately left off.
//
// Four settings had been in that state. `COOKIE_INSECURE` and
// `TRUST_PROXY` were both instructed by the deployment guide as lines to
// add to `.env`, and neither had ever done anything. `DEMO_PERSONAS` was
// documented in the README the same way. `SDI_MEDIA_SENTINEL` joined them
// the day it was added.
//
// This is the same failure as the Dockerfile COPY list in server.test.js:
// code and packaging drifting apart, where the code is right, the
// packaging is wrong, and nothing fails loudly enough to notice.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const web = path.join(__dirname, '..');
const root = path.join(web, '..');

// Names read by the web tier but deliberately not passed through, each with
// the reason. A name here is a decision; a name in neither list is a bug.
const NOT_PASSED = {
  PORT: 'always the container default 3000; WEB_PORT maps it on the host',
  PGPORT: 'the database is on the default port on the compose network',
  SDI_VERSION: 'baked into the image by the Dockerfile ARG/ENV at build time. '
    + 'Passing it here with a `:-` default would blank the real stamp on any '
    + 'deployment without an .env entry',
  SDI_COMMIT: 'baked in at build time, as SDI_VERSION',
  SDI_MFA_KEY: 'MFA has schema but no application layer yet. Add this to both '
    + 'compose files at the same time as the code that reads it',
};

function envNamesReadByTheApp() {
  const names = new Set();
  for (const f of fs.readdirSync(web).filter((n) => n.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(web, f), 'utf8');
    for (const m of src.matchAll(/process\.env\.([A-Z_][A-Z_0-9]*)/g)) names.add(m[1]);
  }
  return names;
}

// The `web:` service block, from its header to the next service at the same
// indent. Reading the whole file would let a name defined on `db` or
// `worker` satisfy a requirement on `web`.
function webServiceBlock(file) {
  const src = fs.readFileSync(path.join(root, file), 'utf8');
  const start = src.indexOf('\n  web:\n');
  assert.ok(start >= 0, `${file} has no web service`);
  const rest = src.slice(start + 1);
  const next = rest.slice(1).search(/\n {2}[a-z][a-z-]*:\n/);
  return next === -1 ? rest : rest.slice(0, next + 1);
}

const keysIn = (block) => new Set(
  [...block.matchAll(/^ {6}([A-Z_][A-Z_0-9]*):/gm)].map((m) => m[1]));

for (const file of ['docker-compose.yml', 'docker-compose.release.yml']) {
  test(`${file} passes the web tier every setting it reads`, () => {
    const declared = keysIn(webServiceBlock(file));
    const missing = [...envNamesReadByTheApp()]
      .filter((n) => !declared.has(n) && !(n in NOT_PASSED))
      .sort();

    assert.deepEqual(missing, [],
      `${file} does not pass these to the web container, so setting them in `
      + `.env does nothing: ${missing.join(', ')}. Add them under the web `
      + "service's environment:, or add them to NOT_PASSED in this test with "
      + 'the reason they are deliberately left out.');
  });
}

test('the build stamp is not overwritten by an empty compose value', () => {
  // SDI_VERSION and SDI_COMMIT come from the Dockerfile. If either is ever
  // added to a compose environment with a `:-` default, every deployment
  // without an .env entry reports its build as `dev` -- and a wrong version
  // is worse than no version, because somebody trusts it while chasing the
  // wrong bug.
  for (const file of ['docker-compose.yml', 'docker-compose.release.yml']) {
    const declared = keysIn(webServiceBlock(file));
    for (const n of ['SDI_VERSION', 'SDI_COMMIT']) {
      assert.ok(!declared.has(n),
        `${file} sets ${n} on the web service, which overwrites the value the `
        + 'Dockerfile baked in at build time');
    }
  }
  const dockerfile = fs.readFileSync(path.join(web, 'Dockerfile'), 'utf8');
  assert.match(dockerfile, /ENV SDI_VERSION=\$SDI_VERSION/);
  assert.match(dockerfile, /ENV SDI_COMMIT=\$SDI_COMMIT/);
});
