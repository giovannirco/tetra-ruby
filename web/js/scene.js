// The three.js scene: the service is a tetrahedron core, each operation is
// a node on the vertices of a larger tetrahedron around it, and every API
// request is a particle that flies to its operation and then into the core.
// Failed requests shatter at their node instead of reaching the core.

import * as THREE from '../vendor/three/build/three.module.min.js';
import { EffectComposer } from '../vendor/three/examples/jsm/postprocessing/EffectComposer.js';
import { RenderPass } from '../vendor/three/examples/jsm/postprocessing/RenderPass.js';
import { UnrealBloomPass } from '../vendor/three/examples/jsm/postprocessing/UnrealBloomPass.js';
import { OutputPass } from '../vendor/three/examples/jsm/postprocessing/OutputPass.js';

const NODE_RADIUS = 3.4;
const SPAWN_RADIUS = 15;
const TRAIL = 22;
const MAX_PARTICLES = 260;
const MAX_WAVES = 8; // overlapping additive rings wash out the scene under load
const ERROR_COLOR = new THREE.Color('#f43f5e');
const CORE_COLOR = new THREE.Color('#7dd3fc');

const easeInOut = (t) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);

// Positions for n nodes: the vertices of a tetrahedron (apex up) for four,
// an even spread on a sphere otherwise.
function layout(n) {
  if (n === 4) {
    const r = NODE_RADIUS;
    const ring = (r * Math.sqrt(8)) / 3;
    const y = -r / 3;
    return [
      new THREE.Vector3(0, r, 0),
      ...[0, 1, 2].map((i) => {
        const a = (i / 3) * Math.PI * 2 + Math.PI / 6;
        return new THREE.Vector3(Math.cos(a) * ring, y, Math.sin(a) * ring);
      }),
    ];
  }
  const golden = Math.PI * (3 - Math.sqrt(5));
  return Array.from({ length: n }, (_, i) => {
    const y = n === 1 ? 0 : 1 - (i / (n - 1)) * 2;
    const r = Math.sqrt(1 - y * y);
    const a = golden * i;
    return new THREE.Vector3(Math.cos(a) * r, y, Math.sin(a) * r).multiplyScalar(NODE_RADIUS);
  });
}

