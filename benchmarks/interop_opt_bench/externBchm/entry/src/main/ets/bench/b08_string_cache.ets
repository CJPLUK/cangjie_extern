import { b08_export, B08Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// The ArkTS side of the view model: an array the records are pushed into.
class B08Row {
  id: number = 0;
  name: string = '';
  status: string = '';
  category: string = '';
}

// Checksum over what arrived, independent of how it was produced.
function checksum(list: B08Row[]): number {
  let s = 0;
  for (const r of list) {
    s += r.id + r.name.length * 3 + r.status.length * 5 + r.category.length * 7;
  }
  return s;
}

const N = 10000;
const U_VALUES: number[] = [1, 10, 100, 1000, 10000];

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB08(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  let reps = quick ? 2 : 11;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const variants: string[] = ['naive', 'names', 'names+values'];
  const list: B08Row[] = [];

  // warmup
  for (const v of variants) {
    b08_export(v, list, N, 100);
    list.length = 0;
    await yieldToSystem();
  }

  // BENCH,b08,u,variant,n,rep,ns_per_record,checksum
  benchLine(sink, 'BENCH,b08,u,variant,n,rep,ns_per_record,checksum');
  for (let rep = 0; rep < reps; rep++) {
    for (const u of U_VALUES) {
      for (let k = 0; k < variants.length; k++) {
        const v = variants[(k + rep) % variants.length];
        const r: B08Result = b08_export(v, list, N, u);
        const cs = checksum(list);
        const ok = list.length === N;
        list.length = 0;
        benchLine(sink, `BENCH,b08,${u},${v},${N},${rep},${(r.ns / N).toFixed(1)},${ok ? cs : -1}`);
        await yieldToSystem();
      }
    }
  }
}
