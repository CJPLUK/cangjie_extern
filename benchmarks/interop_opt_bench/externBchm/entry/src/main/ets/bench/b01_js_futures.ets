import { b01_batch, b01_naive, b01_opt, b01_spin_check, B01Config, B01Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// The JS operation Cangjie workers call on the ArkTS thread. Same for both variants.
function jsOp(x: number): number {
  return x * 2 + 1;
}

type Impl = (fn: (x: number) => number, cfg: B01Config) => Promise<B01Result>;

// sum_{x=0}^{M-1} (2x+1) = M^2, with M = n * t
function expectedChecksum(cfg: B01Config): number {
  const m = cfg.n * cfg.t;
  return m * m;
}

async function runOne(sink: LogSink, variant: string, impl: Impl, cfg: B01Config, rep: number): Promise<void> {
  const r = await impl(jsOp, cfg);
  const ops = cfg.n * cfg.t;
  const ok = r.checksum === expectedChecksum(cfg) ? 1 : 0;
  // BENCH,b01,variant,n,t,w,d,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok
  benchLine(sink, `BENCH,b01,${variant},${cfg.n},${cfg.t},${cfg.w},${cfg.d},${rep},` +
    `${(r.ns / ops).toFixed(1)},${(r.ns / 1e6).toFixed(2)},` +
    `${(r.blockedNs / ops).toFixed(1)},${(r.workedNs / ops).toFixed(1)},${ok}`);
}

interface Variant {
  name: string;
  impl: Impl;
  d: number;
}

// Batching without pipelining: naive vs b01_batch with b ops per posted task. Same t and w as the futures sweep.
async function runBatch(sink: LogSink, quick: boolean, reps: number): Promise<void> {
  const n = quick ? 512 : 2048;  // a multiple of every b
  const threads: number[] = quick ? [1] : [1, 4];
  const works: number[] = quick ? [0] : [0, 10000, 50000];
  const bs: number[] = [1, 2, 4, 8, 16, 32];
  // BENCH,b01b,variant,n,t,w,b,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok
  benchLine(sink, 'BENCH,b01b,variant,n,t,w,b,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok');
  await b01_naive(jsOp, { n: 200, w: 0, d: 0, t: 1 });
  await b01_batch(jsOp, { n: 200, w: 0, d: 0, t: 1, b: 8 });
  const variants: number[] = [0, ...bs];  // 0 = naive
  for (const t of threads) {
    for (const w of works) {
      for (let rep = 0; rep < reps; rep++) {
        for (let k = 0; k < variants.length; k++) {
          const b = variants[(k + rep) % variants.length];
          const cfg: B01Config = { n: n, w: w, d: 0, t: t, b: b === 0 ? 1 : b };
          const r = b === 0 ? await b01_naive(jsOp, cfg) : await b01_batch(jsOp, cfg);
          const ops = n * t;
          const ok = r.checksum === expectedChecksum(cfg) ? 1 : 0;
          benchLine(sink, `BENCH,b01b,${b === 0 ? 'naive' : 'batch'},${n},${t},${w},${cfg.b},${rep},` +
            `${(r.ns / ops).toFixed(1)},${(r.ns / 1e6).toFixed(2)},` +
            `${(r.blockedNs / ops).toFixed(1)},${(r.workedNs / ops).toFixed(1)},${ok}`);
          await yieldToSystem();
        }
      }
    }
  }
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps, 'batch' for the batching sweep
export async function runB01(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const n = quick ? 500 : 2000;
  let reps = quick ? 2 : 7;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  if (opts.indexOf('batch') >= 0) {
    await runBatch(sink, quick, reps);
    return;
  }
  const threads: number[] = quick ? [1] : [1, 4];
  const works: number[] = quick ? [0, 10000] : [0, 2000, 10000, 50000];
  const variants: Variant[] = [
    { name: 'naive', impl: b01_naive, d: 0 },
    { name: 'opt', impl: b01_opt, d: 0 },
    { name: 'opt', impl: b01_opt, d: 1 },
    { name: 'opt', impl: b01_opt, d: 2 },
    { name: 'opt', impl: b01_opt, d: 4 },
    { name: 'opt', impl: b01_opt, d: 8 },
    { name: 'opt', impl: b01_opt, d: 16 },
  ];

  for (const w of works) {
    benchLine(sink, `BENCH,b01_spin,w=${w},avg_ns=${b01_spin_check(w, 2000).toFixed(1)}`);
  }
  benchLine(sink, 'BENCH,b01,variant,n,t,w,d,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok');
  // warmup both paths
  await b01_naive(jsOp, { n: 200, w: 0, d: 0, t: 1 });
  await b01_opt(jsOp, { n: 200, w: 0, d: 4, t: 1 });

  for (const t of threads) {
    for (const w of works) {
      for (let rep = 0; rep < reps; rep++) {
        // rotate the variant order each rep so every variant runs in every position (cancels DVFS drift)
        for (let k = 0; k < variants.length; k++) {
          const v = variants[(k + rep) % variants.length];
          await runOne(sink, v.name, v.impl, { n: n, w: w, d: v.d, t: t }, rep);
        }
      }
    }
  }
}