export function createScene(canvas, labelsEl, { reducedMotion = false } = {}) {
  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
  } catch {
    return null; // no WebGL: the HUD still works without the scene
  }
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;

  const scene = new THREE.Scene();
  scene.fog = new THREE.FogExp2(0x04060d, 0.028);
  const camera = new THREE.PerspectiveCamera(48, 1, 0.1, 200);
  camera.position.set(0, 1.4, 12.5);

  const composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new THREE.Vector2(1, 1), 0.78, 0.42, 0.05);
  composer.addPass(bloom);
  composer.addPass(new OutputPass());

  const additive = { transparent: true, blending: THREE.AdditiveBlending, depthWrite: false };

  // ---- backdrop: stars and a polar grid under the constellation ----
  {
    const n = 1800;
    const pos = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) {
      const v = new THREE.Vector3().randomDirection().multiplyScalar(30 + Math.random() * 60);
      pos.set([v.x, v.y, v.z], i * 3);
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    const stars = new THREE.Points(geo, new THREE.PointsMaterial({ color: 0x6f82b8, size: 0.16, ...additive }));
    stars.name = 'stars';
    scene.add(stars);

    const grid = new THREE.PolarGridHelper(11, 16, 7, 96, 0x1d2a4a, 0x111a30);
    grid.position.y = -4.4;
    grid.material.transparent = true;
    grid.material.opacity = 0.55;
    scene.add(grid);
  }

  // ---- the core ----
  const world = new THREE.Group(); // rotates slowly; nodes ride on it
  scene.add(world);

  const core = new THREE.Group();
  world.add(core);
  const coreGeo = new THREE.TetrahedronGeometry(1.05);
  const coreFill = new THREE.Mesh(coreGeo, new THREE.MeshBasicMaterial({ color: 0x0b2540, ...additive, opacity: 0.9 }));
  const coreEdgesMat = new THREE.LineBasicMaterial({ color: CORE_COLOR.clone(), ...additive });
  const coreEdges = new THREE.LineSegments(new THREE.EdgesGeometry(coreGeo), coreEdgesMat);
  const shellGeo = new THREE.TetrahedronGeometry(1.75);
  const shell = new THREE.LineSegments(
    new THREE.EdgesGeometry(shellGeo),
    new THREE.LineBasicMaterial({ color: 0x2b4f7a, ...additive, opacity: 0.8 }),
  );
  const heart = new THREE.Mesh(new THREE.SphereGeometry(0.22, 24, 16), new THREE.MeshBasicMaterial({ color: 0xbfe9ff }));
  core.add(coreFill, coreEdges, shell, heart);
  let corePulse = 0;
  const coreTint = CORE_COLOR.clone();

  // ---- operation nodes ----
  const nodeGeo = new THREE.OctahedronGeometry(0.2);
  const ringGeo = new THREE.TorusGeometry(0.42, 0.012, 8, 72);
  let nodes = new Map(); // name -> node
  let links = null;

  function setOperations(ops) {
    for (const node of nodes.values()) {
      world.remove(node.group);
      node.label.remove();
    }
    if (links) world.remove(links);
    nodes = new Map();

    const points = layout(ops.length);
    ops.forEach((op, i) => {
      const color = new THREE.Color(op.color);
      const group = new THREE.Group();
      group.position.copy(points[i]);
      const gem = new THREE.Mesh(nodeGeo, new THREE.MeshBasicMaterial({ color: color.clone().multiplyScalar(1.4) }));
      const ring = new THREE.Mesh(ringGeo, new THREE.MeshBasicMaterial({ color, ...additive, opacity: 0.9 }));
      const ring2 = ring.clone();
      ring2.material = ring.material.clone();
      ring2.material.opacity = 0.4;
      ring2.scale.setScalar(1.35);
      group.add(gem, ring, ring2);
      world.add(group);

      const label = document.createElement('div');
      label.className = 'node-label';
      label.style.setProperty('--c', op.color);
      const sym = document.createElement('b');
      sym.textContent = op.symbol;
      const name = document.createElement('span');
      name.textContent = `/api/${op.name}`;
      label.append(sym, name);
      labelsEl.append(label);

      nodes.set(op.name, { op, color, group, gem, ring, ring2, label, pulse: 0, hurt: 0 });
    });

    // Faint lines: node to node (the outer tetrahedron) and node to core.
    const seg = [];
    for (let i = 0; i < points.length; i++) {
      seg.push(points[i], new THREE.Vector3());
      for (let j = i + 1; j < points.length; j++) seg.push(points[i], points[j]);
    }
    links = new THREE.LineSegments(
      new THREE.BufferGeometry().setFromPoints(seg),
      new THREE.LineBasicMaterial({ color: 0x1f3a63, ...additive, opacity: 0.7 }),
    );
    world.add(links);
  }

  // ---- particles, shards and shockwaves ----
  const headGeo = new THREE.SphereGeometry(0.075, 12, 8);
  const particles = [];
  const shards = [];
  const waves = [];
  const waveGeo = new THREE.RingGeometry(0.92, 1, 64);
  const shardGeo = new THREE.TetrahedronGeometry(0.06);
  const tmp = new THREE.Vector3();
  const nodeWorld = new THREE.Vector3();

  function spawnPoint() {
    const dir = new THREE.Vector3().randomDirection();
    if (dir.z > 0.35) dir.z = -dir.z; // never fly in from behind the camera
    return dir.multiplyScalar(SPAWN_RADIUS);
  }

  function emit(event) {
    const node = nodes.get(event.operation);
    if (!node) return;
    if (particles.length >= MAX_PARTICLES) retire(particles.shift());

    const ok = event.status < 400;
    const color = ok ? node.color.clone().multiplyScalar(1.5) : ERROR_COLOR.clone().multiplyScalar(1.5);
    const head = new THREE.Mesh(headGeo, new THREE.MeshBasicMaterial({ color }));
    const start = spawnPoint();
    head.position.copy(start);

    const trailPos = new Float32Array(TRAIL * 3);
    const trailCol = new Float32Array(TRAIL * 3);
    for (let i = 0; i < TRAIL; i++) {
      trailPos.set([start.x, start.y, start.z], i * 3);
      const f = Math.pow(1 - i / TRAIL, 1.6);
      trailCol.set([color.r * f, color.g * f, color.b * f], i * 3);
    }
    const trailGeo = new THREE.BufferGeometry();
    trailGeo.setAttribute('position', new THREE.BufferAttribute(trailPos, 3));
    trailGeo.setAttribute('color', new THREE.BufferAttribute(trailCol, 3));
    const trail = new THREE.Line(trailGeo, new THREE.LineBasicMaterial({ vertexColors: true, ...additive }));
    scene.add(head, trail);

    const bend = new THREE.Vector3().randomDirection().multiplyScalar(4 + Math.random() * 3);
    particles.push({
      node, ok, color, head, trail, start, bend,
      t: 0,
      phase: 'inbound',
      speed: 1 / (0.75 + Math.random() * 0.35),
    });
  }

  function retire(p) {
    scene.remove(p.head, p.trail);
    p.head.material.dispose();
    p.trail.geometry.dispose();
    p.trail.material.dispose();
  }

  function shockwave(position, color, size) {
    if (waves.length >= MAX_WAVES) return;
    const mesh = new THREE.Mesh(waveGeo, new THREE.MeshBasicMaterial({ color, ...additive, side: THREE.DoubleSide }));
    mesh.position.copy(position);
    scene.add(mesh);
    waves.push({ mesh, t: 0, size });
  }

  function shatter(position) {
    for (let i = 0; i < 14; i++) {
      const mesh = new THREE.Mesh(shardGeo, new THREE.MeshBasicMaterial({ color: ERROR_COLOR.clone().multiplyScalar(1.6), ...additive }));
      mesh.position.copy(position);
      scene.add(mesh);
      shards.push({
        mesh,
        v: new THREE.Vector3().randomDirection().multiplyScalar(1.5 + Math.random() * 2.5),
        spin: new THREE.Vector3().randomDirection().multiplyScalar(8),
        t: 0,
      });
    }
  }

  function step(dt) {
    for (let i = particles.length - 1; i >= 0; i--) {
      const p = particles[i];
      p.node.group.getWorldPosition(nodeWorld);

      if (p.phase === 'inbound') {
        p.t = Math.min(1, p.t + dt * p.speed);
        const t = easeInOut(p.t);
        // quadratic Bézier: start -> bend -> node
        const ctrl = tmp.copy(p.start).lerp(nodeWorld, 0.5).add(p.bend);
        const a = p.start.clone().lerp(ctrl, t);
        const b = ctrl.clone().lerp(nodeWorld, t);
        p.head.position.copy(a.lerp(b, t));
        if (p.t >= 1) {
          if (p.ok) {
            p.phase = 'core';
            p.t = 0;
            p.node.pulse = 1;
          } else {
            p.node.hurt = 1;
            shatter(nodeWorld);
            shockwave(nodeWorld, ERROR_COLOR, 0.9);
            p.phase = 'fade';
            p.t = 0;
          }
        }
      } else if (p.phase === 'core') {
        p.t = Math.min(1, p.t + dt * 3.2);
        p.head.position.copy(nodeWorld).lerp(core.getWorldPosition(tmp), p.t * p.t);
        if (p.t >= 1) {
          corePulse = 1;
          coreTint.copy(p.node.color);
          shockwave(core.getWorldPosition(tmp), p.node.color, 1.7);
          p.phase = 'fade';
          p.t = 0;
        }
      } else {
        p.t += dt * 2.5; // the head is gone; let the trail catch up
        p.head.visible = false;
        if (p.t >= 1) {
          retire(p);
          particles.splice(i, 1);
          continue;
        }
      }

      const pos = p.trail.geometry.attributes.position;
      pos.array.copyWithin(3, 0, (TRAIL - 1) * 3);
      pos.array.set([p.head.position.x, p.head.position.y, p.head.position.z], 0);
      pos.needsUpdate = true;
    }

    for (let i = shards.length - 1; i >= 0; i--) {
      const s = shards[i];
      s.t += dt;
      s.v.multiplyScalar(1 - dt * 1.8);
      s.mesh.position.addScaledVector(s.v, dt);
      s.mesh.rotation.x += s.spin.x * dt;
      s.mesh.rotation.y += s.spin.y * dt;
      s.mesh.material.opacity = Math.max(0, 1 - s.t / 0.9);
      if (s.t >= 0.9) {
        scene.remove(s.mesh);
        s.mesh.material.dispose();
        shards.splice(i, 1);
      }
    }

    for (let i = waves.length - 1; i >= 0; i--) {
      const w = waves[i];
      w.t += dt / 0.85;
      w.mesh.lookAt(camera.position);
      w.mesh.scale.setScalar(0.2 + w.size * easeInOut(Math.min(1, w.t)));
      w.mesh.material.opacity = 0.55 * Math.max(0, 1 - w.t);
      if (w.t >= 1) {
        scene.remove(w.mesh);
        w.mesh.material.dispose();
        waves.splice(i, 1);
      }
    }
  }

  // ---- camera, resize, labels ----
  const pointer = { x: 0, y: 0 };
  window.addEventListener('pointermove', (e) => {
    pointer.x = (e.clientX / window.innerWidth) * 2 - 1;
    pointer.y = (e.clientY / window.innerHeight) * 2 - 1;
  });

  let narrow = false;
  function resize() {
    const w = window.innerWidth;
    const h = window.innerHeight;
    narrow = w <= 1080;
    renderer.setSize(w, h, false);
    composer.setSize(w, h);
    bloom.setSize(w, h);
    camera.aspect = w / h;
    camera.fov = w / h < 0.8 ? 62 : 48;
    camera.updateProjectionMatrix();
  }
  window.addEventListener('resize', resize);
  resize();

  function placeLabels() {
    const w = window.innerWidth;
    const h = window.innerHeight;
    for (const node of nodes.values()) {
      node.group.getWorldPosition(tmp);
      const depth = tmp.distanceTo(camera.position);
      tmp.project(camera);
      const x = (tmp.x * 0.5 + 0.5) * w;
      const y = (-tmp.y * 0.5 + 0.5) * h + 56;
      node.label.style.transform = `translate(${x}px, ${y}px) translate(-50%, -50%)`;
      node.label.style.opacity = String(THREE.MathUtils.clamp(1.6 - depth / 12, 0.35, 1));
    }
  }

  // ---- loop ----
  const clock = new THREE.Clock();
  const spin = reducedMotion ? 0.015 : 0.07;
  const stars = scene.getObjectByName('stars');
  const lookTarget = new THREE.Vector3();

  function frame() {
    const dt = Math.min(clock.getDelta(), 0.05);
    const t = clock.elapsedTime;

    world.rotation.y += dt * spin;
    stars.rotation.y -= dt * spin * 0.15;
    core.rotation.y += dt * 0.45;
    core.rotation.x = Math.sin(t * 0.4) * 0.25;
    shell.rotation.y -= dt * 0.9;
    shell.rotation.z += dt * 0.3;

    corePulse *= Math.exp(-dt * 4);
    core.scale.setScalar(1 + corePulse * 0.28 + Math.sin(t * 2.2) * 0.015);
    coreTint.lerp(CORE_COLOR, dt * 2.2);
    coreEdgesMat.color.copy(coreTint).multiplyScalar(1.2 + corePulse * 1.6);
    heart.scale.setScalar(1 + corePulse * 0.9);

    for (const node of nodes.values()) {
      node.pulse *= Math.exp(-dt * 5);
      node.hurt *= Math.exp(-dt * 3);
      node.gem.rotation.y += dt * 1.2;
      node.ring.lookAt(camera.position);
      node.ring2.rotation.x += dt * 0.8;
      node.ring2.rotation.y += dt * 0.5;
      node.group.scale.setScalar(1 + node.pulse * 0.6 + node.hurt * 0.3);
      node.gem.material.color.copy(node.color).lerp(ERROR_COLOR, node.hurt).multiplyScalar(1.4 + node.pulse);
    }

    step(dt);

    const px = reducedMotion ? 0 : pointer.x * 1.6;
    const py = reducedMotion ? 0 : pointer.y * 0.9;
    camera.position.x += (px - camera.position.x) * dt * 2;
    camera.position.y += (1.4 - py - camera.position.y) * dt * 2;
    lookTarget.set(0, narrow ? -2.6 : -0.8, 0);
    camera.lookAt(lookTarget);

    composer.render();
    placeLabels();
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  return {
    setOperations,
    emit,
    stats: () => ({ particles: particles.length, shards: shards.length, waves: waves.length }),
  };
}
