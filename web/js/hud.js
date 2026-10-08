// DOM side of the UI: calculator panel, telemetry panel, request log.
// Every value that came from the network is written with textContent.

const $ = (id) => document.getElementById(id);
const LOG_LINES = 7;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const fmtMs = (ms) => (ms == null ? '—' : ms < 1 ? `${(ms * 1000).toFixed(0)}µs` : `${ms.toFixed(ms < 10 ? 2 : 0)}ms`);

export function setChip(id, state, text) {
  const chip = $(id);
  chip.dataset.state = state;
  if (text !== undefined) chip.lastChild.textContent = text;
}

export function setVersion(v) {
  $('impl').textContent = `${v.implementation} · ${v.runtime}`;
  $('chip-version').textContent = `${v.version} · ${v.commit} · ${v.hostname}`;
}

export function renderOps(ops, onPick) {
  const box = $('ops');
  box.replaceChildren();
  for (const op of ops) {
    const b = el('button', 'op');
    b.type = 'button';
    b.dataset.op = op.name;
    b.title = `${op.label} — GET ${op.path}`;
    b.style.setProperty('--c', op.color);
    b.append(el('b', '', op.symbol), el('span', '', op.name));
    b.addEventListener('click', () => onPick(op));
    box.append(b);
  }

  const bars = $('bars');
  bars.replaceChildren();
  for (const op of ops) {
    const li = el('li');
    li.dataset.op = op.name;
    li.style.setProperty('--c', op.color);
    const track = el('span', 'track');
    track.append(el('span', 'fill'), el('span', 'fill err'));
    li.append(el('span', 'sym', op.symbol), track, el('span', 'count', '0'));
    bars.append(li);
  }
}

export function selectOp(name) {
  for (const b of document.querySelectorAll('.op')) b.setAttribute('aria-pressed', String(b.dataset.op === name));
}

export function showResult(op, res) {
  const box = $('result');
  box.style.setProperty('--c', res.ok ? op.color : 'var(--err)');
  box.dataset.state = res.ok ? 'ok' : 'error';
  $('result-value').textContent = res.ok ? res.result : res.error;
  box.classList.remove('flash');
  void box.offsetWidth; // restart the animation
  box.classList.add('flash');

  $('req-line').textContent = `GET ${res.url}`;
  $('req-line').title = `GET ${res.url}`;
  $('req-status').textContent = res.status ? String(res.status) : 'network error';
  $('req-latency').textContent = `${fmtMs(res.ms)} round trip`;
  $('req-id').textContent = res.requestId || '—';
}

export function logEvent(e, color) {
  const li = el('li');
  li.style.setProperty('--c', color);
  const time = new Date(e.time || Date.now()).toLocaleTimeString([], { hour12: false });
  const ok = e.status < 400;
  const detail = ok ? `${e.term_one}, ${e.term_two} → ${e.result}` : `${e.term_one}, ${e.term_two} → ${e.error || 'error'}`;
  li.append(
    el('span', 't', time),
    el('span', 'o', e.operation),
    el('span', '', detail),
    el('span', ok ? 's' : 's err', String(e.status)),
    el('span', 'd', fmtMs(Number(e.duration_ms))),
  );
  const log = $('log');
  log.prepend(li);
  while (log.children.length > LOG_LINES) log.lastChild.remove();
}

export function renderStats(s) {
  $('kpi-rps').textContent = s.rps < 10 ? s.rps.toFixed(1) : String(Math.round(s.rps));
  $('kpi-err').textContent = `${(s.errorRate * 100).toFixed(s.errorRate > 0 && s.errorRate < 0.1 ? 1 : 0)}%`;
  $('kpi-err').style.color = s.errorRate > 0.05 ? 'var(--err)' : '';
  $('kpi-total').textContent = s.total.toLocaleString();
  $('lat-p50').textContent = fmtMs(s.p50);
  $('lat-p95').textContent = fmtMs(s.p95);
  $('lat-p99').textContent = fmtMs(s.p99);

  let max = 1;
  for (const c of s.perOp.values()) max = Math.max(max, c.ok + c.err);
  for (const li of $('bars').children) {
    const c = s.perOp.get(li.dataset.op) || { ok: 0, err: 0 };
    const [ok, err] = li.querySelectorAll('.fill');
    ok.style.width = `${(c.ok / max) * 100}%`;
    err.style.width = `${(c.err / max) * 100}%`;
    li.querySelector('.count').textContent = String(c.ok + c.err);
  }
  drawSpark($('spark'), s.buckets);
}

function drawSpark(canvas, buckets) {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  if (canvas.width !== w * dpr) {
    canvas.width = w * dpr;
    canvas.height = h * dpr;
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);

  const max = Math.max(4, ...buckets);
  const step = w / (buckets.length - 1);
  const y = (v) => h - 3 - (v / max) * (h - 8);

  const grad = ctx.createLinearGradient(0, 0, 0, h);
  grad.addColorStop(0, 'rgba(34, 211, 238, 0.35)');
  grad.addColorStop(1, 'rgba(34, 211, 238, 0)');
  ctx.beginPath();
  ctx.moveTo(0, h);
  buckets.forEach((v, i) => ctx.lineTo(i * step, y(v)));
  ctx.lineTo(w, h);
  ctx.fillStyle = grad;
  ctx.fill();

  ctx.beginPath();
  buckets.forEach((v, i) => (i ? ctx.lineTo(i * step, y(v)) : ctx.moveTo(0, y(v))));
  ctx.strokeStyle = '#22d3ee';
  ctx.lineWidth = 1.5;
  ctx.shadowColor = '#22d3ee';
  ctx.shadowBlur = 8;
  ctx.stroke();
  ctx.shadowBlur = 0;
}

let toastTimer;
export function toast(text) {
  const t = $('toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 2600);
}
