'use strict';
// Every schema file is loaded everywhere it needs to be.
//
// There are THREE hand-maintained lists of sql/ files -- run.sh for a
// laptop, db-rebuild.sh for a local reset, and docker/db.Dockerfile for
// the published image -- and adding a file means editing all three. That
// has been got wrong before: run.sh stopped at 45 while the directory had
// reached 48, so a fresh local database silently lacked three schemas and
// the failure surfaced later as a missing function.
//
// Nothing about that is visible in a diff of the new file, which is why it
// keeps happening. This test is the fourth list, and the only one that
// complains.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');

// Files that are deliberately not loaded with the rest, each with a reason.
const EXCLUDED = {
  '99_local_logins.sql': 'demo passwords published in a public repo; ./run.sh only',
};

// A test walkthrough, not a schema. run.sh runs these separately and the
// image deliberately does not carry them.
const isTest = (n) => /_tests?\.sql$/.test(n);

const schemaFiles = fs.readdirSync(path.join(root, 'sql'))
  .filter((n) => n.endsWith('.sql'))
  .filter((n) => !isTest(n))
  .filter((n) => !(n in EXCLUDED))
  .sort();

const LISTS = [
  ['run.sh', () => read('run.sh')],
  ['db-rebuild.sh', () => read('db-rebuild.sh')],
  ['docker/db.Dockerfile', () => read('docker/db.Dockerfile')],
];

for (const [name, load] of LISTS) {
  test(`${name} loads every schema file`, () => {
    const src = load();
    // db-rebuild.sh lists bare stems, the other two list file names.
    const missing = schemaFiles.filter((f) => !src.includes(f) && !src.includes(f.replace(/\.sql$/, '')));
    assert.deepEqual(missing, [],
      `${name} does not load: ${missing.join(', ')}. A schema file absent from `
      + 'this list is not a build error — the database simply comes up without '
      + 'it, and the first symptom is a missing function somewhere unrelated.');
  });
}

test('the test walkthroughs are not baked into the image', () => {
  // They contain assertions that ROLLBACK, and one of them writes. The
  // image is what other people pull; it should carry the schema and the
  // demo data, not the test suite.
  const dockerfile = read('docker/db.Dockerfile');
  const tests = fs.readdirSync(path.join(root, 'sql')).filter(isTest);
  assert.ok(tests.length > 0, 'no test walkthroughs found — has the naming changed?');
  const baked = tests.filter((t) => dockerfile.includes(t));
  assert.deepEqual(baked, [], `the image copies test walkthroughs: ${baked.join(', ')}`);
});

test('a schema file is never loaded before one it depends on', () => {
  // The lists are ordered, and the order is the dependency order. A file
  // that sorts later must appear later; anything else means somebody
  // inserted a name in the wrong place, which fails at load with an error
  // about a missing table rather than about ordering.
  for (const [name, load] of LISTS) {
    const src = load();
    const positions = schemaFiles
      .map((f) => [f, src.indexOf(f.replace(/\.sql$/, ''))])
      .filter(([, at]) => at >= 0);
    for (let i = 1; i < positions.length; i++) {
      assert.ok(positions[i][1] > positions[i - 1][1],
        `${name} lists ${positions[i][0]} before ${positions[i - 1][0]}; the `
        + 'lists are in dependency order and these are out of sequence');
    }
  }
});
