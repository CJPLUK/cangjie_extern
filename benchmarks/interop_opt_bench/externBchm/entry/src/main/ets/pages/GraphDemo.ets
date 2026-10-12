import { systemDateTime } from '@kit.BasicServicesKit';
import { b12_setup, b12_step_async, b12_step_sync, B12Result } from 'libohos_app_cangjie_entry.so';
import { adjacency, GNode, LIB, makeEdges, makeNodes, stepArkTS } from '../bench/b12_graph';

// Live version of benchmark B12: the same graph, the same step functions and the same accessors,
// drawn on a canvas every frame. Drag a node to move (and pin) it.

const COLOR_OF: Record<string, string> = { 'still': '#8a8f98', 'slow': '#2a78d6', 'fast': '#eb6834' };
const MAX_DRAWN = 400;   // nodes and edges drawn per frame (evenly sampled); the simulation always runs on all N
const MIN_GAP_MS = 8;    // idle time left to the UI thread between frames

function nowMs(): number {
  return systemDateTime.getTime(true) / 1e6;
}

@Entry
@Component
struct GraphDemo {
  @State mode: string = 'tactical';
  @State n: number = 500;
  @State status: string = '';
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private nodes: GNode[] = [];
  private edges: number[] = [];
  private adj: number[][] = [];
  private running: boolean = false;
  private ready: boolean = false;
  // view transform of the last drawn frame: screen = world * scale + offset
  private viewScale: number = 1;
  private offX: number = 0;
  private offY: number = 0;
  private dragIdx: number = -1;
  // smoothed statistics
  private stepMs: number = 0;
  private uiMs: number = 0;
  private drawMs: number = 0;
  private frameMs: number = 16;
  private lastTick: number = 0;
  private frameCount: number = 0;

  aboutToAppear(): void {
    this.reset();
  }

  aboutToDisappear(): void {
    this.running = false;
  }

  reset(): void {
    this.nodes = makeNodes(this.n);
    this.edges = makeEdges(this.n);
    this.adj = adjacency(this.n, this.edges);
    b12_setup(this.edges, this.n);
    this.stepMs = 0;
    this.uiMs = 0;
    this.drawMs = 0;
  }

  start(): void {
    if (!this.running && this.ready) {
      this.running = true;
      this.lastTick = nowMs();
      this.tick();
    }
  }

  async tick(): Promise<void> {
    if (!this.running) {
      return;
    }
    let step = 0;
    let ui = 0;
    if (this.mode === 'arkts') {
      const t0 = nowMs();
      stepArkTS(this.nodes, this.adj);
      step = nowMs() - t0;
      ui = step;
    } else {
      let r: B12Result;
      if (this.mode === 'full') {
        r = await b12_step_async({ t: 4, b: 64 }, this.nodes, LIB);
      } else {
        r = b12_step_sync({ tactical: this.mode === 'tactical' }, this.nodes, LIB);
      }
      step = r.ns / 1e6;
      ui = r.uiNs / 1e6;
    }
    const d0 = nowMs();
    this.draw();
    const drawn = nowMs() - d0;
    const now = nowMs();
    const a = 0.1;
    this.stepMs += a * (step - this.stepMs);
    this.uiMs += a * (ui - this.uiMs);
    this.drawMs += a * (drawn - this.drawMs);
    this.frameMs += a * (now - this.lastTick - this.frameMs);
    this.lastTick = now;
    if (++this.frameCount % 10 === 0) {
      const how = this.mode === 'arkts' ? 'pure ArkTS' : this.mode === 'full' ? 'tactical + futures + batching, 4 threads'
        : this.mode;
      this.status = `${how}: step ${this.stepMs.toFixed(1)} ms · UI thread ${this.uiMs.toFixed(1)} ms · ` +
        `draw ${this.drawMs.toFixed(1)} ms · ${(1000 / this.frameMs).toFixed(0)} fps`;
    }
    // leave the UI thread idle for a while every frame, so it can render and handle input
    const gap = Math.max(MIN_GAP_MS, 16 - (nowMs() - now));
    setTimeout(() => {
      this.tick();
    }, gap);
  }

