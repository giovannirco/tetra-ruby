// Rolling client-side view of the live events: rate, error ratio,
// latency percentiles (server-measured) and per-operation counts.

const WINDOW_S = 60;

export class Stats {
  constructor() {
    this.events = [];
    this.total = 0;
  }

  add(e) {
    this.total++;
    this.events.push({ at: Date.now(), op: e.operation, ok: e.status < 400, ms: Number(e.duration_ms) || 0 });
  }

  snapshot(ops) {
    const now = Date.now();
    const cutoff = now - WINDOW_S * 1000;
    while (this.events.length && this.events[0].at < cutoff) this.events.shift();

    const buckets = new Array(WINDOW_S).fill(0);
    const perOp = new Map(ops.map((op) => [op.name, { ok: 0, err: 0 }]));
    const durations = [];
    let errors = 0;
    let recent = 0;
    for (const e of this.events) {
      const age = Math.floor((now - e.at) / 1000);
      buckets[WINDOW_S - 1 - Math.min(age, WINDOW_S - 1)]++;
      if (now - e.at <= 5000) recent++;
      if (!e.ok) errors++;
      durations.push(e.ms);
      const c = perOp.get(e.op);
      if (c) c[e.ok ? 'ok' : 'err']++;
    }
    durations.sort((a, b) => a - b);
    const pct = (p) => (durations.length ? durations[Math.min(durations.length - 1, Math.floor(p * durations.length))] : null);

    return {
      rps: recent / 5,
      errorRate: this.events.length ? errors / this.events.length : 0,
      total: this.total,
      p50: pct(0.5),
      p95: pct(0.95),
      p99: pct(0.99),
      perOp,
      buckets,
    };
  }
}
