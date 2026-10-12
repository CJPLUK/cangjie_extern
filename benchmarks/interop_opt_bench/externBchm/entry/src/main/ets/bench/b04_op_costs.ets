import { systemDateTime } from '@kit.BasicServicesKit';
import { b04_naive, b04_cached, B04Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// ---- Fixture ----
class B04Child {
  v: number = 1;
}

class B04Obj {
  x: number = 1;
  child: B04Child = new B04Child();

  m(v: number): number {
    return v + this.x;
  }
}

class B04Point {
  x: number;
  y: number;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

interface XY {
  x: number;
  y: number;
}

function makeObjs(): B04Obj[] {
  const a: B04Obj[] = [];
  for (let i = 0; i < 16; i++) {
    a.push(new B04Obj());
  }
  return a;
}

function makeArr(): number[] {
  const a: number[] = [];
  for (let i = 0; i < 16; i++) {
    a.push(i);
  }
  return a;
}

function makeVals(): Object[] {
  const a: Object[] = [];
  for (let i = 0; i < 16; i++) {
    a.push(i % 2 === 0 ? i : `s${i}`);
  }
  return a;
}

// Passed to Cangjie as `fx`; the ArkTS loops below use the same objects.
class B04Fx {
  objs: B04Obj[] = makeObjs();
  f0 = (): number => 1;
  f1 = (x: number): number => x + 1;
  fstr = (s: string): number => s.length;
  f5 = (a: number, b: number, c: number, d: number, e: number): number => a + b + c + d + e;
  pointSample: B04Point = new B04Point(0, 0);   // Cangjie takes the class from .constructor
  arr: number[] = makeArr();
  s8: string = 'aaaaaaaa';
  s1000: string = new Array<string>(1000).fill('a').join('');
  vals: Object[] = makeVals();
}

const FX = new B04Fx();

// Allocations in the ArkTS loops are stored here so the JIT cannot drop them.
const SINK: Object[] = new Array<Object>(16);

// ---- Pure ArkTS loops, one per operation. Each returns the checksum. ----
function tsOp(op: string, n: number): number {
  const objs = FX.objs;
  const f0 = FX.f0;
  const f1 = FX.f1;
  const fstr = FX.fstr;
  const f5 = FX.f5;
  const arr = FX.arr;
  const vals = FX.vals;
  let s = 0;
  if (op === 'baseline') {
    for (let j = 0; j < n; j++) { s += 1; }
  } else if (op === 'read_num') {
    for (let j = 0; j < n; j++) { s += objs[j & 15].x; }
  } else if (op === 'read_obj') {
    for (let j = 0; j < n; j++) { SINK[j & 15] = objs[j & 15].child; s += 1; }
  } else if (op === 'write_num') {
    for (let j = 0; j < n; j++) { objs[j & 15].x = 1; s += 1; }
  } else if (op === 'has') {
    for (let j = 0; j < n; j++) { s += Reflect.has(objs[j & 15], 'x') ? 1 : 0; }
  } else if (op === 'call0') {
    for (let j = 0; j < n; j++) { s += f0(); }
  } else if (op === 'call1') {
    for (let j = 0; j < n; j++) { s += f1(j & 15); }
  } else if (op === 'call_str') {
    for (let j = 0; j < n; j++) { s += fstr('hello'); }
  } else if (op === 'call5') {
    for (let j = 0; j < n; j++) { s += f5(j & 15, 1, 1, 1, 1); }
  } else if (op === 'method') {
    for (let j = 0; j < n; j++) { s += objs[j & 15].m(j & 15); }
  } else if (op === 'new_obj') {
    for (let j = 0; j < n; j++) { SINK[j & 15] = new Object(); s += 1; }
  } else if (op === 'new_obj2') {
    for (let j = 0; j < n; j++) { const o: XY = { x: 1, y: 2 }; SINK[j & 15] = o; s += 1; }
  } else if (op === 'new_class') {
    for (let j = 0; j < n; j++) { SINK[j & 15] = new B04Point(1, 2); s += 1; }
  } else if (op === 'new_arr8') {
    for (let j = 0; j < n; j++) { SINK[j & 15] = [0, 1, 2, 3, 4, 5, 6, 7]; s += 1; }
  } else if (op === 'arr_get') {
    for (let j = 0; j < n; j++) { s += arr[j & 15]; }
  } else if (op === 'arr_set') {
    for (let j = 0; j < n; j++) { arr[j & 15] = j & 15; s += 1; }
  } else if (op === 'typecheck') {
    for (let j = 0; j < n; j++) { s += typeof vals[j & 15] === 'number' ? 1 : 0; }
  } else {
    return -1;  // no ArkTS equivalent
  }
  return s;
}

interface OpSpec {
  op: string;
  ts: boolean;      // has a pure ArkTS equivalent
  cached: boolean;  // has a cached Cangjie variant
}

const OPS: OpSpec[] = [
  { op: 'baseline', ts: true, cached: true },
  { op: 'read_num', ts: true, cached: true },
  { op: 'read_obj', ts: true, cached: true },
  { op: 'write_num', ts: true, cached: true },
  { op: 'has', ts: true, cached: true },
  { op: 'call0', ts: true, cached: false },
  { op: 'call1', ts: true, cached: false },
  { op: 'call_str', ts: true, cached: true },
  { op: 'call5', ts: true, cached: false },
  { op: 'method', ts: true, cached: true },
  { op: 'new_obj', ts: true, cached: false },
  { op: 'new_obj2', ts: true, cached: true },
  { op: 'new_class', ts: true, cached: true },
  { op: 'new_arr8', ts: true, cached: true },
  { op: 'arr_get', ts: true, cached: false },
  { op: 'arr_set', ts: true, cached: false },
  { op: 'num_to_js', ts: false, cached: false },
  { op: 'str8_to_js', ts: false, cached: false },
  { op: 'str1000_to_js', ts: false, cached: false },
  { op: 'str8_to_cj', ts: false, cached: false },
  { op: 'str1000_to_cj', ts: false, cached: false },
  { op: 'typecheck', ts: true, cached: false },
];

function logRow(sink: LogSink, op: string, variant: string, n: number, rep: number, ns: number, checksum: number): void {
  // BENCH,b04,op,variant,n,rep,ns_per_op,checksum_per_op
  benchLine(sink, `BENCH,b04,${op},${variant},${n},${rep},${(ns / n).toFixed(2)},${(checksum / n).toFixed(4)}`);
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB04(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const nCj = quick ? 1600 : 16000;       // multiples of 16: every variant sees each object equally often
  const nTs = quick ? 16000 : 1600000;    // ArkTS ops are ~100x cheaper: more iterations for resolution
  let reps = quick ? 2 : 11;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }

  benchLine(sink, 'BENCH,b04,op,variant,n,rep,ns_per_op,checksum_per_op');
  for (const spec of OPS) {
    // warmup
    if (spec.ts) {
      tsOp(spec.op, 16000);
    }
    b04_naive(spec.op, FX, 1600);
    if (spec.cached) {
      b04_cached(spec.op, FX, 1600);
    }
    await yieldToSystem();

    for (let rep = 0; rep < reps; rep++) {
      // rotate the order of the variants each rep
      const order: string[] = ['arkts', 'naive', 'cached'];
      for (let k = 0; k < 3; k++) {
        const variant = order[(k + rep) % 3];
        if (variant === 'arkts' && spec.ts) {
          const t0 = systemDateTime.getTime(true);
          const cs = tsOp(spec.op, nTs);
          const ns = systemDateTime.getTime(true) - t0;
          logRow(sink, spec.op, 'arkts', nTs, rep, ns, cs);
        } else if (variant === 'naive') {
          const r: B04Result = b04_naive(spec.op, FX, nCj);
          logRow(sink, spec.op, 'naive', nCj, rep, r.ns, r.checksum);
        } else if (variant === 'cached' && spec.cached) {
          const r: B04Result = b04_cached(spec.op, FX, nCj);
          logRow(sink, spec.op, 'cached', nCj, rep, r.ns, r.checksum);
        }
        await yieldToSystem();
      }
    }
  }
}
