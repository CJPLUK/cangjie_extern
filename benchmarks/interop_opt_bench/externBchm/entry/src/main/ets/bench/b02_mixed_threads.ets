import { b02_naive, b02_opt, B02Config, B01Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink } from './Log';

// Same JS operation as B01.
function jsOp(x: number): number {
  return x * 2 + 1;
}

type Impl = (fn: (x: number) => number, cfg: B02Config) => Promise<B01Result>;

interface Variant {
  name: string;
  impl: Impl;
  d: number;
}

async function runOne(sink: LogSink, v: Variant, cfg: B02Config, rep: number): Promise<void> {
  const r = await v.impl(jsOp, cfg);
  const ops = cfg.n * cfg.t;
  const ok = r.checksum === ops * ops ? 1 : 0;  // sum_{x<ops} (2x+1) = ops^2
  // BENCH,b02,variant,n,t,w,d,o,c,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok
  benchLine(sink, `BENCH,b02,${v.name},${cfg.n},${cfg.t},${cfg.w},${cfg.d},${cfg.o},${cfg.c},${rep},` +
    `${(r.ns / ops).toFixed(1)},${(r.ns / 1e6).toFixed(2)},` +
    `${(r.blockedNs / ops).toFixed(1)},${(r.workedNs / ops).toFixed(1)},${ok}`);
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB02(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const n = quick ? 500 : 2000;
  let reps = quick ? 2 : 8;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const threads: number[] = quick ? [1] : [1, 4];
  const works: number[] = quick ? [0] : [0, 10000];
  const offs: number[] = quick ? [0, 0.5, 1] : [0, 0.25, 0.5, 0.75, 0.9, 1];
  const bursts: number[] = quick ? [1] : [1, 16];
  const variants: Variant[] = [
    { name: 'naive', impl: b02_naive, d: 0 },
    { name: 'opt', impl: b02_opt, d: 4 },
  ];

  benchLine(sink, 'BENCH,b02,variant,n,t,w,d,o,c,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok');
  // warmup both paths, mixed
  await b02_naive(jsOp, { n: 200, w: 0, d: 0, t: 1, o: 0.5, c: 4 });
  await b02_opt(jsOp, { n: 200, w: 0, d: 4, t: 1, o: 0.5, c: 4 });

  for (const t of threads) {
    for (const w of works) {
      for (const c of bursts) {
        for (const o of offs) {
          for (let rep = 0; rep < reps; rep++) {
            // alternate which variant goes first
            for (let k = 0; k < variants.length; k++) {
              const v = variants[(k + rep) % variants.length];
              await runOne(sink, v, { n: n, w: w, d: v.d, t: t, o: o, c: c }, rep);
            }
          }
        }
      }
    }
  }
}
