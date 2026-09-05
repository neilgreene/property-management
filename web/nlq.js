// =====================================================================
// nlq.js  |  plain-English search
// =====================================================================
// "3 bed duplex in Cleveland under 200k with the best yield" ->
//   { min_beds:3, property_type:'Duplex', city:'Cleveland',
//     max_price:200000, sort:'cap_desc' }
//
// WHAT THIS IS. A rules parser. It is not a language model and it does
// not call one. It is here because the shape of the feature -- free text
// in, a bounded criteria object out -- is the part that has to be right,
// and it is worth having that seam built and tested before a model is
// wired behind it.
//
// WHY IT IS SHAPED THIS WAY. The parser's only output is a criteria
// object whose keys the database itself constrains (see the allowlist on
// core.saved_search) and whose values the query builder binds. So the
// blast radius of a wrong answer -- from these rules today or from a
// model tomorrow -- is a bad search, never a bad query. A model that
// hallucinated `{"'; DROP TABLE": 1}` would produce an ignored key.
//
// SWAPPING IN A MODEL. Replace the body of parse() with a call that
// returns the same object, keep interpret() as the validator on the way
// out, and nothing else in the system changes. The validator is not
// optional in that world -- it is the thing that makes model output safe
// to execute.

const TYPES = {
  'single family': 'Single Family', 'single-family': 'Single Family',
  'house': 'Single Family', 'houses': 'Single Family', 'sfr': 'Single Family',
  'duplex': 'Duplex', 'duplexes': 'Duplex',
  'triplex': 'Triplex', 'triplexes': 'Triplex',
  'condo': 'Condo', 'condos': 'Condo', 'condominium': 'Condo',
  'townhouse': 'Townhouse', 'townhouses': 'Townhouse', 'townhome': 'Townhouse',
};

// Keys the criteria object may contain. Identical to the database
// constraint on core.saved_search by design: what cannot be stored must
// not be produced.
const KEYS = new Set(['q', 'city', 'state', 'property_type', 'status',
  'min_price', 'max_price', 'min_beds', 'max_beds', 'min_baths', 'max_baths',
  'min_sqft', 'max_sqft', 'sort',
  // Operational criteria. These are the questions staff actually have and
  // could not previously ask: what is flagged, what is underperforming,
  // what has no photographs, what nobody has sent out, what is still on
  // an old fee schedule.
  'flag', 'min_roi', 'max_roi', 'no_photos', 'not_shared_days', 'fees_stale',
  // The map viewport. Not a search intent a person types, but a criterion
  // the server applies, so it passes through the same validator as
  // everything else rather than round the side of it.
  'bbox_n', 'bbox_s', 'bbox_e', 'bbox_w']);

// STAFF ONLY, AND DROPPED RATHER THAN APPLIED for anybody else.
//
// Two of these read band 3 figures -- five-year ROI is derived from the
// offer and the underwriting -- and a filter on a hidden number is an
// oracle: narrow it repeatedly and the result set tells you the value one
// bisection at a time. That is the same attack the map viewport had to be
// designed against.
//
// So they are dropped here AND refused underneath: api.property_return
// and api.share_log return nothing to a caller who may not read them. The
// second layer is the one that matters, being the one that survives
// somebody deleting the first by mistake.
//
// Dropped and REPORTED, not dropped silently. A saved search made by an
// admin and later opened by an investor should not quietly return
// different results with no explanation.
const STAFF_KEYS = new Set(['flag', 'min_roi', 'max_roi', 'no_photos',
  'not_shared_days', 'fees_stale']);

const FLAGS = new Set(['critical', 'attention', 'ok']);

const SORTS = new Set(['price_asc', 'price_desc', 'sqft_desc', 'beds_desc', 'cap_desc', 'ref']);

// A money-ish token: 250k, $250,000, 1.2m, 250000
function money(tok) {
  if (!tok) return null;
  const m = /^\$?([\d,.]+)\s*([kKmM])?$/.exec(tok.trim());
  if (!m) return null;
  const n = Number(m[1].replace(/,/g, ''));
  if (!Number.isFinite(n)) return null;
  const mult = m[2] ? (m[2].toLowerCase() === 'k' ? 1e3 : 1e6) : 1;
  const v = n * mult;
  // "under 200" plainly means 200 thousand in this context; "under 200000"
  // does not need help. The threshold is where the two cannot be confused.
  return v < 2000 && !m[2] ? v * 1000 : v;
}

