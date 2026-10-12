import { systemDateTime } from '@kit.BasicServicesKit';
import { b07_objects, b07_strings } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// ---- Fixture: arrays of N objects {inner: {v: 1}} ----
class B07Inner {
  v: number = 1;
}

class B07Item {
  inner: B07Inner = new B07Inner();
}

const SIZES: number[] = [10, 100, 1000, 10000];
const TOTAL = 40000;  // elements (or calls) per measurement

function makeItems(n: number): B07Item[] {
  const a: B07Item[] = [];
  for (let i = 0; i < n; i++) {
    a.push(new B07Item());
  }
  return a;
}

const ARRAYS: B07Item[][] = SIZES.map((n: number) => makeItems(n));
const exclaim = (s: string): string => s + '!';

// One measurement: `passes` ArkTS -> Cangjie calls, each processing n elements; timed in ArkTS.
function measure(prog: string, variant: string, idx: number, passes: number): number[] {
  const n = SIZES[idx];
  let checksum = 0;
  const t0 = systemDateTime.getTime(true);
  if (prog === 'objects') {
    const xs = ARRAYS[idx];
    for (let p = 0; p < passes; p++) {
      checksum += b07_objects(variant, xs);
    }
  } else {
    for (let p = 0; p < passes; p++) {
      checksum += b07_strings(variant, exclaim, n);
    }
  }
  const ns = systemDateTime.getTime(true) - t0;
  return [ns, checksum];
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB07(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const total = quick ? 4000 : TOTAL;
  let reps = quick ? 2 : 11;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const progs: string[] = ['objects', 'strings'];

  // warmup
  for (const prog of progs) {
    for (let idx = 0; idx < SIZES.length; idx++) {
      for (const v of ['user', 'generated']) {
        measure(prog, v, idx, 1);
      }
    }
    await yieldToSystem();
  }

  // BENCH,b07,prog,n,variant,passes,rep,ns_per_elem,checksum
  benchLine(sink, 'BENCH,b07,prog,n,variant,passes,rep,ns_per_elem,checksum');
  for (let rep = 0; rep < reps; rep++) {
    for (const prog of progs) {
      for (let idx = 0; idx < SIZES.length; idx++) {
        const n = SIZES[idx];
        const passes = Math.max(1, Math.floor(total / n));
        const order = rep % 2 === 0 ? ['user', 'generated'] : ['generated', 'user'];
        for (const v of order) {
          const r = measure(prog, v, idx, passes);
          benchLine(sink, `BENCH,b07,${prog},${n},${v},${passes},${rep},${(r[0] / (n * passes)).toFixed(1)},${r[1]}`);
          await yieldToSystem();
        }
      }
    }
  }
}
