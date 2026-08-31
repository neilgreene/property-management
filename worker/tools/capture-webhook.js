#!/usr/bin/env node
// Capture one live GoHighLevel webhook, exactly as sent.
//
// Why this exists: GHL signs the precise bytes it transmits, and the signature
// algorithm is not stated in their documentation. One real delivery settles it.
// Anything that re-serialises the payload on the way in destroys the evidence,
// so this writes the raw bytes to disk untouched and never parses them first.
//
// Zero dependencies. Node 18+.
//
//   node worker/tools/capture-webhook.js            # listens on 3999
//   PORT=8080 node worker/tools/capture-webhook.js
//
// It needs to be reachable from the internet for GHL to reach it. Easiest
// options: run it on any host with a public address, or put a tunnel in front
// of it (`cloudflared tunnel --url http://localhost:3999` needs no account).
'use strict';

const http = require('http');
const fs   = require('fs');
const path = require('path');

const PORT   = Number(process.env.PORT || 3999);
const OUTDIR = process.env.OUTDIR || path.join(process.cwd(), 'captures');

fs.mkdirSync(OUTDIR, { recursive: true });

let n = 0;

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('capture-webhook is listening. Point a GHL webhook here.\n');
  }

  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const raw = Buffer.concat(chunks);
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const id = String(++n).padStart(3, '0');

    // Raw bytes, byte-for-byte. This file is the evidence.
    const bodyFile = path.join(OUTDIR, `${stamp}-${id}.body.bin`);
    fs.writeFileSync(bodyFile, raw);

    // Headers separately, so the body file stays pristine.
    const headFile = path.join(OUTDIR, `${stamp}-${id}.headers.json`);
    fs.writeFileSync(headFile, JSON.stringify(req.headers, null, 2));

    const sig = req.headers['x-wh-signature'] || '(none)';
    let type = '(unparsed)';
    try { type = JSON.parse(raw.toString('utf8')).type || '(no type)'; } catch {}

    console.log(`\n--- delivery ${id} -------------------------------------`);
    console.log(`  event      : ${type}`);
    console.log(`  body bytes : ${raw.length}`);
    console.log(`  signature  : ${sig.slice(0, 32)}${sig.length > 32 ? '...' : ''}`);
    console.log(`  saved      : ${bodyFile}`);
    console.log(`               ${headFile}`);
    console.log(`  sha256(raw): ${require('crypto').createHash('sha256').update(raw).digest('hex')}`);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end('{"ok":true}');
  });
});

server.listen(PORT, () => {
  console.log(`capture-webhook listening on http://localhost:${PORT}`);
  console.log(`writing to ${OUTDIR}`);
  console.log(`\nSend a TEST contact through GHL, not a real one -- the payload`);
  console.log(`is saved to disk and will be shared, so it should contain no real`);
  console.log(`client data. A contact named "Test Test" is enough.\n`);
});