const NUM = '\\$?[\\d,.]+\\s*[kKmM]?';

function parse(text, cities = []) {
  const out = {};
  if (!text || !text.trim()) return out;
  const s = ' ' + text.toLowerCase().replace(/\s+/g, ' ').trim() + ' ';

  let m;
  // --- size -----------------------------------------------------------
  // Parsed BEFORE price, and the matched phrase is then removed from the
  // text the price rules see. Otherwise "over 1500 sqft" reads as a
  // $1.5m floor: both rules match "over <number>", and only the unit
  // that follows tells them apart.
  const SQFT = '(?:sq ?ft|sqft|square feet|square foot|sf)';
  if ((m = new RegExp(`(?:under|below|less than|up to|max) ([\\d,]+)\\s*\\+?\\s*${SQFT}`).exec(s))) {
    out.max_sqft = Number(m[1].replace(/,/g, ''));
  }
  if (out.max_sqft == null &&
      (m = new RegExp(`([\\d,]+)\\s*\\+\\s*${SQFT}`).exec(s)) ||
      (m = new RegExp(`(?:over|above|more than|at least) ([\\d,]+)\\s*${SQFT}`).exec(s))) {
    if (m) out.min_sqft = Number(m[1].replace(/,/g, ''));
  }
  if (out.min_sqft == null && out.max_sqft == null &&
      (m = new RegExp(`([\\d,]{3,})\\s*${SQFT}`).exec(s))) {
    out.min_sqft = Number(m[1].replace(/,/g, ''));
  }

  // Everything the size rules consumed is removed before price is read.
  let sp = s.replace(new RegExp(`(?:under|below|less than|up to|max|over|above|more than|at least)?\\s*[\\d,]+\\s*\\+?\\s*${SQFT}`, 'g'), ' ');

  // --- rates, BEFORE price and consuming their own text ---------------
  //
  // A rate and a price are both "under N", and the money heuristic reads
  // a bare "under 15" as $15,000 -- so "under 15% roi" parsed as both,
  // producing a price filter that matches nothing and made the ROI filter
  // look broken. A lookahead was the first fix and was worse: it also
  // suppressed the legitimate price in "over 300k best yield", where the
  // rate word is part of the SORT and nothing to do with the number.
  //
  // Matching first and cutting the matched span out of the string the
  // price rules read is the version that holds. One number, consumed
  // once, by whichever rule recognised it.
  const eat = (re, set) => {
    const mm = re.exec(sp);
    if (!mm) return false;
    set(Number(mm[1]));
    sp = sp.slice(0, mm.index) + ' '.repeat(mm[0].length) + sp.slice(mm.index + mm[0].length);
    return true;
  };
  eat(/\b(?:roi|return)\b[^.]{0,20}?\b(?:under|below|less than|<)\s*(\d+(?:\.\d+)?)\s*%?/,
      (n) => { out.max_roi = n; })
    || eat(/\b(?:under|below|less than)\s*(\d+(?:\.\d+)?)\s*%\s*(?:roi|return|yield)?/,
      (n) => { out.max_roi = n; });
  eat(/\b(?:roi|return)\b[^.]{0,20}?\b(?:over|above|at least|more than|>)\s*(\d+(?:\.\d+)?)\s*%?/,
      (n) => { out.min_roi = n; })
    || eat(/\b(?:over|above|at least|more than)\s*(\d+(?:\.\d+)?)\s*%\s*(?:roi|return|yield)?/,
      (n) => { out.min_roi = n; });

  // --- price ---------------------------------------------------------
  if ((m = new RegExp(`between (${NUM}) (?:and|to|-) (${NUM})`).exec(sp)) ||
      (m = new RegExp(`(${NUM})\\s*(?:-|to)\\s*(${NUM})`).exec(sp))) {
    const a = money(m[1]), b = money(m[2]);
    if (a != null && b != null) { out.min_price = Math.min(a, b); out.max_price = Math.max(a, b); }
  }
  if (out.max_price == null &&
      (m = new RegExp(`(?:under|below|less than|up to|max|cheaper than|no more than) (${NUM})`).exec(sp))) {
    const v = money(m[1]); if (v != null) out.max_price = v;
  }
  if (out.min_price == null &&
      (m = new RegExp(`(?:over|above|more than|at least|from|min|starting at) (${NUM})`).exec(sp))) {
    const v = money(m[1]); if (v != null) out.min_price = v;
  }

  // --- beds and baths -------------------------------------------------
  if ((m = /(\d+)\s*\+?\s*(?:bed|beds|bedroom|bedrooms|br|bd)\b/.exec(s))) out.min_beds = Number(m[1]);
  if ((m = /(\d+(?:\.\d)?)\s*\+?\s*(?:bath|baths|bathroom|bathrooms|ba)\b/.exec(s))) out.min_baths = Number(m[1]);
  // "exactly 3 bedrooms" pins both ends.
  if ((m = /exactly (\d+)\s*(?:bed|beds|bedroom|bedrooms)\b/.exec(s))) {
    out.min_beds = out.max_beds = Number(m[1]);
  }

  // --- property type ---------------------------------------------------
  for (const [word, canon] of Object.entries(TYPES)) {
    if (s.includes(' ' + word + ' ') || s.includes(' ' + word + 's ')) { out.property_type = canon; break; }
  }

  // --- city -------------------------------------------------------------
  // Matched against the cities the CALLER can actually see, passed in by
  // the server. A city nobody is listed in is not a filter, it is a typo.
  for (const c of cities) {
    if (s.includes(' ' + c.toLowerCase() + ' ') || s.includes(' in ' + c.toLowerCase())) {
      out.city = c; break;
    }
  }

  // --- operational, for staff ------------------------------------------
  // These are parsed for everybody and DROPPED BY interpret() for anyone
  // who may not use them. Parsing them conditionally would mean the same
  // sentence parsed two ways depending on who typed it, which is a much
  // harder thing to reason about than one parse and one gate.
  if (/\b(critical|urgent|emergenc)/.test(s)) out.flag = 'critical';
  else if (/\b(attention|needs? (?:doing|chasing)|to chase|chasing)\b/.test(s)) out.flag = 'attention';
  else if (/\b(clear|nothing outstanding|no (?:open )?(?:issues|problems|flags))\b/.test(s)) out.flag = 'ok';
  if (/\bflagged\b/.test(s) && !out.flag) out.flag = 'critical';

  if (/\bno (?:photo|photograph|picture|image)/.test(s)
   || /\b(?:missing|without) (?:photo|photograph|picture|image)/.test(s)) out.no_photos = true;
  if (/\b(?:stale|old|superseded|outdated) fee/.test(s)
   || /\bfees? (?:are )?(?:stale|out of date|outdated)\b/.test(s)) out.fees_stale = true;

  // "not shared in 30 days", "nobody has sent in the last 60 days"
  if ((m = /\bnot (?:been )?(?:shared|sent)\b[^.]{0,20}?(\d+)\s*days?/.exec(s))
   || (m = /\b(?:no[tb]|never)[^.]{0,30}?(?:shared|sent)[^.]{0,20}?(\d+)\s*days?/.exec(s))) {
    out.not_shared_days = Number(m[1]);
  }

  // --- ordering ---------------------------------------------------------
  if (/\b(best|highest|top)\s+(yield|cap|cap rate|return)\b/.test(s) || /\bcap rate\b/.test(s)) out.sort = 'cap_desc';
  else if (/\b(cheapest|lowest price|least expensive|budget)\b/.test(s)) out.sort = 'price_asc';
  else if (/\b(most expensive|priciest|highest price)\b/.test(s)) out.sort = 'price_desc';
  else if (/\b(biggest|largest)\b/.test(s)) out.sort = 'sqft_desc';
  else if (/\b(most bedrooms|most beds)\b/.test(s)) out.sort = 'beds_desc';

  return out;
}

