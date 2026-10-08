// Thin client for the Tetra HTTP API.

export async function getJSON(path) {
  const res = await fetch(path, { cache: 'no-store' });
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
  return res.json();
}

export function requestURL(op, termOne, termTwo) {
  return `/api/${op}?${new URLSearchParams({ term_one: termOne, term_two: termTwo })}`;
}

// calculate calls one operation. The result is read from the raw body so
// 64-bit integers keep every digit (JSON.parse would round them).
export async function calculate(op, termOne, termTwo) {
  const url = requestURL(op, termOne, termTwo);
  const started = performance.now();
  try {
    const res = await fetch(url, { cache: 'no-store' });
    const text = await res.text();
    const ms = performance.now() - started;
    const match = /"result"\s*:\s*(-?\d+)/.exec(text);
    let error = null;
    if (!res.ok) {
      try { error = JSON.parse(text).error; } catch { error = text || `HTTP ${res.status}`; }
    }
    return {
      url, ms, ok: res.ok, status: res.status, error,
      result: match ? match[1] : null,
      requestId: res.headers.get('X-Request-Id'),
    };
  } catch (err) {
    return { url, ms: performance.now() - started, ok: false, status: 0, error: String(err.message || err), result: null, requestId: null };
  }
}

// stream subscribes to /events. onState receives 'on', 'warn' (reconnecting)
// or 'bad' (closed for good); EventSource reconnects by itself.
export function stream(onEvent, onState) {
  if (!('EventSource' in window)) {
    onState('bad');
    return { isOpen: () => false };
  }
  const es = new EventSource('/events');
  es.addEventListener('open', () => onState('on'));
  es.addEventListener('error', () => onState(es.readyState === EventSource.CLOSED ? 'bad' : 'warn'));
  es.addEventListener('calc', (e) => {
    try { onEvent(JSON.parse(e.data)); } catch { /* ignore malformed */ }
  });
  return { isOpen: () => es.readyState === EventSource.OPEN };
}

export async function isReady() {
  try {
    const res = await fetch('/readyz', { cache: 'no-store' });
    return res.ok;
  } catch {
    return false;
  }
}
