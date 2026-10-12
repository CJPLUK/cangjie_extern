import { systemDateTime } from '@kit.BasicServicesKit';
import { b09_run, B09Config } from 'libohos_app_cangjie_entry.so';
import { B09ItemTS, B09ResultRow, makeCatalogue, reader, searchArkTS } from '../bench/b09_search';

// Live version of benchmark B09: the same catalogue generator, the same Cangjie program (b09_run)
// and the same pure-ArkTS search, driven by a search box.

const CATALOGUE_SIZE = 2000;
const CATALOGUE: B09ItemTS[] = makeCatalogue(CATALOGUE_SIZE, 40);
const SHOWN = 40;

interface ShownRow {
  key: string;
  title: string;
  brand: string;
  price: number;
  kind: string;
  score: string;
}

function kindRank(k: string): number {
  return k === 'prefix' ? 0 : k === 'match' ? 1 : k === 'fuzzy' ? 2 : 3;
}

@Entry
@Component
struct SearchDemo {
  @State query: string = '';
  @State rows: ShownRow[] = [];
  @State status: string = 'Type to search 2,000 products.';
  @State futures: boolean = true;
  @State coalesce: boolean = true;
  @State scoped: boolean = true;
  @State cache: boolean = true;
  @State workers: number = 4;
  @State pureArkTS: boolean = false;
  @State showControls: boolean = true;  // tap the title to hide the switches and timings (clean screenshots)
  private seq: number = 0;

  async search(): Promise<void> {
    const q = this.query.trim().toLowerCase();
    const my = ++this.seq;
    if (q.length === 0) {
      this.rows = [];
      this.status = 'Type to search 2,000 products.';
      return;
    }
    const results: B09ResultRow[] = [];
    const t0 = systemDateTime.getTime(true);
    let how = '';
    if (this.pureArkTS) {
      searchArkTS(CATALOGUE, results, q);
      how = 'pure ArkTS, single thread';
    } else {
      const cfg: B09Config = {
        futures: this.futures, coalesce: this.coalesce, scoped: this.scoped, cache: this.cache, d: 8, t: this.workers
      };
      const r = await b09_run(cfg, CATALOGUE, results, reader, q);
      const on: string[] = [];
      if (this.futures) { on.push('futures'); }
      if (this.coalesce) { on.push('coalesce'); }
      if (this.scoped) { on.push('scoped'); }
      if (this.cache) { on.push('cache'); }
      how = `Cangjie, ${this.workers} thread${this.workers > 1 ? 's' : ''}, ${on.length > 0 ? on.join(' + ') : 'no optimisations'}` +
        (r.errors > 0 ? `, ${r.errors} errors` : '');
    }
    const ms = (systemDateTime.getTime(true) - t0) / 1e6;
    if (my !== this.seq) {
      return;  // a newer search has started; drop this result
    }
    results.sort((a: B09ResultRow, b: B09ResultRow) => b.score - a.score || kindRank(a.kind) - kindRank(b.kind) || a.id - b.id);
    const matches = results.filter((r: B09ResultRow) => r.kind !== 'none').length;
    this.rows = results.slice(0, SHOWN).map((r: B09ResultRow): ShownRow => ({
      key: `${my}-${r.id}`,
      title: CATALOGUE[r.id].meta.title,
      brand: r.brand,
      price: r.price,
      kind: r.kind,
      score: r.score.toFixed(2)
    }));
    this.status = `${results.length} products scored in ${ms.toFixed(1)} ms (${how}). ${matches} matches.`;
  }

  @Builder
  flag(label: string, isOn: boolean, set: (v: boolean) => void) {
    Row({ space: 4 }) {
      Toggle({ type: ToggleType.Checkbox, isOn: isOn })
        .enabled(!this.pureArkTS)
        .onChange((v: boolean) => {
          set(v);
          this.search();
        })
      Text(label).fontSize(14)
    }
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button('Back').onClick(() => {
          this.getUIContext().getRouter().back();
        })
        Text('Search demo: benchmark B09, live').fontSize(18).fontWeight(FontWeight.Bold)
          .onClick(() => {
            this.showControls = !this.showControls;
          })
      }
      .width('100%')

      TextInput({ placeholder: 'Search products, e.g. wireless', text: this.query })
        .onChange((v: string) => {
          this.query = v;
          this.search();
        })

      if (this.showControls) {
      Row({ space: 12 }) {
        this.flag('futures', this.futures, (v: boolean) => { this.futures = v; })
        this.flag('coalesce', this.coalesce, (v: boolean) => { this.coalesce = v; })
        this.flag('scoped', this.scoped, (v: boolean) => { this.scoped = v; })
        this.flag('cache', this.cache, (v: boolean) => { this.cache = v; })
      }

      Row({ space: 8 }) {
        Button('1 thread')
          .enabled(!this.pureArkTS)
          .backgroundColor(this.workers === 1 ? '#2a78d6' : '#9aa0a6')
          .onClick(() => {
            this.workers = 1;
            this.search();
          })
        Button('4 threads')
          .enabled(!this.pureArkTS)
          .backgroundColor(this.workers === 4 ? '#2a78d6' : '#9aa0a6')
          .onClick(() => {
            this.workers = 4;
            this.search();
          })
        Row({ space: 4 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.pureArkTS })
            .onChange((v: boolean) => {
              this.pureArkTS = v;
              this.search();
            })
          Text('pure ArkTS').fontSize(14)
        }
      }

      Text(this.status).fontSize(13).fontColor('#5f6368').width('100%')
      }

      List({ space: 2 }) {
        ForEach(this.rows, (r: ShownRow) => {
          ListItem() {
            Row({ space: 8 }) {
              Column() {
                Text(r.title).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${r.brand} · ${r.price}`).fontSize(12).fontColor('#5f6368')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(r.kind).fontSize(12).fontColor('#5f6368')
              Text(r.score).fontSize(14).fontWeight(FontWeight.Medium)
            }
            .padding({ top: 6, bottom: 6 })
            .width('100%')
          }
        }, (r: ShownRow) => r.key)
      }
      .layoutWeight(1)
      .divider({ strokeWidth: 1, color: '#e6e6e6' })
    }
    .padding(12)
    .height('100%')
    .width('100%')
  }
}
