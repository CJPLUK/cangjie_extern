import { hilog } from '@kit.PerformanceAnalysisKit';

// Every result line goes to hilog with tag BENCH (collected over hdc) and to the on-screen log.
export type LogSink = (line: string) => void;

export function benchLine(sink: LogSink, line: string): void {
  hilog.info(0x0000, 'BENCH', '%{public}s', line);
  sink(line);
}

// Synchronous benchmarks run on the UI thread: yield with a real delay between measurements so the
// system's own main-thread tasks (e.g. the THREAD_BLOCK watchdog heartbeat) get to run.
export function yieldToSystem(): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, 5));
}
