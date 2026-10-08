// Entry point: loads the operation catalogue, then wires the scene,
// the HUD, the live event stream and the traffic generator together.

import { calculate, getJSON, isReady, requestURL, stream } from './api.js';
import * as hud from './hud.js';
import { Stats } from './stats.js';
import { Traffic } from './load.js';

const OP_COLORS = { sum: '#22d3ee', sub: '#f472b6', mul: '#fbbf24', div: '#a3e635' };

// Operations added later get a stable color derived from their name.
function colorFor(name) {
  if (OP_COLORS[name]) return OP_COLORS[name];
  let h = 0;
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) % 360;
  return `hsl(${h} 85% 62%)`;
}

async function loadScene(canvas, labels) {
  try {
    const { createScene } = await import('./scene.js');
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    return createScene(canvas, labels, { reducedMotion });
  } catch (err) {
    console.error('scene unavailable:', err);
    return null;
  }
}

async function main() {
  const catalogue = await getJSON('/api');
  const ops = catalogue.operations.map((op) => ({ ...op, color: colorFor(op.name) }));
  const byName = new Map(ops.map((op) => [op.name, op]));

  const scene = await loadScene(document.getElementById('scene'), document.getElementById('labels'));
  if (scene) scene.setOperations(ops);
  else hud.toast('WebGL is unavailable here: the API and telemetry still work.');

  getJSON('/version').then(hud.setVersion).catch(() => {});

  const stats = new Stats();
  const record = (e) => {
    stats.add(e);
    scene?.emit(e);
    hud.logEvent(e, byName.get(e.operation)?.color || 'var(--text)');
  };

  // Server-pushed events cover every client of this pod. If the stream is
  // down, fall back to drawing this browser's own requests.
  const live = stream(record, (state) => hud.setChip('chip-live', state, state === 'on' ? 'live stream' : 'stream'));
  const onLocalResult = (op, a, b, res) => {
    if (live.isOpen()) return;
    record({
      operation: op, term_one: a, term_two: b, result: res.result, error: res.error,
      status: res.status || 599, duration_ms: res.ms, time: new Date().toISOString(),
    });
  };

  // ---- calculator ----
  let current = ops[0];
  hud.renderOps(ops, (op) => compute(op));
  hud.selectOp(current.name);
  const termOne = document.getElementById('term-one');
  const termTwo = document.getElementById('term-two');

  async function compute(op) {
    current = op;
    hud.selectOp(op.name);
    const a = termOne.value.trim();
    const b = termTwo.value.trim();
    const res = await calculate(op.name, a, b);
    hud.showResult(op, res);
    onLocalResult(op.name, a, b, res);
  }

  document.getElementById('calc-form').addEventListener('submit', (e) => {
    e.preventDefault();
    compute(current);
  });
  for (const input of [termOne, termTwo]) {
    input.addEventListener('keydown', (e) => {
      const op = { '+': 'sum', '-': 'sub', '*': 'mul', '/': 'div' }[e.key];
      // Operator keys pick the operation, except a leading minus sign.
      if (op && byName.has(op) && !(e.key === '-' && input.selectionStart === 0)) {
        e.preventDefault();
        compute(byName.get(op));
      } else if (e.key === 'Enter') {
        e.preventDefault();
        compute(current);
      }
    });
  }

  document.getElementById('copy-curl').addEventListener('click', async () => {
    const cmd = `curl -s '${location.origin}${requestURL(current.name, termOne.value.trim(), termTwo.value.trim())}'`;
    try {
      await navigator.clipboard.writeText(cmd);
      hud.toast('curl command copied');
    } catch {
      hud.toast(cmd);
    }
  });

  // ---- traffic generator ----
  const traffic = new Traffic(ops, onLocalResult);
  const burstBtn = document.getElementById('btn-burst');
  burstBtn.addEventListener('click', async () => {
    burstBtn.disabled = true;
    await traffic.burst(50);
    burstBtn.disabled = false;
  });
  const toggle = (id, apply) => {
    const btn = document.getElementById(id);
    btn.addEventListener('click', () => {
      const on = btn.getAttribute('aria-pressed') !== 'true';
      btn.setAttribute('aria-pressed', String(on));
      apply(on);
    });
  };
  toggle('btn-steady', (on) => traffic.setSteady(on));
  toggle('btn-chaos', (on) => { traffic.chaos = on; });

  // ---- periodic refresh ----
  setInterval(() => hud.renderStats(stats.snapshot(ops)), 250);
  const pollReady = async () => {
    const ok = await isReady();
    hud.setChip('chip-ready', ok ? 'on' : 'bad', ok ? 'ready' : 'not ready');
  };
  pollReady();
  setInterval(pollReady, 5000);

  compute(current);
}

main().catch((err) => {
  console.error(err);
  hud.toast(`Could not reach the API: ${err.message}`);
});
