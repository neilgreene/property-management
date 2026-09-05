'use strict';
// =====================================================================
// llm.js  |  the model behind the search box
// =====================================================================
// Step three of three. Steps one and two were the work: the criteria
// vocabulary the model is allowed to speak (nlq.js KEYS, mirrored by the
// CHECK on core.saved_search), and the screening that refuses a request
// that would steer before anything is parsed at all.
//
// THE MODEL RETURNS CRITERIA, NEVER SQL. Text-to-SQL is the tempting
// version and the wrong one. Here the model fills in a fixed schema whose
// keys are the same allowlist the rules parser produces, nlq.interpret()
// validates the result on the way out exactly as it does for the rules,
// and the query builder binds every value. A model that hallucinates a
// key produces an ignored key.
//
// STRICT TOOL USE RATHER THAN "RETURN JSON". `strict: true` with
// additionalProperties:false means the API itself guarantees the argument
// object matches the schema. Asking for JSON in a prompt and parsing the
// reply is the same idea with the guarantee removed.
//
// THE RULES PARSER RUNS FIRST AND IS THE FALLBACK. "3 bed duplex in
// Cleveland under 200k" is handled by regexes today: instantly, free, and
// identically every time. The model is for the sentences the rules do not
// reach. That ordering also means the search box keeps working when there
// is no API key, when the network is down, and when a request is slow --
// a search that depends on a third party being up is a search that is
// down whenever they are.
const nlq = require('./nlq');

// The skill's default. Deliberately NOT downgraded for cost: which model
// runs is the operator's decision, not this file's, and SDI_LLM_MODEL
// makes it a one-line change if they want the tradeoff.
const MODEL = process.env.SDI_LLM_MODEL || 'claude-opus-5';

// A search box cannot hang. Past this the rules answer stands and the
// caller is told the model was not consulted.
const TIMEOUT_MS = Number(process.env.SDI_LLM_TIMEOUT_MS || 8000);

// The schema IS the vocabulary. Built from the same constants the rules
// parser and the database use, so a key added in one place cannot be
// missing here -- and a test asserts the three agree.
function schema() {
  const props = {
    city:          { type: ['string', 'null'], description: 'Exact city name from the list given.' },
    state:         { type: ['string', 'null'], description: 'Two-letter state code.' },
    property_type: { type: ['string', 'null'],
                     enum: [null, 'Single Family', 'Duplex', 'Triplex', 'Condo', 'Townhouse'] },
    status:        { type: ['string', 'null'],
                     enum: [null, 'active', 'pending', 'sold', 'coming_soon', 'draft'] },
    min_price: { type: ['number', 'null'] }, max_price: { type: ['number', 'null'] },
    min_beds:  { type: ['number', 'null'] }, max_beds:  { type: ['number', 'null'] },
    min_baths: { type: ['number', 'null'] }, max_baths: { type: ['number', 'null'] },
    min_sqft:  { type: ['number', 'null'] }, max_sqft:  { type: ['number', 'null'] },
    sort: { type: ['string', 'null'], enum: [null, ...nlq.SORTS] },
    // Operational. Offered to the model for everybody and dropped by
    // interpret() for callers who may not use them -- the same one parse,
    // one gate rule the rules path follows. Parsing conditionally would
    // mean one sentence understood two ways depending on who typed it.
    flag: { type: ['string', 'null'], enum: [null, 'critical', 'attention', 'ok'] },
    min_roi: { type: ['number', 'null'], description: 'Five-year annual ROI as a fraction: 0.15 for 15%.' },
    max_roi: { type: ['number', 'null'], description: 'Five-year annual ROI as a fraction: 0.15 for 15%.' },
    no_photos:       { type: ['boolean', 'null'] },
    fees_stale:      { type: ['boolean', 'null'] },
    not_shared_days: { type: ['number', 'null'] },
  };
  return { type: 'object', properties: props,
           required: Object.keys(props), additionalProperties: false };
}

