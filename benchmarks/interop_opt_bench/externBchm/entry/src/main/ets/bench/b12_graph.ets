import { b12_check_costs, b12_setup, b12_step_async, b12_step_sync, B12Result } from 'libohos_app_cangjie_entry.so';
import { systemDateTime } from '@kit.BasicServicesKit';
import { benchLine, LogSink, yieldToSystem } from './Log';
import { process } from '@kit.ArkTS';

// ---- The UI's data: graph nodes the UI is bound to ----
export class GNode {
  x: number;
  y: number;
  pinned: boolean;
  color: string = 'still';
  label: string;

  constructor(x: number, y: number, pinned: boolean, label: string) {
    this.x = x;
    this.y = y;
    this.pinned = pinned;
    this.label = label;
  }
}

// Positions live on a 1/1024 grid (every configuration snaps after each step), so the optimised configurations can
// pass a node's values across the boundary as one exactly packed integer (a mock of a multi-value return).
const Q = 1024;
const OFF = 16777216;    // 2^24: fixed-point offset, coordinates in [-16384, 16384)
const SHIFT = 33554432;  // 2^25: bits per coordinate
const COLORS: string[] = ['still', 'slow', 'fast'];

export function snap(v: number): number {
  return Math.floor(v * Q + 0.5) / Q;
}

// Deterministic graph: N nodes in a 1000 x 1000 square, every 50th node pinned (node 0 is the one the user drags);
// edges: a ring plus one chord per node.
export function makeNodes(n: number): GNode[] {
  let seed = 4242;
  const rnd = (): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return (seed % 100000) / 100;
  };
  const nodes: GNode[] = [];
  for (let i = 0; i < n; i++) {
    nodes.push(new GNode(snap(rnd()), snap(rnd()), i % 50 === 0, `node ${i}`));
  }
  return nodes;
}

export function makeEdges(n: number): number[] {
  const e: number[] = [];
  for (let i = 0; i < n; i++) {
    e.push(i, (i + 1) % n);
    const j = (i * 7 + 3) % n;
    if (j !== i) {
      e.push(i, j);
    }
  }
  return e;
}

// Generated accessors used by both optimised configurations: one call per node for the reads and one for the writes,
// each carrying all values as one packed integer (mock of a multi-value return / multi-value argument).
//   read:  ((x * 1024 + 2^24) * 2^25 + (y * 1024 + 2^24)) * 2 + pinned          (51 bits)
//   write: ((x * 1024 + 2^24) * 2^25 + (y * 1024 + 2^24)) * 4 + colour index    (52 bits)
class B12Lib {
  readNode = (nodes: GNode[], i: number): number => {
    const n = nodes[i];
    const xq = Math.floor(n.x * Q + 0.5) + OFF;
    const yq = Math.floor(n.y * Q + 0.5) + OFF;
    return (xq * SHIFT + yq) * 2 + (n.pinned ? 1 : 0);
  };
  writeNode = (nodes: GNode[], i: number, p: number): void => {
    const n = nodes[i];
    const c = p % 4;
    const r = (p - c) / 4;
    const yq = r % SHIFT;
    const xq = (r - yq) / SHIFT;
    n.x = (xq - OFF) / Q;
    n.y = (yq - OFF) / Q;
    n.color = COLORS[c];
  };
}
export const LIB = new B12Lib();

// ---- The same step in pure ArkTS (same arithmetic, same order) ----
const K_REP = 500;
const K_SPRING = 0.05;
const L0 = 30;
const STEP = 0.1;
const MAX_MOVE = 5;

function clamp(v: number): number {
  return v > MAX_MOVE ? MAX_MOVE : v < -MAX_MOVE ? -MAX_MOVE : v;
}

export function stepArkTS(nodes: GNode[], adj: number[][]): void {
  const n = nodes.length;
  const x: number[] = [];
  const y: number[] = [];
  for (const nd of nodes) {
    x.push(nd.x);
    y.push(nd.y);
  }
  for (let i = 0; i < n; i++) {
    const nd = nodes[i];
    if (nd.pinned) {
      nd.color = COLORS[0];
      continue;
    }
    const xi = x[i];
    const yi = y[i];
    let ax = 0;
    let ay = 0;
    for (let j = 0; j < n; j++) {
      if (j !== i) {
        const dx = xi - x[j];
        const dy = yi - y[j];
        const f = K_REP / (dx * dx + dy * dy + 0.01);
        ax += dx * f;
        ay += dy * f;
      }
    }
    for (const j of adj[i]) {
      const dx = x[j] - xi;
      const dy = y[j] - yi;
      const d = Math.sqrt(dx * dx + dy * dy + 0.01);
      const f = K_SPRING * (d - L0) / d;
      ax += dx * f;
      ay += dy * f;
    }
    const mx = clamp(ax * STEP);
    const my = clamp(ay * STEP);
    nd.x = snap(xi + mx);
    nd.y = snap(yi + my);
    const speed = Math.abs(mx) + Math.abs(my);
    nd.color = COLORS[speed < 0.5 ? 0 : speed < 2 ? 1 : 2];
  }
}

export function adjacency(n: number, edges: number[]): number[][] {
  const adj: number[][] = [];
  for (let i = 0; i < n; i++) {
    adj.push([]);
  }
  for (let k = 0; k + 1 < edges.length; k += 2) {
    adj[edges[k]].push(edges[k + 1]);
    adj[edges[k + 1]].push(edges[k]);
  }
  return adj;
}

