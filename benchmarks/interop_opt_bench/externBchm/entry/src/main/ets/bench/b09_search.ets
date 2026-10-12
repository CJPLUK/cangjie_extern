import { b09_run, B09Config, B09Result } from 'libohos_app_cangjie_entry.so';
import { systemDateTime } from '@kit.BasicServicesKit';
import { benchLine, LogSink, yieldToSystem } from './Log';

// ---- The UI's data: a catalogue of items ----
class B09Meta {
  title: string;
  brand: string;
  description: string;

  constructor(title: string, brand: string, description: string) {
    this.title = title;
    this.brand = brand;
    this.description = description;
  }
}

class B09Price {
  amount: number;

  constructor(amount: number) {
    this.amount = amount;
  }
}

export class B09ItemTS {
  id: number;
  meta: B09Meta;
  price: B09Price;

  constructor(id: number, meta: B09Meta, price: B09Price) {
    this.id = id;
    this.meta = meta;
    this.price = price;
  }
}

export class B09ResultRow {
  id: number = 0;
  score: number = 0;
  kind: string = '';
  brand: string = '';
  price: number = 0;
}

const WORDS: string[] = ['wireless', 'wirless', 'wired', 'noise', 'cancelling', 'headphones', 'speaker', 'portable',
  'bluetooth', 'charger', 'black', 'white', 'pro', 'mini', 'smart', 'watch', 'band', 'case', 'cable', 'usb', 'fast',
  'sport', 'earbuds', 'stereo', 'wireles', 'wire', 'less', 'studio'];
const BRANDS: string[] = ['sonora', 'axiom', 'veltra', 'nimbus', 'orbit', 'kestrel', 'lumen', 'tarsus'];

// Deterministic catalogue: titles of about `titleLen` characters and descriptions of about `descLen`
// characters, built from WORDS.
export function makeCatalogue(n: number, titleLen: number, descLen: number = 0): B09ItemTS[] {
  let seed = 12345;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };
  const items: B09ItemTS[] = [];
  for (let i = 0; i < n; i++) {
    let title = WORDS[rnd(WORDS.length)];
    while (title.length < titleLen) {
      title = title + ' ' + WORDS[rnd(WORDS.length)];
    }
    let description = '';
    while (description.length < descLen) {
      description = description.length === 0 ? WORDS[rnd(WORDS.length)] : description + ' ' + WORDS[rnd(WORDS.length)];
    }
    items.push(new B09ItemTS(i, new B09Meta(title, BRANDS[rnd(BRANDS.length)], description), new B09Price(10 + rnd(990))));
  }
  return items;
}

// Used by the coalesced variant: one call returns all the fields Cangjie needs.
export const reader = (list: Object[], i: number): Object[] => {
  const it = list[i] as B09ItemTS;
  return [it.id, it.meta.title, it.meta.brand, it.price.amount, it.meta.description];
};

function kindCode(k: string): number {
  return k === 'prefix' ? 1 : k === 'match' ? 2 : k === 'fuzzy' ? 3 : 4;
}

// Checksum over the results as the UI receives them, independent of their order.
function checksum(rows: B09ResultRow[]): number {
  let s = 0;
  for (const r of rows) {
    s += Math.round(r.score * 1000) + kindCode(r.kind) * 7 + r.brand.length * 11 + r.id + r.price;
  }
  return s;
}

const QUERY = 'wireless';

// ---- The same search written entirely in ArkTS (single-threaded, on the ArkTS thread) ----
// Minimum edit distance between q and any substring of t (Sellers 1980), as in b09_search.cj.
function substringDistance(q: string, t: string): number {
  const m = q.length;
  let prev: number[] = [];
  let cur: number[] = [];
  for (let i = 0; i <= m; i++) {
    prev.push(i);
    cur.push(0);
  }
  let best = m;
  for (let j = 0; j < t.length; j++) {
    cur[0] = 0;
    const tc = t.charCodeAt(j);
    for (let i = 1; i <= m; i++) {
      const sub = prev[i - 1] + (q.charCodeAt(i - 1) === tc ? 0 : 1);
      const del = prev[i] + 1;
      const ins = cur[i - 1] + 1;
      let v = sub;
      if (del < v) { v = del; }
      if (ins < v) { v = ins; }
      cur[i] = v;
    }
    if (cur[m] < best) { best = cur[m]; }
    const tmp = prev;
    prev = cur;
    cur = tmp;
  }
  return best;
}

export function searchArkTS(list: B09ItemTS[], results: B09ResultRow[], query: string): void {
  for (const it of list) {
    const title = it.meta.title;
    const dist = substringDistance(query, title + ' ' + it.meta.description);
    const row = new B09ResultRow();
    row.id = it.id;
    row.score = 1 - dist / query.length;
    row.kind = title.startsWith(query) ? 'prefix' : dist === 0 ? 'match' : dist <= 2 ? 'fuzzy' : 'none';
    row.brand = it.meta.brand;
    row.price = it.price.amount;
    results.push(row);
  }
}

interface Flags {
  futures: boolean;
  coalesce: boolean;
  scoped: boolean;
  cache: boolean;
}

