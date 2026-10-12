import { systemDateTime } from '@kit.BasicServicesKit';
import { b03_field, b03_field_ck, b03_calls, B03Config, B03Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// ---- Fixture: L0.k0 -> L1.k1 -> ... -> L7.k7 = 42 ----
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

// A path of depth d starts at node L(8-d).
function startNode(d: number): Object {
  if (d === 8) {
    return ROOT;
  } else if (d === 4) {
    return ROOT.k0.k1.k2.k3;
  } else if (d === 2) {
    return ROOT.k0.k1.k2.k3.k4.k5;
  }
  return ROOT.k0.k1.k2.k3.k4.k5.k6;
}

// Getters s<start>_<len>: len levels of access starting at L<start>, done on the ArkTS side.
class B03Fns {
  s0_1 = (o: L0): L1 => o.k0;
  s1_1 = (o: L1): L2 => o.k1;
  s2_1 = (o: L2): L3 => o.k2;
  s3_1 = (o: L3): L4 => o.k3;
  s4_1 = (o: L4): L5 => o.k4;
  s5_1 = (o: L5): L6 => o.k5;
  s6_1 = (o: L6): L7 => o.k6;
  s7_1 = (o: L7): number => o.k7;
  s0_2 = (o: L0): L2 => o.k0.k1;
  s2_2 = (o: L2): L4 => o.k2.k3;
  s4_2 = (o: L4): L6 => o.k4.k5;
  s6_2 = (o: L6): number => o.k6.k7;
  s0_4 = (o: L0): L4 => o.k0.k1.k2.k3;
  s4_4 = (o: L4): number => o.k4.k5.k6.k7;
  s0_8 = (o: L0): number => o.k0.k1.k2.k3.k4.k5.k6.k7;
}

const FNS = new B03Fns();

// ---- Pure ArkTS baseline: the same path reads, no interop. A lower bound: the JIT may hoist loads. ----
function nativeLoop(d: number, n: number): number {
  let s = 0;
  if (d === 8) {
    const o = ROOT;
    for (let i = 0; i < n; i++) { s += o.k0.k1.k2.k3.k4.k5.k6.k7; }
  } else if (d === 4) {
    const o = ROOT.k0.k1.k2.k3;
    for (let i = 0; i < n; i++) { s += o.k4.k5.k6.k7; }
  } else if (d === 2) {
    const o = ROOT.k0.k1.k2.k3.k4.k5;
    for (let i = 0; i < n; i++) { s += o.k6.k7; }
  } else {
    const o = ROOT.k0.k1.k2.k3.k4.k5.k6;
    for (let i = 0; i < n; i++) { s += o.k7; }
  }
  return s;
}

type Impl = (root: Object, fns: Object, cfg: B03Config) => B03Result;

interface Variant {
  name: string;
  impl: Impl;
  k: number;  // levels per call (calls variant only; 0 otherwise)
}

function runOne(sink: LogSink, v: Variant, d: number, n: number, rep: number): void {
  const r = v.impl(startNode(d), FNS, { d: d, k: v.k, n: n });
  const ok = r.checksum === n * LEAF ? 1 : 0;
  // BENCH,b03,variant,d,k,n,rep,ns_per_path,ns_per_level,ok
  benchLine(sink, `BENCH,b03,${v.name},${d},${v.k},${n},${rep},` +
    `${(r.ns / n).toFixed(1)},${(r.ns / n / d).toFixed(1)},${ok}`);
}

function runNative(sink: LogSink, d: number, n: number, rep: number): void {
  const t0 = systemDateTime.getTime(true);
  const s = nativeLoop(d, n);
  const ns = systemDateTime.getTime(true) - t0;
  const ok = s === n * LEAF ? 1 : 0;
  benchLine(sink, `BENCH,b03,arkts_native,${d},0,${n},${rep},${(ns / n).toFixed(1)},${(ns / n / d).toFixed(1)},${ok}`);
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB03(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const n = quick ? 2000 : 20000;
  let reps = quick ? 2 : 15;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const depths: number[] = [1, 2, 4, 8];

  benchLine(sink, 'BENCH,b03,variant,d,k,n,rep,ns_per_path,ns_per_level,ok');
  for (const d of depths) {
    const variants: Variant[] = [
      { name: 'field', impl: b03_field, k: 0 },
      { name: 'field_ck', impl: b03_field_ck, k: 0 },
    ];
    for (const k of [1, 2, 4, 8]) {
      if (k <= d) {
        variants.push({ name: 'calls', impl: b03_calls, k: k });
      }
    }
    // warmup every variant at this depth
    for (const v of variants) {
      v.impl(startNode(d), FNS, { d: d, k: v.k, n: 2000 });
    }
    nativeLoop(d, n);

    for (let rep = 0; rep < reps; rep++) {
      // rotate the variant order each rep
      for (let j = 0; j < variants.length; j++) {
        runOne(sink, variants[(j + rep) % variants.length], d, n, rep);
        await yieldToSystem();
      }
      runNative(sink, d, n, rep);
      await yieldToSystem();
    }
  }
}
