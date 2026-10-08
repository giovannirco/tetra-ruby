// Traffic generator: bursts, a steady stream, and a chaos mode that mixes
// in requests the API must reject (division by zero, overflow, bad input).

import { calculate } from './api.js';

const MAX_INT64 = '9223372036854775807';
const CONCURRENCY = 8;

const rand = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;

function validRequest(ops) {
  const op = ops[rand(0, ops.length - 1)].name;
  const a = rand(-999, 999);
  let b = rand(-99, 99);
  if (b === 0) b = 1;
  return [op, String(a), String(b)];
}

function badRequest(ops) {
  const pick = rand(0, 3);
  if (pick === 0 && ops.some((o) => o.name === 'div')) return ['div', String(rand(1, 99)), '0'];
  if (pick === 1 && ops.some((o) => o.name === 'mul')) return ['mul', MAX_INT64, '2'];
  if (pick === 2) return [ops[rand(0, ops.length - 1)].name, 'NaN', '1'];
  return [ops[rand(0, ops.length - 1)].name, String(rand(1, 9)), '1.5'];
}

export class Traffic {
  constructor(ops, onLocalResult) {
    this.ops = ops;
    this.onLocalResult = onLocalResult;
    this.chaos = false;
    this.timer = null;
    this.inFlight = 0;
  }

  next() {
    return this.chaos && Math.random() < 0.35 ? badRequest(this.ops) : validRequest(this.ops);
  }

  async fire() {
    if (this.inFlight >= CONCURRENCY) return;
    this.inFlight++;
    const [op, a, b] = this.next();
    try {
      this.onLocalResult(op, a, b, await calculate(op, a, b));
    } finally {
      this.inFlight--;
    }
  }

  async burst(n) {
    let left = n;
    const worker = async () => {
      while (left-- > 0) {
        const [op, a, b] = this.next();
        this.onLocalResult(op, a, b, await calculate(op, a, b));
      }
    };
    await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  }

  setSteady(on) {
    clearInterval(this.timer);
    this.timer = on ? setInterval(() => this.fire(), 100) : null;
  }
}
