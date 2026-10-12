import { b06_run, B06Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// ---- Fixture: 1000 objects; price = i % 100, so `price >= limit` selects (100 - limit)% of them ----
class B06Item {
  x: number = 1;
  price: number;

  constructor(price: number) {
    this.price = price;
  }
}

const N = 1000;

function makeItems(): B06Item[] {
  const a: B06Item[] = [];
  for (let i = 0; i < N; i++) {
    a.push(new B06Item(i % 100));
  }
  return a;
}

const ITEMS = makeItems();
const strLen = (s: string): number => s.length;

interface Row {
  prog: string;
  param: number;  // P5: % of elements that escape; otherwise 0
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB06(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const passes = quick ? 2 : 20;
  let reps = quick ? 2 : 15;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const rows: Row[] = [
    { prog: 'p2', param: 0 },
    { prog: 'p5', param: 0 }, { prog: 'p5', param: 10 }, { prog: 'p5', param: 50 }, { prog: 'p5', param: 100 },
    { prog: 'p4', param: 0 },
  ];

  // warmup
  for (const r of rows) {
    for (const v of ['naive', 'opt']) {
      b06_run(r.prog, v, ITEMS, strLen, 100 - r.param, 1);
      await yieldToSystem();
    }
  }

  // BENCH,b06,prog,param,variant,n,passes,rep,ns_per_elem,persisted_per_elem,gc_during,checksum
  benchLine(sink, 'BENCH,b06,prog,param,variant,n,passes,rep,ns_per_elem,persisted_per_elem,gc_during,checksum');
  for (let rep = 0; rep < reps; rep++) {
    for (let k = 0; k < rows.length; k++) {
      const r = rows[(k + rep) % rows.length];
      // alternate which variant goes first
      const order = rep % 2 === 0 ? ['naive', 'opt'] : ['opt', 'naive'];
      for (const v of order) {
        const res: B06Result = b06_run(r.prog, v, ITEMS, strLen, 100 - r.param, passes);
        const elems = N * passes;
        benchLine(sink, `BENCH,b06,${r.prog},${r.param},${v},${N},${passes},${rep},` +
          `${(res.ns / elems).toFixed(1)},${(res.persisted / elems).toFixed(3)},${res.gcDuring},${res.checksum}`);
        await yieldToSystem();
      }
    }
  }
}
