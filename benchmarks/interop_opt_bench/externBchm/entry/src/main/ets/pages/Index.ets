import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { runB01 } from '../bench/b01_js_futures';
import { runB02 } from '../bench/b02_mixed_threads';
import { runB03 } from '../bench/b03_object_access';
import { runB04 } from '../bench/b04_op_costs';
import { runB05 } from '../bench/b05_string_anatomy';
import { runB06 } from '../bench/b06_persist';
import { runB07 } from '../bench/b07_temporaries';
import { runB08 } from '../bench/b08_string_cache';
import { runB09 } from '../bench/b09_search';
import { runB11 } from '../bench/b11_dsl';
import { runB12 } from '../bench/b12_graph';

interface BenchEntry {
  name: string;
  // opts: extra spec words, e.g. ['quick'] or ['reps21']
  run: (sink: (line: string) => void, opts: string[]) => Promise<void>;
}

const BENCHES: BenchEntry[] = [
  { name: 'b01', run: runB01 },
  { name: 'b02', run: runB02 },
  { name: 'b03', run: runB03 },
  { name: 'b04', run: runB04 },
  { name: 'b05', run: runB05 },
  { name: 'b06', run: runB06 },
  { name: 'b07', run: runB07 },
  { name: 'b08', run: runB08 },
  { name: 'b09', run: runB09 },
  { name: 'b11', run: runB11 },
  { name: 'b12', run: runB12 },
];

@Entry
@Component
struct Index {
  @State lines: string[] = [];
  @State running: boolean = false;
  @StorageLink('autorun') autorun: string = '';

  aboutToAppear(): void {
    // launched via: aa start ... --ps autorun b01[,quick]
    if (this.autorun.length > 0) {
      const spec = this.autorun;
      this.autorun = '';
      setTimeout(() => {
        this.runSpec(spec);
      }, 1500);
    }
  }

  async runSpec(spec: string): Promise<void> {
    const parts = spec.split(',');
    const names = parts.filter((p: string) => p === 'all' || BENCHES.some((b: BenchEntry) => b.name === p));
    const opts = parts.filter((p: string) => names.indexOf(p) < 0);
    this.running = true;
    this.lines = [];
    const sink = (line: string) => {
      this.lines.push(line);
    };
    for (const b of BENCHES) {
      if (names.indexOf('all') >= 0 || names.indexOf(b.name) >= 0) {
        try {
          await b.run(sink, opts);
        } catch (e) {
          sink(`BENCH_ERROR,${b.name},${JSON.stringify(e)}`);
          hilog.error(0x0000, 'BENCH', 'BENCH_ERROR,%{public}s,%{public}s', b.name, JSON.stringify(e));
        }
      }
    }
    // hilog rate-limits bursts, so the authoritative copy of the results is a file in the sandbox
    this.saveResults();
    hilog.info(0x0000, 'BENCH', '%{public}s', 'BENCH_DONE');
    sink('BENCH_DONE');
    this.running = false;
  }

  saveResults(): void {
    const path = this.getUIContext().getHostContext()!.filesDir + '/results.csv';
    const f = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    const body = this.lines.map((l: string) => l.startsWith('BENCH,') ? l.substring(6) : l).join('\n') + '\n';
    fileIo.writeSync(f.fd, body);
    fileIo.closeSync(f);
  }

  build() {
    Column({ space: 8 }) {
      Button('Search demo (B09, live)').onClick(() => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/SearchDemo' });
      })
      Button('Graph demo (B12, live)').onClick(() => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/GraphDemo' });
      })
      Row({ space: 8 }) {
        ForEach(BENCHES, (b: BenchEntry) => {
          Button(b.name).enabled(!this.running).onClick(() => {
            this.runSpec(b.name);
          })
          Button(`${b.name} quick`).enabled(!this.running).onClick(() => {
            this.runSpec(`${b.name},quick`);
          })
        }, (b: BenchEntry) => b.name)
      }
      Text(this.running ? 'running…' : 'idle').fontSize(14)
      List() {
        ForEach(this.lines, (l: string, i: number) => {
          ListItem() {
            Text(l).fontSize(10).fontFamily('monospace')
          }
        }, (l: string, i: number) => `${i}`)
      }
      .layoutWeight(1)
    }
    .padding(12)
    .height('100%')
    .width('100%')
  }
}