function allFlags(): Flags[] {
  const out: Flags[] = [];
  for (let m = 0; m < 16; m++) {
    out.push({ futures: (m & 8) !== 0, coalesce: (m & 4) !== 0, scoped: (m & 2) !== 0, cache: (m & 1) !== 0 });
  }
  return out;
}

// Text-length sweep: description of L characters; pure ArkTS vs Cangjie naive vs Cangjie with all optimisations
// (futures, batching b = 8, coalesce, scoped, cache). The number of items shrinks as L grows so that each
// measurement stays short.
const SWEEP: number[][] = [[0, 1000], [50, 1000], [100, 1000], [200, 1000], [500, 500], [1000, 250]];  // [L, items]

interface SweepVariant {
  name: string;
  t: number;      // workers (0 for pure ArkTS)
  allOn: boolean;
}

async function textSweep(sink: LogSink, reps: number): Promise<void> {
  const variants: SweepVariant[] = [
    { name: 'arkts', t: 0, allOn: false },
    { name: 'naive', t: 1, allOn: false }, { name: 'naive', t: 4, allOn: false },
    { name: 'optimised', t: 1, allOn: true }, { name: 'optimised', t: 4, allOn: true },
  ];
  // BENCH,b09t,L,n,variant,t,rep,us_per_item,checksum,errors  (variants in a new random order every rep)
  benchLine(sink, 'BENCH,b09t,L,n,variant,t,rep,us_per_item,checksum,errors');
  let seed = 11;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };
  for (const cfgL of SWEEP) {
    const L = cfgL[0];
    const n = cfgL[1];
    const list = makeCatalogue(n, 40, L);
    const results: B09ResultRow[] = [];
    // warmup each variant once at this length
    for (const v of variants) {
      await sweepOne(v, list, results);
      results.length = 0;
      await yieldToSystem();
    }
    for (let rep = 0; rep < reps; rep++) {
      const order: number[] = [];
      for (let k = 0; k < variants.length; k++) {
        order.push(k);
      }
      for (let k = order.length - 1; k > 0; k--) {
        const j = rnd(k + 1);
        const tmp = order[k];
        order[k] = order[j];
        order[j] = tmp;
      }
      for (const k of order) {
        const v = variants[k];
        const r = await sweepOne(v, list, results);
        const cs = results.length === n ? checksum(results) : -1;
        results.length = 0;
        benchLine(sink, `BENCH,b09t,${L},${n},${v.name},${v.t},${rep},${(r[0] / n / 1000).toFixed(2)},${cs},${r[1]}`);
        await yieldToSystem();
      }
    }
  }
}

// Returns [ns, errors].
async function sweepOne(v: SweepVariant, list: B09ItemTS[], results: B09ResultRow[]): Promise<number[]> {
  if (v.t === 0) {
    const t0 = systemDateTime.getTime(true);
    searchArkTS(list, results, QUERY);
    return [systemDateTime.getTime(true) - t0, 0];
  }
  const cfg: B09Config = { futures: v.allOn, coalesce: v.allOn, scoped: v.allOn, cache: v.allOn, d: 8, t: v.t,
    b: v.allOn ? 8 : 1 };
  const r: B09Result = await b09_run(cfg, list, results, reader, QUERY);
  return [r.ns, r.errors];
}