// The validator. Everything the parser -- or a model, later -- produces
// passes through here before it reaches a query or the database.
// `staff` decides whether the operational criteria survive. It defaults
// to false: a caller that forgets to pass it gets the safe answer rather
// than the convenient one.
function interpret(obj, { staff = false } = {}) {
  const out = {};
  const ignored = [];
  Object.defineProperty(out, '__ignored', { value: ignored, enumerable: false });
  if (!obj || typeof obj !== 'object') return out;
  for (const [k, v] of Object.entries(obj)) {
    if (!KEYS.has(k)) continue;
    if (STAFF_KEYS.has(k) && !staff) { ignored.push(k); continue; }
    if (k === 'sort') { if (SORTS.has(v)) out.sort = v; continue; }
    if (k === 'flag') { if (FLAGS.has(v)) out.flag = v; continue; }
    // Booleans arrive off a query string as the string "1", and as real
    // booleans from a saved search. Both mean the same thing.
    if (k === 'no_photos' || k === 'fees_stale') {
      if (v === true || v === '1' || v === 1 || v === 'true') out[k] = true;
      continue;
    }
    // A rate is typed as a percentage and stored as a fraction. 15 means
    // 15%, not 1500%; anything above 1 is read as a percentage, which is
    // what somebody typing into a box marked ROI will always mean.
    if (k === 'min_roi' || k === 'max_roi') {
      const n = Number(v);
      if (Number.isFinite(n) && n > -10 && n < 1000) out[k] = n > 1 ? n / 100 : n;
      continue;
    }
    if (k === 'q' || k === 'city' || k === 'state' || k === 'property_type' || k === 'status') {
      if (typeof v === 'string' && v.length && v.length <= 60) out[k] = v;
      continue;
    }
    // Coordinates are the one numeric criterion that is legitimately
    // negative -- every longitude in the United States is. The general
    // rule below rejects negatives on purpose (a price or a bedroom count
    // never is), so the map box needs its own bounds rather than a
    // loosened rule for everything.
    if (k.startsWith('bbox_')) {
      const n = Number(v);
      const limit = (k === 'bbox_n' || k === 'bbox_s') ? 90 : 180;
      if (Number.isFinite(n) && n >= -limit && n <= limit) out[k] = n;
      continue;
    }
    const n = Number(v);
    if (Number.isFinite(n) && n >= 0 && n < 1e9) out[k] = n;
  }
  return out;
}

