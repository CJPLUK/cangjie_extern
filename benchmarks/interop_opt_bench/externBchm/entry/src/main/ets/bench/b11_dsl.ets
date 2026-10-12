import { b11_probe, b11_run, B11Config, B11Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// ---------------------------------------------------------------------------
// The interpreter: a fixed ArkTS library. Programs are generated on the Cangjie side as JSON text.
// A program is a list of instructions over registers; r0..r5 hold the arguments.
//   [0, dst, src, "key"]      dst = src.key
//   [1, obj, "key", src]      obj.key = src
//   [2, dst]                  dst = {}
//   [3, arr, src]             arr.push(src)
//   [4, dst, a, b, ...]       dst = [ra, rb, ...]
//   [5, src]                  return src
// ---------------------------------------------------------------------------
type Insn = (number | string)[];

function exec(prog: Insn[], r: Object[]): Object {
  for (let pc = 0; pc < prog.length; pc++) {
    const ins = prog[pc];
    const op = ins[0] as number;
    if (op === 0) {
      r[ins[1] as number] = Reflect.get(r[ins[2] as number], ins[3] as string) as Object;
    } else if (op === 1) {
      Reflect.set(r[ins[1] as number], ins[2] as string, r[ins[3] as number]);
    } else if (op === 2) {
      r[ins[1] as number] = new Object();
    } else if (op === 3) {
      (r[ins[1] as number] as Object[]).push(r[ins[2] as number]);
    } else if (op === 4) {
      const a: Object[] = [];
      for (let k = 2; k < ins.length; k++) {
        a.push(r[ins[k] as number]);
      }
      r[ins[1] as number] = a;
    } else {
      return r[ins[1] as number];
    }
  }
  return 0;
}

function regs(a0: Object, a1?: Object, a2?: Object, a3?: Object, a4?: Object, a5?: Object): Object[] {
  const r: Object[] = [a0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  if (a1 !== undefined) { r[1] = a1; }
  if (a2 !== undefined) { r[2] = a2; }
  if (a3 !== undefined) { r[3] = a3; }
  if (a4 !== undefined) { r[4] = a4; }
  if (a5 !== undefined) { r[5] = a5; }
  return r;
}

// Parse and run in one call.
const evalProg = (src: string, a0: Object, a1?: Object, a2?: Object, a3?: Object, a4?: Object, a5?: Object): Object =>
  exec(JSON.parse(src) as Insn[], regs(a0, a1, a2, a3, a4, a5));

// Load once (returns an id), then run by id.
const PROGS: Insn[][] = [];
const loadProg = (src: string): number => {
  PROGS.push(JSON.parse(src) as Insn[]);
  return PROGS.length - 1;
};
const callProg = (id: number, a0: Object, a1?: Object, a2?: Object, a3?: Object, a4?: Object, a5?: Object): Object =>
  exec(PROGS[id], regs(a0, a1, a2, a3, a4, a5));

// ---------------------------------------------------------------------------
// Fixtures and hand-written ArkTS functions ("stub": what a compiler could generate at build time).
// ---------------------------------------------------------------------------
class L7 { k7: number = 42; }
class L6 { k6: L7 = new L7(); }
class L5 { k5: L6 = new L6(); }
class L4 { k4: L5 = new L5(); }
class L3 { k3: L4 = new L4(); }
class L2 { k2: L3 = new L3(); }
class L1 { k1: L2 = new L2(); }
class L0 { k0: L1 = new L1(); }
const ROOT: L0 = new L0();
const LEAF = 42;

// A path of depth d starts at node L(8 - d).
function startNode(d: number): Object {
  if (d === 8) { return ROOT; }
  if (d === 4) { return ROOT.k0.k1.k2.k3; }
  if (d === 2) { return ROOT.k0.k1.k2.k3.k4.k5; }
  return ROOT.k0.k1.k2.k3.k4.k5.k6;
}

class B11Meta {
  title: string = 'wireless noise cancelling headphones';
  brand: string = 'sonora';
  description: string = 'portable bluetooth speaker with fast usb charger';
}
class B11Price { amount: number = 99; }
class B11Item {
  id: number = 7;
  meta: B11Meta = new B11Meta();
  price: B11Price = new B11Price();
}
const ITEM = new B11Item();
const ITEM_SUM = 7 + 99 + ITEM.meta.title.length + ITEM.meta.brand.length + ITEM.meta.description.length;

class B11Row {
  id: number;
  score: number;
  kind: string;
  brand: string;
  price: number;

  constructor(id: number, score: number, kind: string, brand: string, price: number) {
    this.id = id;
    this.score = score;
    this.kind = kind;
    this.brand = brand;
    this.price = price;
  }
}

class B11Lib {
  path1 = (o: L7): number => o.k7;
  path2 = (o: L6): number => o.k6.k7;
  path4 = (o: L4): number => o.k4.k5.k6.k7;
  path8 = (o: L0): number => o.k0.k1.k2.k3.k4.k5.k6.k7;
  reader = (it: B11Item): Object[] => [it.id, it.meta.title, it.meta.brand, it.price.amount, it.meta.description];
  writer = (res: Object[], id: number, score: number, kind: string, brand: string, price: number): void => {
    res.push(new B11Row(id, score, kind, brand, price));
  };
  evalProg = evalProg;
  loadProg = loadProg;
  callProg = callProg;
}
const LIB = new B11Lib();

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------
interface Case {
  work: string;  // path | read | write
  d: number;     // path depth (path only)
}

function checksumOk(c: Case, n: number, got: number, results: Object[]): number {
  if (c.work === 'path') {
    return got === n * LEAF ? 1 : 0;
  }
  if (c.work === 'read') {
    return got === n * ITEM_SUM ? 1 : 0;
  }
  // write: n rows with ids 0..n-1
  let s = 0;
  for (const o of results) {
    s += Reflect.get(o, 'id') as number;
  }
  return results.length === n && s === n * (n - 1) / 2 ? 1 : 0;
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB11(sink: LogSink, opts: string[]): Promise<void> {
  if (opts.indexOf('probe') >= 0) {
    benchLine(sink, `BENCH,b11_probe,${b11_probe()}`);
    return;
  }
  const quick = opts.indexOf('quick') >= 0;
  const n = quick ? 1000 : 10000;
  let reps = quick ? 2 : 20;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const cases: Case[] = [
    { work: 'path', d: 1 }, { work: 'path', d: 2 }, { work: 'path', d: 4 }, { work: 'path', d: 8 },
    { work: 'read', d: 0 }, { work: 'write', d: 0 },
  ];
  const variants: string[] = ['naive', 'stub', 'interp', 'interp_cached'];
  const results: Object[] = [];
  let seed = 5;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };

  const runCase = (c: Case, v: string, count: number): B11Result => {
    const cfg: B11Config = { work: c.work, variant: v, d: c.d, n: count };
    const fixture: Object = c.work === 'path' ? startNode(c.d) : c.work === 'read' ? ITEM : results;
    return b11_run(cfg, fixture, LIB);
  };

  // warmup
  for (const c of cases) {
    for (const v of variants) {
      runCase(c, v, 500);
      results.length = 0;
    }
  }
  // BENCH,b11,work,d,variant,n,rep,ns_per_op,ok
  benchLine(sink, 'BENCH,b11,work,d,variant,n,rep,ns_per_op,ok');
  for (let rep = 0; rep < reps; rep++) {
    for (const c of cases) {
      const order: number[] = [0, 1, 2, 3];
      for (let k = order.length - 1; k > 0; k--) {
        const j = rnd(k + 1);
        const tmp = order[k];
        order[k] = order[j];
        order[j] = tmp;
      }
      for (const k of order) {
        const v = variants[k];
        const r = runCase(c, v, n);
        const ok = checksumOk(c, n, r.checksum, results);
        results.length = 0;
        benchLine(sink, `BENCH,b11,${c.work},${c.d},${v},${n},${rep},${(r.ns / n).toFixed(1)},${ok}`);
        await yieldToSystem();
      }
    }
  }
}
