import { b05_run, b05_force_gc, B05Result, B05GcResult } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
}

interface Row {
  op: string;
  cond: string;  // cold / spin / warm / debt, see b05Run in b05_string_anatomy.cj
}

const OPS: string[] = [
  'baseline',
  // raw C primitives
  'raw_ffi_floor', 'raw_utf8_0', 'raw_utf8_8', 'raw_utf8_1000', 'raw_object', 'raw_is_heap',
  'raw_global_object', 'raw_global_str8', 'raw_dispose_sync', 'raw_dispose_async',
  // Cangjie-side steps
  'cj_acquire_release', 'cj_alloc_plain', 'cj_alloc_fin',
  // whole API calls
  'api_object', 'api_string0', 'api_string8', 'api_string1000', 'api_string8_u16',
  'api_scoped8', 'api_scoped1000', 'api_object_keep', 'api_string8_keep',
];

// rows measured under every condition (all others: 'warm' only)
const LADDER_OPS: string[] = [
  'baseline', 
  'raw_utf8_8', 'raw_object', 'cj_alloc_fin', 'api_object', 'api_string8', 'api_scoped8', 'api_string8_keep',
];

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps,
//       'steady' to measure every op back to back without forced GC (condition 'steady')
export async function runB05(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const steady = opts.indexOf('steady') >= 0;
  const n = quick ? 1600 : 16000;
  let reps = quick ? 1 : 7;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const rows: Row[] = [];
  for (const op of OPS) {
    rows.push({ op: op, cond: steady ? 'steady' : 'warm' });
  }
  if (!steady) {
    for (const op of LADDER_OPS) {
      for (const cond of ['cold', 'spin', 'debt']) {
        rows.push({ op: op, cond: cond });
      }
    }
  }

  // warmup
  let via = '';
  for (const r of rows) {
    via = b05_run(r.op, 'warm', 1600).via;
    await yieldToSystem();
  }
  benchLine(sink, `BENCH,b05_info,symbols_via,${via}`);

  benchLine(sink, 'BENCH,b05,op,cond,n,rep,ns_per_op,gc_ran,gc_attempts,gc_wait_ms,gc_during,checksum_per_op');
  for (let rep = 0; rep < reps; rep++) {
    for (let k = 0; k < rows.length; k++) {
      // rotate the row order each rep
      const r = rows[(k + rep * 3) % rows.length];
      let g: B05GcResult = { ran: 0, attempts: 0, waitedMs: 0 };
      if (!steady) {
        g = b05_force_gc();
        await sleepMs(30);  // let finalizers run and the ArkTS-side AsyncDisposer drain
      }
      const res: B05Result = b05_run(r.op, r.cond, n);
      benchLine(sink, `BENCH,b05,${r.op},${r.cond},${n},${rep},${(res.ns / n).toFixed(2)},` +
        `${g.ran},${g.attempts},${g.waitedMs.toFixed(1)},${res.gcDuring},${(res.checksum / n).toFixed(4)}`);
      await yieldToSystem();
    }
  }
}