// A sentence describing what was understood, so the box is never a black
// box: the user sees the parse, not just the results.
function explain(c) {
  const bits = [];
  const money = (n) => '$' + Number(n).toLocaleString();
  const plural = (t) => ({ 'Single Family': 'single-family homes', 'Duplex': 'duplexes',
                           'Triplex': 'triplexes', 'Condo': 'condos',
                           'Townhouse': 'townhouses' }[t] || t.toLowerCase());
  if (c.property_type) bits.push(plural(c.property_type));
  if (c.min_beds && c.min_beds === c.max_beds) bits.push(`exactly ${c.min_beds} bed`);
  else if (c.min_beds) bits.push(`${c.min_beds}+ bed`);
  if (c.min_baths) bits.push(`${c.min_baths}+ bath`);
  if (c.city) bits.push('in ' + c.city);
  if (c.min_price && c.max_price) bits.push(`${money(c.min_price)}–${money(c.max_price)}`);
  else if (c.max_price) bits.push('under ' + money(c.max_price));
  else if (c.min_price) bits.push('over ' + money(c.min_price));
  if (c.min_sqft) bits.push(`${Number(c.min_sqft).toLocaleString()}+ sq ft`);
  if (c.max_sqft) bits.push(`under ${Number(c.max_sqft).toLocaleString()} sq ft`);
  if (c.flag === 'critical')  bits.push('flagged critical');
  if (c.flag === 'attention') bits.push('needing attention');
  if (c.flag === 'ok')        bits.push('with nothing outstanding');
  if (c.min_roi != null) bits.push(`${(c.min_roi * 100).toFixed(1)}%+ five-year ROI`);
  if (c.max_roi != null) bits.push(`under ${(c.max_roi * 100).toFixed(1)}% five-year ROI`);
  if (c.no_photos) bits.push('with no photographs');
  if (c.fees_stale) bits.push('on a superseded fee schedule');
  if (c.not_shared_days) bits.push(`not shared in ${c.not_shared_days} days`);
  const order = { cap_desc: 'best cap rate first', price_asc: 'cheapest first',
                  price_desc: 'most expensive first', sqft_desc: 'largest first',
                  beds_desc: 'most bedrooms first' }[c.sort];
  if (order) bits.push(order);
  return bits.length ? bits.join(', ') : null;
}

module.exports = { parse, interpret, explain, KEYS, SORTS, STAFF_KEYS, FLAGS };