const SYSTEM = [
  'You turn a property investor\'s search phrase into filter criteria.',
  '',
  'Fill in only what the phrase actually asks for. Everything else is null.',
  'Do not infer a filter from a preference the phrase does not state: "a good',
  'investment" is not a price range, and "near me" is not a city.',
  '',
  'Prices are US dollars. A bare number under 2000 in a price context means',
  'thousands: "under 200" is 200000.',
  '',
  'ROI is the five-year annual return and is a fraction: 15% is 0.15.',
  '',
  'This is an investment marketplace. Never produce criteria standing in for',
  'schools, crime, neighbourhood quality, demographics, or who lives in an',
  'area -- those requests are refused before they reach you, and quietly',
  'turning one into a city or a bedroom count would defeat that.',
].join('\n');

let client = null;

// A KEY THAT IS NOT A KEY IS NOT CONFIGURED. A placeholder left in a
// config file -- "sk-ant-..." copied from an instruction, or "changeme" --
// is a non-empty string, so a bare truthiness check calls it configured.
// The call then fails and the search sits through the whole timeout before
// falling back, on every unparseable search, for as long as the
// placeholder is there. Better to recognise it and stay on the rules.
//
// Deliberately a shape check and nothing more: whether a well-formed key
// is VALID is the API's business, and guessing at that here would mean a
// working key rejected by a regex somebody wrote from memory.
function looksLikeKey(v) {
  const k = String(v || '').trim();
  return k.startsWith('sk-ant-') && k.length > 24 && !k.includes('...');
}

function configured() {
  return looksLikeKey(process.env.ANTHROPIC_API_KEY)
    // An OAuth token has a different shape entirely, so it only has to be
    // present and not obviously a placeholder.
    || (String(process.env.ANTHROPIC_AUTH_TOKEN || '').trim().length > 8
        && !String(process.env.ANTHROPIC_AUTH_TOKEN).includes('...'));
}

function getClient() {
  if (client) return client;
  const Anthropic = require('@anthropic-ai/sdk');
  client = new (Anthropic.default || Anthropic)();
  return client;
}

// Returns { criteria, source } or null when the model could not be used.
// NULL RATHER THAN THROWING: every caller's next move is the same -- keep
// what the rules produced -- and a search box is not a place to surface a
// vendor's outage.
async function parse(text, cities = [], { timeoutMs = TIMEOUT_MS } = {}) {
  if (!configured()) return null;
  const t = String(text || '').trim();
  if (!t) return null;

  try {
    const res = await getClient().beta.messages.create({
      model: MODEL,
      max_tokens: 2048,
      // Filling in a fixed schema is a simple task. High effort here buys
      // nothing and costs on every search.
      output_config: { effort: 'low' },
      // A policy decline on a property search would be surprising, but
      // the answer to one is a working search rather than an error.
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      system: SYSTEM,
      messages: [{
        role: 'user',
        content: `Cities that exist in this marketplace: ${cities.join(', ') || '(none)'}\n\n`
               + `Search phrase: ${t}`,
      }],
      tools: [{
        name: 'search_properties',
        description: 'Apply filter criteria to the property marketplace.',
        strict: true,
        input_schema: schema(),
      }],
      tool_choice: { type: 'auto' },
    }, { timeout: timeoutMs });

    // A refusal is not an error either: the rules answer stands.
    if (res.stop_reason === 'refusal') return null;

    const call = res.content.find((b) => b.type === 'tool_use');
    if (!call) return null;

    // Nulls out, then through the SAME validator the rules parser uses.
    // The model does not get a shorter path to the query than the regexes
    // do -- that is the whole reason this seam was built before it.
    const raw = {};
    for (const [k, v] of Object.entries(call.input || {})) {
      if (v !== null && v !== undefined && v !== '') raw[k] = v;
    }
    return { criteria: raw, source: 'model', model: res.model };
  } catch {
    // Timeout, network, bad key, rate limit. All the same answer.
    return null;
  }
}

module.exports = { parse, configured, looksLikeKey, schema, MODEL, SYSTEM };