// One frame of the given configuration. Returns [ms frame, ms UI thread, ms compute].
async function frame(variant: string, nodes: GNode[], adj: number[][]): Promise<number[]> {
  if (variant === 'arkts') {
    const t0 = systemDateTime.getTime(true);
    stepArkTS(nodes, adj);
    const ms = (systemDateTime.getTime(true) - t0) / 1e6;
    return [ms, ms, ms];
  }
  let r: B12Result;
  if (variant.startsWith('full')) {
    // 'full' = 4 compute threads; 'full_tK' = K compute threads
    const t = variant.startsWith('full_t') ? Number.parseInt(variant.substring(6)) : 4;
    r = await b12_step_async({ t: t, b: 64 }, nodes, LIB);
  } else {
    r = b12_step_sync({ tactical: variant === 'tactical' }, nodes, LIB);
  }
  return [r.ns / 1e6, r.uiNs / 1e6, r.computeNs / 1e6];
}

// Deferred costs: FRAMES frames back to back, separated only by a zero-delay timer, so that work queued on the
// ArkTS thread by earlier frames (e.g. disposal of persistent references) runs between frames. Per frame:
// step time, wall time (step + whatever else the ArkTS thread ran), and process CPU time including a drain
// period after the last frame (garbage collection and finalizers on any thread).
async function deferred(sink: LogSink, reps: number): Promise<void> {
  const FRAMES = 30;
  const DRAIN_MS = 300;
  const variants: string[] = ['naive', 'tactical'];
  benchLine(sink, 'BENCH,b12d,N,variant,rep,frames,ms_step,ms_wall,ms_cpu');
  for (let rep = 0; rep < reps; rep++) {
    for (const n of [1000, 2000]) {
      const edges = makeEdges(n);
      const adj = adjacency(n, edges);
      b12_setup(edges, n);
      for (let k = 0; k < variants.length; k++) {
        const v = variants[(k + rep) % variants.length];
        const nodes = makeNodes(n);
        await frame(v, nodes, adj);          // warm-up frame, not counted
        await yieldToSystem();
        await new Promise<void>((res) => setTimeout(res, DRAIN_MS));
        let step = 0;
        const cpu0 = process.getPastCpuTime();
        const w0 = systemDateTime.getTime(true);
        for (let f = 0; f < FRAMES; f++) {
          nodes[0].x += 0.5;
          step += (await frame(v, nodes, adj))[0];
          await new Promise<void>((res) => setTimeout(res, 0));
        }
        const wall = (systemDateTime.getTime(true) - w0) / 1e6;
        await new Promise<void>((res) => setTimeout(res, DRAIN_MS));
        const cpu = process.getPastCpuTime() - cpu0 - 0;
        benchLine(sink, `BENCH,b12d,${n},${v},${rep},${FRAMES},${(step / FRAMES).toFixed(3)},` +
          `${(wall / FRAMES).toFixed(3)},${(cpu / FRAMES).toFixed(3)}`);
        await yieldToSystem();
      }
    }
  }
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps, 'deferred' for the deferred-cost run
export async function runB12(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  let reps = quick ? 1 : 8;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  if (opts.indexOf('checks') >= 0) {
    // ns per call of the library's checks, on the accessor's result shape [x, y, pinned]
    benchLine(sink, 'BENCH,b12k,rep,isNumber,isBoolean,size,toNumber,toBoolean,getElementToNumber');
    const arr: Object[] = [1.5, 2.5, true];
    b12_check_costs(arr, 20000);  // warmup
    for (let rep = 0; rep < reps; rep++) {
      const c = b12_check_costs(arr, 200000);
      benchLine(sink, `BENCH,b12k,${rep},${c.isNumber.toFixed(1)},${c.isBoolean.toFixed(1)},${c.size.toFixed(1)},` +
        `${c.toNumber.toFixed(1)},${c.toBoolean.toFixed(1)},${c.getElementToNumber.toFixed(1)}`);
      await yieldToSystem();
    }
    return;
  }
  if (opts.indexOf('deferred') >= 0) {
    await deferred(sink, reps);
    return;
  }
  const threadsProbe = opts.indexOf('threads') >= 0;
  const sizes: number[] = quick ? [250] : threadsProbe ? [1000] : [250, 500, 1000, 2000];
  const frames = quick ? 3 : 6;
  const variants: string[] = threadsProbe ? ['tactical', 'full_t1', 'full_t2', 'full_t4'] : ['arkts', 'naive', 'tactical', 'full'];
  let seed = 9;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };

  // BENCH,b12,N,variant,rep,frame,ms_frame,ms_ui,ms_compute   and after each run
  // BENCH,b12sum,N,variant,rep,checksum
  benchLine(sink, 'BENCH,b12,N,variant,rep,frame,ms_frame,ms_ui,ms_compute');
  for (let rep = 0; rep < reps; rep++) {
    for (const n of sizes) {
      const edges = makeEdges(n);
      const adj = adjacency(n, edges);
      b12_setup(edges, n);
      const order: number[] = [0, 1, 2, 3];
      for (let k = order.length - 1; k > 0; k--) {
        const j = rnd(k + 1);
        const tmp = order[k];
        order[k] = order[j];
        order[j] = tmp;
      }
      for (const k of order) {
        const v = variants[k];
        const nodes = makeNodes(n);
        for (let f = 0; f < frames; f++) {
          nodes[0].x += 0.5;  // the user drags node 0
          const t = await frame(v, nodes, adj);
          benchLine(sink, `BENCH,b12,${n},${v},${rep},${f},${t[0].toFixed(3)},${t[1].toFixed(3)},${t[2].toFixed(3)}`);
          await yieldToSystem();
        }
        let s = 0;
        for (const nd of nodes) {
          s += nd.x + nd.y + (nd.color === 'fast' ? 1 : nd.color === 'slow' ? 2 : 3);
        }
        benchLine(sink, `BENCH,b12sum,${n},${v},${rep},${s.toFixed(6)}`);
      }
    }
  }
}
