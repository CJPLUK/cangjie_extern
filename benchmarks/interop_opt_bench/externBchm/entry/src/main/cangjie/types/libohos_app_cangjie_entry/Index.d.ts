export declare function testCJ(s: string): string

// ---- B01: JS-thread futures ----
export interface B01Config {
  n: number;  // ops per worker thread
  w: number;  // ns of Cangjie work per op
  d: number;  // lookahead: result consumed d ops after issue (opt only)
  t: number;  // Cangjie worker threads
  b?: number; // ops per posted task (batch only; default 1)
}
export interface B01Result {
  ns: number;        // wall time measured in Cangjie, all workers
  checksum: number;  // sum of fn(x) over all ops
  blockedNs: number; // summed over workers: time blocked in future.get()
  workedNs: number;  // summed over workers: time spent in the Cangjie work loop
}
export declare function b01_naive(fn: (x: number) => number, cfg: B01Config): Promise<B01Result>
// diagnostic: avg wall ns of spinNs(w), n calls, no interop
export declare function b01_spin_check(w: number, n: number): number
export declare function b01_opt(fn: (x: number) => number, cfg: B01Config): Promise<B01Result>;
export declare function b01_batch(fn: (x: number) => number, cfg: B01Config): Promise<B01Result>;

// ---- B02: B01 with a share of the ops issued from the ArkTS thread ----
export interface B02Config {
  n: number;  // total ops = n * t
  w: number;  // ns of Cangjie work per op
  d: number;  // lookahead for off-main ops (opt only)
  t: number;  // Cangjie worker threads
  o: number;  // fraction of ops issued off the main thread: 0 = all on ArkTS thread, 1 = all on workers
  c: number;  // main-thread ops per burst (one JS task per burst)
}
export declare function b02_naive(fn: (x: number) => number, cfg: B02Config): Promise<B01Result>
export declare function b02_opt(fn: (x: number) => number, cfg: B02Config): Promise<B01Result>

// ---- B03: coalescing accesses to one ArkTS object graph (synchronous, on the ArkTS thread) ----
export interface B03Config {
  d: number;  // path depth (levels of property access)
  k: number;  // levels per getter call (b03_calls only)
  n: number;  // path reads
}
export interface B03Result {
  ns: number;        // time of the whole loop, measured in Cangjie
  checksum: number;  // sum of the leaf values read
}
export declare function b03_field(root: Object, fns: Object, cfg: B03Config): B03Result
export declare function b03_field_ck(root: Object, fns: Object, cfg: B03Config): B03Result
export declare function b03_calls(root: Object, fns: Object, cfg: B03Config): B03Result

// ---- B04: per-operation interop cost (synchronous, on the ArkTS thread) ----
export interface B04Result {
  ns: number;        // time of the whole loop, measured in Cangjie; -1 = variant not applicable
  checksum: number;
}
export declare function b04_naive(op: string, fx: Object, n: number): B04Result
export declare function b04_cached(op: string, fx: Object, n: number): B04Result

// ---- B05: anatomy of runtime.string(s) (synchronous, on the ArkTS thread) ----
export interface B05Result {
  ns: number;        // time of the timed loop only
  checksum: number;
  gcDuring: number;  // Cangjie GCs that happened during the timed loop
  via: string;       // how the ARKTS_* symbols were located
}
export interface B05GcResult {
  ran: number;       // 1 if the forced GC was observed (GC count increased)
  attempts: number;
  waitedMs: number;
}
export declare function b05_run(op: string, cond: string, n: number): B05Result
export declare function b05_force_gc(): B05GcResult

// ---- B06: do not persist short-lived values (synchronous, on the ArkTS thread) ----
export interface B06Result {
  ns: number;         // time of the timed loop
  checksum: number;
  persisted: number;  // persistent references created in the timed loop
  gcDuring: number;   // Cangjie GCs during the timed loop
}
export declare function b06_run(prog: string, variant: string, arr: Object[], f: (s: string) => number,
  limit: number, passes: number): B06Result

// ---- B07: temporaries bound as persistent references (user) vs scoped values (generated) ----
export declare function b07_objects(variant: string, xs: Object[]): number
export declare function b07_strings(variant: string, f: (s: string) => string, n: number): number

// ---- B08: string caching (names; names + values) ----
export interface B08Result {
  ns: number;  // time of the timed loop
}
export declare function b08_export(variant: string, list: Object[], n: number, u: number): B08Result

// ---- B09: search-as-you-type with all optimisations behind switches ----
export interface B09Config {
  futures: boolean;   // reads issued d items ahead, writes waited for at the end
  coalesce: boolean;  // one ArkTS reader call per item instead of 7 property/element reads
  scoped: boolean;    // temporaries and written string values as scoped JSValues
  cache: boolean;     // names created once; string values reused through a String -> JSString cache
  d: number;          // lookahead when futures is on
  t: number;          // worker threads
  b?: number;         // items per posted task (default 1)
}
export interface B09Result {
  ns: number;      // wall time of the whole search, all workers
  errors: number;  // exceptions inside posted tasks (should be 0)
}
export declare function b09_run(cfg: B09Config, list: Object[], results: Object[],
  reader: (list: Object[], i: number) => Object[], query: string): Promise<B09Result>

export interface B11Config {
  work: string;     // path | read | write
  variant: string;  // naive | stub | interp | interp_cached
  d: number;        // path depth (path only)
  n: number;        // repetitions
}
export interface B11Result {
  ns: number;
  checksum: number;
}
export declare function b11_run(cfg: B11Config, fixture: Object, lib: Object): B11Result;
export declare function b11_probe(): string;

export interface B12Result {
  ns: number;         // wall time of the step
  uiNs: number;       // time the ArkTS thread spent in the step
  computeNs: number;  // time of the force computation
}
export declare function b12_setup(edges: number[], n: number): number;
export declare function b12_step_sync(cfg: { tactical: boolean }, nodes: Object[], lib: Object): B12Result;
export declare function b12_step_async(cfg: { t: number, b: number }, nodes: Object[], lib: Object): Promise<B12Result>;
export interface B12CheckCosts {
  isNumber: number; isBoolean: number; size: number; toNumber: number; toBoolean: number;
  getElementToNumber: number; sink: number;
}
export declare function b12_check_costs(arr: Object[], n: number): B12CheckCosts;