  draw(): void {
    const ctx = this.ctx;
    const w = ctx.width;
    const h = ctx.height;
    let minX = Number.MAX_VALUE;
    let minY = Number.MAX_VALUE;
    let maxX = -Number.MAX_VALUE;
    let maxY = -Number.MAX_VALUE;
    for (const nd of this.nodes) {
      minX = Math.min(minX, nd.x);
      maxX = Math.max(maxX, nd.x);
      minY = Math.min(minY, nd.y);
      maxY = Math.max(maxY, nd.y);
    }
    const s = Math.min((w - 24) / Math.max(maxX - minX, 1), (h - 24) / Math.max(maxY - minY, 1));
    this.viewScale = s;
    this.offX = (w - (maxX - minX) * s) / 2 - minX * s;
    this.offY = (h - (maxY - minY) * s) / 2 - minY * s;
    const ox = this.offX;
    const oy = this.offY;

    ctx.clearRect(0, 0, w, h);
    ctx.strokeStyle = '#d5d9df';
    ctx.lineWidth = 0.5;
    ctx.beginPath();
    const edgeStep = 2 * Math.max(1, Math.ceil(this.edges.length / 2 / MAX_DRAWN));
    for (let k = 0; k + 1 < this.edges.length; k += edgeStep) {
      const p = this.nodes[this.edges[k]];
      const q = this.nodes[this.edges[k + 1]];
      ctx.moveTo(p.x * s + ox, p.y * s + oy);
      ctx.lineTo(q.x * s + ox, q.y * s + oy);
    }
    ctx.stroke();
    const nodeStep = Math.max(1, Math.ceil(this.nodes.length / MAX_DRAWN));
    for (const c of ['still', 'slow', 'fast']) {
      ctx.fillStyle = COLOR_OF[c];
      ctx.beginPath();
      for (let i = 0; i < this.nodes.length; i += nodeStep) {
        const nd = this.nodes[i];
        if (nd.color === c) {
          ctx.rect(nd.x * s + ox - 2, nd.y * s + oy - 2, 4, 4);
        }
      }
      ctx.fill();
    }
    ctx.strokeStyle = '#1d1d1f';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (const nd of this.nodes) {
      if (nd.pinned) {
        ctx.rect(nd.x * s + ox - 4, nd.y * s + oy - 4, 8, 8);
      }
    }
    ctx.stroke();
  }

  onCanvasTouch(e: TouchEvent): void {
    if (e.touches.length === 0) {
      return;
    }
    const tx = e.touches[0].x;
    const ty = e.touches[0].y;
    const wx = (tx - this.offX) / this.viewScale;
    const wy = (ty - this.offY) / this.viewScale;
    if (e.type === TouchType.Down) {
      let best = -1;
      let bestD = 24 * 24;
      for (let i = 0; i < this.nodes.length; i++) {
        const dx = this.nodes[i].x * this.viewScale + this.offX - tx;
        const dy = this.nodes[i].y * this.viewScale + this.offY - ty;
        if (dx * dx + dy * dy < bestD) {
          bestD = dx * dx + dy * dy;
          best = i;
        }
      }
      this.dragIdx = best;
      if (best >= 0) {
        this.nodes[best].pinned = true;
      }
    } else if (e.type === TouchType.Move && this.dragIdx >= 0) {
      this.nodes[this.dragIdx].x = wx;
      this.nodes[this.dragIdx].y = wy;
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      this.dragIdx = -1;
    }
  }

  @Builder
  choice(label: string, active: boolean, onPick: () => void) {
    Button(label)
      .fontSize(13)
      .height(32)
      .backgroundColor(active ? '#2a78d6' : '#9aa0a6')
      .onClick(onPick)
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Button('Back').onClick(() => {
          this.running = false;
          this.getUIContext().getRouter().back();
        })
        Text('Graph demo: benchmark B12, live').fontSize(18).fontWeight(FontWeight.Bold)
      }
      .width('100%')

      Row({ space: 6 }) {
        this.choice('ArkTS', this.mode === 'arkts', () => { this.mode = 'arkts'; })
        this.choice('naive', this.mode === 'naive', () => { this.mode = 'naive'; })
        this.choice('tactical', this.mode === 'tactical', () => { this.mode = 'tactical'; })
        this.choice('full', this.mode === 'full', () => { this.mode = 'full'; })
      }

      Row({ space: 6 }) {
        ForEach([250, 500, 1000, 2000], (k: number) => {
          this.choice(`${k}`, this.n === k, () => {
            this.n = k;
            this.reset();
          })
        }, (k: number) => `${k}`)
        this.choice('unpin', false, () => {
          for (let i = 0; i < this.nodes.length; i++) {
            this.nodes[i].pinned = i % 50 === 0;
          }
        })
      }

      Text(this.status).fontSize(13).fontColor('#5f6368').width('100%')

      Canvas(this.ctx)
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#fafbfc')
        .onReady(() => {
          this.ready = true;
          this.start();
        })
        .onTouch((e: TouchEvent) => {
          this.onCanvasTouch(e);
        })
    }
    .padding(12)
    .height('100%')
    .width('100%')
  }
}