// Batching: futures off/on x (coalesce, scoped, cache) all off/all on x b = 1/8 items per posted task,
// for 1 and 4 threads, each rep in a new random order.
async function batchGrid(sink: LogSink, list: B09ItemTS[], n: number, titleLen: number, descLen: number,
  reps: number): Promise<void> {
  const cfgs: B09Config[] = [];
  for (const t of [1, 4]) {
    for (const fut of [false, true]) {
      for (const all of [false, true]) {
        for (const b of [1, 8]) {
          cfgs.push({ futures: fut, coalesce: all, scoped: all, cache: all, d: 8, t: t, b: b });
        }
      }
    }
  }
  const results: B09ResultRow[] = [];
  for (const c of cfgs) {  // warmup
    await b09_run(c, list, results, reader, QUERY);
    results.length = 0;
    await yieldToSystem();
  }
  let seed = 7;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };
  // prev: index into the configuration list of the one measured just before; -1 = pure ArkTS
  benchLine(sink, 'BENCH,b09b,t,futures,others,b,n,title_len,desc_len,rep,us_per_item,checksum,errors,prev');
  for (let rep = 0; rep < reps; rep++) {
    const t0 = systemDateTime.getTime(true);
    searchArkTS(list, results, QUERY);
    const ns = systemDateTime.getTime(true) - t0;
    const csA = results.length === n ? checksum(results) : -1;
    results.length = 0;
    benchLine(sink, `BENCH,b09b,0,0,0,0,${n},${titleLen},${descLen},${rep},${(ns / n / 1000).toFixed(2)},${csA},0,-1`);
    await yieldToSystem();
    const order: number[] = [];
    for (let k = 0; k < cfgs.length; k++) {
      order.push(k);
    }
    for (let k = order.length - 1; k > 0; k--) {
      const j = rnd(k + 1);
      const tmp = order[k];
      order[k] = order[j];
      order[j] = tmp;
    }
    let prev = -1;
    for (const k of order) {
      const c = cfgs[k];
      const r: B09Result = await b09_run(c, list, results, reader, QUERY);
      const cs = results.length === n ? checksum(results) : -1;
      results.length = 0;
      benchLine(sink, `BENCH,b09b,${c.t},${c.futures ? 1 : 0},${c.coalesce ? 1 : 0},${c.b},${n},${titleLen},${descLen},` +
        `${rep},${(r.ns / n / 1000).toFixed(2)},${cs},${r.errors},${prev}`);
      prev = k;
      await yieldToSystem();
    }
  }
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB09(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  // 'descN': items get a description of N characters; fewer items for longer texts
  let descLen = 0;
  for (const o of opts) {
    if (o.startsWith('desc')) {
      descLen = Number.parseInt(o.substring(4));
    }
  }
  const n = quick ? 200 : descLen >= 5000 ? 60 : descLen >= 1000 ? 250 : 1000;
  const titleLen = 40;
  const d = 8;
  let reps = quick ? 1 : 5;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const list = makeCatalogue(n, titleLen, descLen);
  const results: B09ResultRow[] = [];
  const flags = allFlags();

  if (opts.indexOf('batch') >= 0) {
    await batchGrid(sink, list, n, titleLen, descLen, reps);
    return;
  }
  if (opts.indexOf('textsweep') >= 0) {
    await textSweep(sink, reps);
    return;
  }
  if (opts.indexOf('arkts') >= 0) {
    for (let w = 0; w < 3; w++) {  // warmup
      searchArkTS(list, results, QUERY);
      results.length = 0;
    }
    // BENCH,b09_arkts,n,title_len,rep,us_per_item,checksum
    benchLine(sink, 'BENCH,b09_arkts,n,title_len,rep,us_per_item,checksum');
    for (let rep = 0; rep < reps; rep++) {
      const t0 = systemDateTime.getTime(true);
      searchArkTS(list, results, QUERY);
      const ns = systemDateTime.getTime(true) - t0;
      const cs = results.length === n ? checksum(results) : -1;
      results.length = 0;
      benchLine(sink, `BENCH,b09_arkts,${n},${titleLen},${rep},${(ns / n / 1000).toFixed(2)},${cs}`);
      await yieldToSystem();
    }
    return;
  }
  const threads: number[] = [1, 4];

  // warmup: all off and all on
  for (const t of threads) {
    for (const f of [flags[0], flags[15]]) {
      const cfg: B09Config = { futures: f.futures, coalesce: f.coalesce, scoped: f.scoped, cache: f.cache, d: d, t: t };
      await b09_run(cfg, list, results, reader, QUERY);
      results.length = 0;
      await yieldToSystem();
    }
  }

  // BENCH,b09,t,futures,coalesce,scoped,cache,n,title_len,desc_len,rep,us_per_item,checksum,errors
  // (t = 0 rows are the pure-ArkTS reference)
  // prev: index (0..15, bits futures/coalesce/scoped/cache) of the configuration measured just before; -1 = pure ArkTS
  benchLine(sink, 'BENCH,b09,t,futures,coalesce,scoped,cache,n,title_len,desc_len,rep,us_per_item,checksum,errors,prev');
  let seed = 2024;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };
  for (let rep = 0; rep < reps; rep++) {
    {
      const t0 = systemDateTime.getTime(true);
      searchArkTS(list, results, QUERY);
      const ns = systemDateTime.getTime(true) - t0;
      const cs = results.length === n ? checksum(results) : -1;
      results.length = 0;
      benchLine(sink, `BENCH,b09,0,0,0,0,0,${n},${titleLen},${descLen},${rep},${(ns / n / 1000).toFixed(2)},${cs},0,-1`);
      await yieldToSystem();
    }
    let prev = -1;  // the pure-ArkTS run above
    for (const t of threads) {
      // a new random order every rep, so no configuration always follows the same one
      const order: number[] = [];
      for (let k = 0; k < flags.length; k++) {
        order.push(k);
      }
      for (let k = order.length - 1; k > 0; k--) {
        const j = rnd(k + 1);
        const tmp = order[k];
        order[k] = order[j];
        order[j] = tmp;
      }
      for (let k = 0; k < flags.length; k++) {
        const f = flags[order[k]];
        const cfg: B09Config = { futures: f.futures, coalesce: f.coalesce, scoped: f.scoped, cache: f.cache, d: d, t: t };
        const r: B09Result = await b09_run(cfg, list, results, reader, QUERY);
        const ok = results.length === n;
        const cs = ok ? checksum(results) : -1;
        results.length = 0;
        benchLine(sink, `BENCH,b09,${t},${f.futures ? 1 : 0},${f.coalesce ? 1 : 0},${f.scoped ? 1 : 0},${f.cache ? 1 : 0},` +
          `${n},${titleLen},${descLen},${rep},${(r.ns / n / 1000).toFixed(2)},${cs},${r.errors},${prev}`);
        prev = order[k];
        await yieldToSystem();
      }
    }
  }
}
