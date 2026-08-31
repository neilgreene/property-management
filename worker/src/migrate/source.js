// Source adapter contract for the EspoCRM extract.
//
// The field-level mapping cannot be written without the live EspoCRM schema --
// entity names, custom field keys and which of the 30+ SDI metrics are genuine
// inputs versus derived. What CAN be settled now is the shape of the extract
// and the ordering of the load, which is where relational integrity is won or
// lost. So this file defines the contract and ships a fixture implementation;
// swapping in a real adapter is one module.
//
// An adapter returns plain objects with a stable `sourceId`. That id is the
// join key in ghl.id_map and is what makes a failed load resumable, so it must
// be the EspoCRM primary key -- never a name, email or generated value.
'use strict';

/**
 * @typedef {Object} SourceAdapter
 * @property {() => AsyncIterable<Object>} people      - investors, agents, lenders
 * @property {() => AsyncIterable<Object>} properties  - listings
 * @property {() => AsyncIterable<Object>} links       - property <-> person edges
 * @property {() => AsyncIterable<Object>} deals       - opportunities
 */

function assertAdapter(a) {
  for (const m of ['people', 'properties', 'links', 'deals']) {
    if (typeof a[m] !== 'function') {
      throw new TypeError(`source adapter is missing ${m}()`);
    }
  }
  return a;
}

// Reads an extract already dumped to JSON. Useful for rehearsing the load
// against a snapshot rather than hammering a live EspoCRM instance -- and a
// rehearsal against a snapshot is repeatable, which a live read is not.
function jsonAdapter(doc) {
  const iter = (key) => async function* () {
    for (const row of doc[key] || []) yield row;
  };
  return assertAdapter({
    people: iter('people'),
    properties: iter('properties'),
    links: iter('links'),
    deals: iter('deals'),
  });
}

module.exports = { assertAdapter, jsonAdapter };
