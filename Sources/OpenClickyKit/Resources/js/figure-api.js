// OpenClicky 3D figures: the figure() language (docs/dsl-3d.md) as a drawing-engine plugin.
//
// Loaded by the 2D engine after itself (docs/drawing-contract.md). It registers figure() through
// __engine.registerModule and turns each part statement into plain-data 3D marks (figure, part3d, motion3d,
// camera3d, label3d, tick3d, readout3d). Meshes are built natively by the geometry kernel from each part's
// canonical recipe; nothing here touches the GPU.
//
// State that must outlive one program (tick functions, tick poses, readouts) lives in globalThis.__figure3d,
// which the host calls once per frame to run ticks.
(function () {
  'use strict';

  // ---------------------------------------------------------------------------------------------------------
  // Small vector and rotation helpers. Rotations are unit quaternions [x, y, z, w]; Euler angles are degrees
  // applied X, then Y, then Z (matrix = Rx · Ry · Rz), the same convention the native side uses.

  const DEG = Math.PI / 180;
  const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const num = (v, fallback, lo, hi) => {
    const n = isNum(v) ? v : fallback;
    return clamp(n, lo === undefined ? -Infinity : lo, hi === undefined ? Infinity : hi);
  };
  const vec3 = (v, fallback) => {
    if (Array.isArray(v) && v.length >= 3 && v.slice(0, 3).every(isNum)) return [v[0], v[1], v[2]];
    if (isNum(v)) return [v, v, v];
    return fallback ? fallback.slice() : null;
  };
  const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
  const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
  const mul = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
  const len = (a) => Math.hypot(a[0], a[1], a[2]);
  const unit = (a) => { const l = len(a); return l > 1e-9 ? mul(a, 1 / l) : [0, 1, 0]; };
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];

  function quatAxisAngle(axis, radians) {
    return mul(unit(axis), Math.sin(radians / 2)).concat(Math.cos(radians / 2));
  }
  /** The product p·q (turn by q, then by p) in vector form: (w1 v2 + w2 v1 + v1 × v2, w1 w2 − v1 · v2). */
  function quatMul(p, q) {
    const pv = p.slice(0, 3), qv = q.slice(0, 3);
    return add(add(mul(qv, p[3]), mul(pv, q[3])), cross(pv, qv)).concat(p[3] * q[3] - dot(pv, qv));
  }
  /** Turn v by the unit quaternion q: v + 2w (u × v) + 2 u × (u × v), with u the vector part. */
  function quatRotate(q, v) {
    const u = q.slice(0, 3), uv = cross(u, v);
    return add(add(v, mul(uv, 2 * q[3])), mul(cross(u, uv), 2));
  }
  const quatInverse = (q) => [-q[0], -q[1], -q[2], q[3]];
  function quatFromEuler(deg) {
    const qx = quatAxisAngle([1, 0, 0], deg[0] * DEG);
    const qy = quatAxisAngle([0, 1, 0], deg[1] * DEG);
    const qz = quatAxisAngle([0, 0, 1], deg[2] * DEG);
    return quatMul(quatMul(qx, qy), qz);
  }
  function eulerFromQuat(q) {
    // Rotation matrix of q, then decompose as Rx · Ry · Rz.
    const [x, y, z, w] = q;
    const m02 = 2 * (x * z + w * y);
    const m12 = 2 * (y * z - w * x), m22 = 1 - 2 * (x * x + y * y);
    const m00 = 1 - 2 * (y * y + z * z), m01 = 2 * (x * y - w * z);
    const m21 = 2 * (y * z + w * x), m11 = 1 - 2 * (x * x + z * z);
    const ry = Math.asin(clamp(m02, -1, 1));
    let rx, rz;
    if (Math.abs(m02) < 0.99999) {
      rx = Math.atan2(-m12, m22);
      rz = Math.atan2(-m01, m00);
    } else {
      // Gimbal lock (ry = ±90°): put the whole remaining turn on x.
      rx = Math.atan2(m21, m11);
      rz = 0;
    }
    const tidy = (r) => Math.round((r / DEG) * 1e4) / 1e4 + 0;
    return [tidy(rx), tidy(ry), tidy(rz)];
  }

  const AXIS_NAMES = { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] };
  /** Index 0, 1 or 2 of an axis word ("x", "-z", "+ y"), or -1. */
  function axisIndex(word) {
    if (typeof word !== 'string') return -1;
    const bare = word.replace(/\s+/g, '').toLowerCase().replace(/^[+-]/, '');
    return AXIS_NAMES[bare] ? AXIS_NAMES[bare].indexOf(1) : -1;
  }

  /** "x", "-z", "+y" or a vector -> unit vector; anything else -> fallback. */
  function axisVector(spec, fallback) {
    if (typeof spec === 'string') {
      const index = axisIndex(spec);
      if (index < 0) return fallback;
      const v = [0, 0, 0];
      v[index] = spec.trim().startsWith('-') ? -1 : 1;
      return v;
    }
    const v = vec3(spec, null);
    return v && len(v) > 1e-9 ? unit(v) : fallback;
  }

  // ---------------------------------------------------------------------------------------------------------
  // Canonical recipe JSON: sorted keys, numbers rounded to 4 decimals, nothing non-finite. Equal shapes give
  // equal text, which is what the kernel's mesh cache is keyed by.

  function canonical(value) {
    if (typeof value === 'number') return Number.isFinite(value) ? Math.round(value * 1e4) / 1e4 + 0 : undefined;
    if (typeof value === 'string' || typeof value === 'boolean') return value;
    if (Array.isArray(value)) return value.map((item) => { const c = canonical(item); return c === undefined ? null : c; });
    if (value && typeof value === 'object') {
      const out = {};
      for (const key of Object.keys(value).sort()) {
        const c = canonical(value[key]);
        if (c !== undefined) out[key] = c;
      }
      return out;
    }
    return undefined;
  }
  const canonicalJSON = (value) => JSON.stringify(canonical(value));

  // ---------------------------------------------------------------------------------------------------------
  // Colours and materials. Figure colours are muted, photographic versions of common names; glows use brighter
  // ones so a lamp still reads as its colour after lighting.

  const COLORS = {
    red: '#B23A32', orange: '#CF6A2C', yellow: '#D9B13B', green: '#4F8A4A', teal: '#2F8C88', blue: '#2F5E9E',
    navy: '#22385E', purple: '#6A4F93', pink: '#CF8796', brown: '#6E4B33', tan: '#B8956B', cream: '#E6DCC6',
    white: '#ECEAE5', grey: '#8D9096', gray: '#8D9096', charcoal: '#3A3D42', black: '#1F2124', silver: '#C3C7CC',
  };
  const GLOW_COLORS = {
    red: '#FF4A3D', orange: '#FF8A2A', yellow: '#FFD23A', green: '#4DFF7A', teal: '#2EF2E0', blue: '#3D8BFF',
    navy: '#4060FF', purple: '#B266FF', pink: '#FF6FB0', white: '#FFF4E0', cream: '#FFE9B8',
  };
  const MATERIALS = new Set([
    'steel', 'chrome', 'aluminum', 'aluminium', 'alu', 'titanium', 'iron', 'brass', 'copper', 'gold',
    'plastic', 'gloss', 'matte', 'rubber', 'paint', 'ceramic', 'wood', 'paper', 'glass', 'water', 'glow',
  ]);
  const MATERIAL_KEYS = ['mat', 'color', 'rough', 'metal', 'opacity', 'glow', 'coat', 'sheen', 'flat', 'double'];
  const PLACE_KEYS = ['at', 'rot', 'scale', 'parent', 'name', 'from', 'to', 'mirror', 'copies', 'cut'];
  const FROM_TO_KINDS = new Set(['cylinder', 'cone', 'tube', 'capsule', 'spring']);
  const POINT_KINDS = new Set(['pipe', 'arrow']);
  const PART_KINDS = ['arrow', 'blob', 'box', 'capsule', 'cone', 'cylinder', 'extrude', 'gear', 'lathe', 'pipe', 'poly',
    'sphere', 'spring', 'torus', 'tube'];

  const HEX = /^#?([0-9a-f]{6})$/i;
  const HEX3 = /^#([0-9a-f]{3})$/i;
  function colorHex(name, ink, glow) {
    if (typeof name !== 'string') return null;
    const s = name.trim().toLowerCase();
    let m = HEX.exec(s);
    if (m) return '#' + m[1].toUpperCase();
    m = HEX3.exec(s);
    if (m) return '#' + m[1].split('').map((c) => c + c).join('').toUpperCase();
    if (s === 'ink') return ink;
    if (glow && GLOW_COLORS[s]) return GLOW_COLORS[s];
    return COLORS[s] || null;
  }

  function materialFrom(op, ink) {
    const out = {};
    let mat = typeof op.mat === 'string' ? op.mat.trim().toLowerCase() : '';
    let tint = op.color;
    const colon = mat.indexOf(':');
    if (colon > 0) { tint = tint === undefined ? mat.slice(colon + 1) : tint; mat = mat.slice(0, colon); }
    if (mat && !MATERIALS.has(mat)) {
      // An unknown word is a colour on glossy plastic ("mat: 'red'").
      if (tint === undefined && colorHex(mat, ink)) tint = mat;
      mat = 'gloss';
    }
    if (mat === 'aluminium' || mat === 'alu') mat = 'aluminum';
    if (mat) out.mat = mat;
    const hex = colorHex(tint, ink, mat === 'glow');
    if (hex) out.color = hex;
    if (isNum(op.rough)) out.rough = clamp(op.rough, 0, 1);
    if (isNum(op.metal)) out.metal = clamp(op.metal, 0, 1);
    if (isNum(op.opacity)) out.opacity = clamp(op.opacity, 0, 1);
    if (isNum(op.coat)) out.coat = clamp(op.coat, 0, 1);
    if (isNum(op.sheen)) out.sheen = clamp(op.sheen, 0, 1);
    if (isNum(op.glow)) out.glow = clamp(op.glow, 0, 1);
    else if (typeof op.glow === 'string') {
      const glowHex = colorHex(op.glow, ink, true);
      if (glowHex) { out.glow = 1; out.glowColor = glowHex; }
    } else if (op.glow === true) out.glow = 1;
    if (op.flat === true) out.flat = true;
    if (op.double === true) out.double = true;
    return out;
  }

  /** cut option -> [nx, ny, nz, offset]; n points at the removed half, which is where dot(n, p) > offset. */
  function cutPlane(spec) {
    if (spec === undefined || spec === null || spec === false) return null;
    if (spec === true) return [0, 0, 1, 0];
    if (typeof spec === 'string') {
      const n = axisVector(spec, null);
      return n ? [n[0], n[1], n[2], 0] : null;
    }
    if (typeof spec === 'object') {
      const n = axisVector(spec.axis === undefined ? 'z' : spec.axis, null);
      if (!n) return null;
      const at = num(spec.at, 0);
      // The plane sits at coordinate `at` along the named axis (x = at), whichever side is removed.
      const offset = at * (n[0] + n[1] + n[2]);
      return [n[0], n[1], n[2], offset];
    }
    return null;
  }

  // ---------------------------------------------------------------------------------------------------------
  // Registry shared by every program run in this context.

  const registry = globalThis.__figure3d || (globalThis.__figure3d = {});
  registry.figures = registry.figures || new Map();
  registry.inTick = false;
  registry.pendingName = null;
  registry.dirtyReadouts = registry.dirtyReadouts || new Set();

  /** The next part made takes this name (hosts call it for `const NAME = f.part(...)` statements). */
  registry.nameNext = function (name) {
    registry.pendingName = typeof name === 'string' ? name.slice(0, 40) : null;
  };

  const TICK_BUDGET_MS = 8;
  /** Hard limit for one tick call when the engine can enforce it (`ctx.guarded`). */
  const TICK_LIMIT_MS = 50;
  const TICK_STRIKES = 5;
  const POSE_FLOATS = 12;

  /** Run the started ticks of one figure and return the tick poses of its parts (see docs/dsl-3d.md §10). */
  registry.runTicks = function (figureId, ticks, dt) {
    const fig = registry.figures.get(figureId);
    if (!fig) return new Float32Array(0);
    const step = isNum(dt) && dt > 0 ? dt : 1 / 60;
    registry.inTick = true;
    try {
      for (const entry of ticks || []) {
        const tick = fig.ticks.get(entry[0]);
        if (!tick) continue;
        const began = Date.now();
        try {
          // Program code outside a statement: the engine's runaway-loop guard must be armed for it (see §10).
          if (typeof registry.guarded === 'function') registry.guarded(() => tick.fn(num(entry[1], 0), step), TICK_LIMIT_MS);
          else tick.fn(num(entry[1], 0), step);
        } catch (error) {
          fig.ticks.delete(entry[0]);
          fig.warn('tick ' + entry[0] + ' stopped: ' + (error && error.message ? error.message : String(error)));
          continue;
        }
        if (Date.now() - began > TICK_BUDGET_MS && ++tick.strikes > TICK_STRIKES) {
          fig.ticks.delete(entry[0]);
          fig.warn('tick ' + entry[0] + ' stopped: too slow');
        }
      }
    } finally {
      registry.inTick = false;
    }
    const posed = [];
    for (const part of fig.parts.values()) if (part.pose.mask) posed.push(part);
    const out = new Float32Array(posed.length * POSE_FLOATS);
    posed.forEach((part, i) => {
      const p = part.pose, o = i * POSE_FLOATS;
      out[o] = part.n; out[o + 1] = p.mask;
      if (p.at) { out[o + 2] = p.at[0]; out[o + 3] = p.at[1]; out[o + 4] = p.at[2]; }
      if (p.rot) { out[o + 5] = p.rot[0]; out[o + 6] = p.rot[1]; out[o + 7] = p.rot[2]; }
      out[o + 8] = isNum(p.scale) ? p.scale : 1;
      out[o + 9] = isNum(p.glow) ? p.glow : 0;
      out[o + 10] = p.show === false ? 0 : 1;
      out[o + 11] = p.color ? parseInt(p.color.slice(1), 16) : 0;
    });
    return out;
  };

  /** Readouts changed by ticks since the last call, as JSON {figureId: {key: text}}, or null. */
  registry.takeReadouts = function () {
    if (!registry.dirtyReadouts.size) return null;
    const out = {};
    for (const id of registry.dirtyReadouts) {
      const fig = registry.figures.get(id);
      if (fig) out[id] = Object.assign({}, fig.readouts);
    }
    registry.dirtyReadouts.clear();
    return JSON.stringify(out);
  };

  /**
   * What a part is called: its `name`, else the program variable that holds its handle (`const rotor =
   * f.cylinder(...)` -> "rotor"), else null. Copies made by `copies`/`mirror` answer with their first part's
   * variable. The engine runs programs at global scope, so their variables are properties of globalThis.
   */
  registry.nameOf = function (partId) {
    let state = null;
    for (const fig of registry.figures.values()) { if (fig.parts.has(partId)) { state = fig.parts.get(partId); break; } }
    if (state && state.name) return state.name;
    const wanted = new Set([partId]);
    if (state && state.copyOf) wanted.add(state.copyOf);
    for (const key of Object.getOwnPropertyNames(globalThis)) {
      if (key.startsWith('__') || key.length > 40) continue;
      let value;
      try { value = globalThis[key]; } catch (e) { continue; }
      if (value && typeof value === 'object' && wanted.has(value.__figurePart)) return key;
    }
    return null;
  };

  /** One line per part, for follow-up turns that build on a figure. */
  registry.describe = function (figureId) {
    const fig = registry.figures.get(figureId);
    if (!fig) return '';
    const lines = ['3D figure ' + figureId + ' (' + fig.parts.size + ' parts; build on these, never redraw them):'];
    const rows = [];
    for (const part of fig.parts.values()) {
      const shape = part.recipe ? Object.entries(part.recipe).map(([k, v]) => {
        if (typeof v === 'number') return k + ' ' + +v.toFixed(3);
        if (typeof v === 'string') return k + ' ' + (v.length > 24 ? v.slice(0, 24) + '…' : v);
        if (Array.isArray(v) && v.length <= 4 && v.every(isNum)) return k + ' [' + v.map((x) => +x.toFixed(3)).join(', ') + ']';
        if (Array.isArray(v)) return k + ' (' + v.length + ' points)';
        return null;
      }).filter(Boolean).join(', ') : '';
      const name = part.name || (part.copyOf ? null : registry.nameOf(part.id));
      const bits = [name ? '"' + name + '"' : null, part.kind, shape || null,
        'at [' + part.at.map((v) => +v.toFixed(2)).join(', ') + ']',
        part.material.mat || null, part.material.color || null,
        part.parent ? 'in ' + part.parent : null].filter(Boolean);
      rows.push({ id: part.id, text: bits.join(' · '), copyOf: part.copyOf });
    }
    for (let i = 0; i < rows.length; i++) {
      let j = i;
      while (j + 1 < rows.length && rows[j + 1].copyOf && rows[j + 1].copyOf === (rows[i].copyOf || rows[i].id)) j++;
      lines.push(j > i ? (j - i + 1) + '× ' + rows[i].id + '–' + rows[j].id + ' ' + rows[i].text : rows[i].id + ' ' + rows[i].text);
      i = j;
    }
    return lines.join('\n');
  };

  // ---------------------------------------------------------------------------------------------------------
  // The plugin.

  const engine = globalThis.__engine;
  if (!engine || typeof engine.registerModule !== 'function') return;

  // The engine may call this once when the plugin loads (before any program has begun), so the canvas and ink are
  // read from ctx on every use, never captured here.
  engine.registerModule(function (api, ctx) {
    // Optional engine hook: guarded(fn, ms) runs fn with the engine's runaway-loop guard armed for ms milliseconds.
    // Ticks run between statements, when the guard would otherwise stop the first loop or function call it sees.
    registry.guarded = typeof ctx.guarded === 'function' ? ctx.guarded.bind(ctx) : null;
    const currentCanvas = () => {
      const c = ctx.canvas;
      return c && isNum(c.width) && isNum(c.height) ? c : { width: 1440, height: 900, scale: 2 };
    };
    const currentInk = () => colorHex(typeof ctx.ink === 'string' ? ctx.ink : '', null) || '#30333A';
    const step = () => (typeof ctx.currentStep === 'function' ? ctx.currentStep() : 0);
    const warn = (message) => { if (typeof ctx.warn === 'function') ctx.warn(message); };
    // `__dur` / `__adv` are the engine's pacing hints (seconds the mark takes to draw, and how long until the next
    // mark of the same line may start); the engine turns them into `start` and `duration` and strips them.
    const push = (mark, dur, adv) => {
      mark.step = step();
      mark.__dur = dur;
      mark.__adv = adv;
      mark.duration = dur;
      return ctx.push(mark) || mark;
    };

    function figure(x, y, w, h, options) {
      const canvas = currentCanvas();
      const defaultInk = currentInk();
      let o = options;
      if (x && typeof x === 'object' && !Array.isArray(x)) {
        o = x;
        w = Math.min(560, canvas.width * 0.42);
        h = Math.min(460, canvas.height * 0.6);
        x = canvas.width * 0.54;
        y = canvas.height * 0.16;
        warn('figure() had no rectangle; placed it at ' + [x, y, w, h].map(Math.round).join(', '));
      }
      o = o || {};
      if (![x, y, w, h].every(isNum) || w < 40 || h < 40) {
        warn('figure() needs a finite rectangle at least 40×40; skipped');
        return null;
      }
      // Nothing bigger than the canvas can be seen whole, and every point of it costs GPU memory.
      if (w > canvas.width || h > canvas.height) {
        w = Math.min(w, canvas.width);
        h = Math.min(h, canvas.height);
        warn('figure() was bigger than the canvas; shrunk it to ' + Math.round(w) + '×' + Math.round(h));
      }
      const id = ctx.nextId('fig');
      const look = o.look === 'illustrated' ? 'illustrated' : 'studio';
      const camera = {
        tilt: num(o.tilt, 18, -80, 80), turn: num(o.turn, 0, -180, 180), spin: num(o.spin, 2, 0, 12),
        zoom: num(o.zoom, 1, 0.5, 3), fov: num(o.fov, 30, 15, 70),
      };
      // `at`/`w`/`h` is where the painter puts the figure's layer; `rect` says the same in one array.
      const mark = { id, do: 'figure', at: [x, y], w, h, rect: [x, y, w, h], look, ink: defaultInk, camera };
      // Lets the 2D engine keep later pieces from landing on the figure.
      mark.__box = { x, y, w, h };
      const figureCut = cutPlane(o.cut);
      if (figureCut) mark.cut = figureCut;
      if (typeof o.title === 'string') mark.title = o.title.slice(0, 60);
      if (typeof o.card === 'boolean') mark.card = o.card;
      push(mark, 0.35, 0.12);

      const fig = {
        id, look, ink: defaultInk, warn, parts: new Map(), byName: new Map(), ticks: new Map(), readouts: {},
        count: { p: 0, l: 0, m: 0, c: 0, t: 0, r: 0 }, defaultParent: null, cut: figureCut, warmed: new Set(),
      };
      registry.figures.set(id, fig);
      const nextId = (letter) => id + '.' + letter + (++fig.count[letter]);

      const f = { id, kind: 'figure' };

      function resolveParent(ref) {
        if (ref === undefined || ref === null) return fig.defaultParent;
        if (typeof ref === 'object' && typeof ref.id === 'string') return ref.id;
        const part = lookup(ref);
        if (part) return part.id;
        warn('unknown parent ' + JSON.stringify(ref) + '; ignored');
        return null;
      }

      function lookup(ref) {
        if (ref && typeof ref === 'object' && typeof ref.id === 'string') return fig.parts.get(ref.id) || null;
        if (isNum(ref)) return fig.parts.get(id + '.p' + ref) || null;
        if (typeof ref === 'string') {
          if (fig.parts.has(ref)) return fig.parts.get(ref);
          if (/^p\d+$/.test(ref)) return fig.parts.get(id + '.' + ref) || null;
          return fig.byName.get(ref) || null;
        }
        return null;
      }

      // ---- parts -------------------------------------------------------------------------------------------

      function makePart(kind, op) {
        op = op && typeof op === 'object' ? op : {};
        if (kind === 'arrow' && Array.isArray(op)) op = { points: op };
        const recipe = {};
        for (const key of Object.keys(op)) {
          if (PLACE_KEYS.includes(key) || MATERIAL_KEYS.includes(key) || key === 'pos' || key === 'rotate') continue;
          recipe[key] = op[key];
        }
        let at = vec3(op.at !== undefined ? op.at : op.pos, null);
        let quat = quatFromEuler(vec3(op.rot !== undefined ? op.rot : op.rotate, [0, 0, 0]));
        let scale = 1;
        const params = {};

        const from = vec3(op.from, null), to = vec3(op.to, null);
        if (from && to && FROM_TO_KINDS.has(kind)) {
          const d = sub(to, from);
          if (len(d) > 1e-6) {
            at = mul(add(from, to), 0.5);
            recipe.h = len(d);
            recipe.axis = unit(d);
            params.from = from; params.to = to;
          }
        } else if (from && to && kind === 'arrow') {
          recipe.points = [from, to];
        }

        if (POINT_KINDS.has(kind) && Array.isArray(recipe.points) && !at) {
          const pts = recipe.points.map((p) => vec3(p, null)).filter(Boolean);
          if (pts.length) {
            const mean = mul(pts.reduce(add, [0, 0, 0]), 1 / pts.length);
            recipe.points = pts.map((p) => sub(p, mean));
            at = mean;
          }
        }

        if (Array.isArray(op.scale)) {
          const s = vec3(op.scale, null);
          if (s) recipe.stretch = s;
        } else if (isNum(op.scale)) scale = Math.max(0, op.scale);

        at = at || [0, 0, 0];
        const parent = resolveParent(op.parent);
        const material = materialFrom(op, fig.ink);
        const cut = op.cut === undefined ? fig.cut : cutPlane(op.cut);
        let name = typeof op.name === 'string' ? op.name.slice(0, 40) : registry.pendingName;
        registry.pendingName = null;

        // Placements: the part itself, then copies, then mirrored versions of all of those.
        let placements = [{ at, quat, mirror: null }];
        const copies = op.copies && typeof op.copies === 'object' ? op.copies : null;
        if (copies && kind !== 'group') {
          const count = Math.round(num(copies.count, 1, 1, 240));
          if (copies.around !== undefined || copies.center !== undefined || copies.arc !== undefined) {
            const axis = axisVector(copies.around === undefined ? 'y' : copies.around, [0, 1, 0]);
            const center = vec3(copies.center, [0, 0, 0]);
            const arc = num(copies.arc, 360, -360, 360);
            const gap = Math.abs(Math.abs(arc) - 360) < 1e-6 ? arc / count : arc / Math.max(1, count - 1);
            placements = [];
            for (let k = 0; k < count; k++) {
              const q = quatAxisAngle(axis, k * gap * DEG);
              placements.push({ at: add(center, quatRotate(q, sub(at, center))), quat: quatMul(q, quat), mirror: null });
            }
          } else {
            const stepVec = vec3(copies.step, [1, 0, 0]);
            const turn = vec3(copies.turn, [0, 0, 0]);
            placements = [];
            for (let k = 0; k < count; k++) {
              const q = quatFromEuler(mul(turn, k));
              placements.push({ at: add(at, mul(stepVec, k)), quat: quatMul(q, quat), mirror: null });
            }
          }
        }
        // Reflections: every combination of the named planes (x, z, then x and z together, …), never none.
        const planes = new Set([].concat(op.mirror === undefined || op.mirror === null ? [] : op.mirror).map(axisIndex));
        planes.delete(-1);
        let reflections = [[1, 1, 1]];
        for (const axis of planes) {
          reflections = reflections.concat(reflections.map((r) => r.map((sign, k) => (k === axis ? -sign : sign))));
        }
        reflections.shift();
        if (reflections.length && kind !== 'group') {
          const base = placements.slice();
          for (const s of reflections) {
            const det = s[0] * s[1] * s[2];
            for (const p of base) {
              placements.push({
                at: [p.at[0] * s[0], p.at[1] * s[1], p.at[2] * s[2]],
                // Reflecting a rotation: S·R·S, which in quaternion form scales the vector part by det(S)·S.
                quat: [det * s[0] * p.quat[0], det * s[1] * p.quat[1], det * s[2] * p.quat[2], p.quat[3]],
                mirror: s,
              });
            }
          }
        }

        const ids = [];
        let first = null;
        placements.forEach((placement, index) => {
          const n = ++fig.count.p;
          const partId = id + '.p' + n;
          let partRecipe = null, recipeText = null;
          if (kind !== 'group') {
            partRecipe = Object.assign({}, recipe);
            if (placement.mirror) partRecipe.mirror = placement.mirror;
            recipeText = canonicalJSON(partRecipe);
            // The host starts building the mesh now, while the voice is still on earlier lines, so the part is
            // ready when its own line is heard. Each distinct shape is sent once per figure.
            const warmKey = kind + '\u0001' + recipeText;
            if (!fig.warmed.has(warmKey) && typeof ctx.prewarmShape === 'function') {
              fig.warmed.add(warmKey);
              ctx.prewarmShape(kind, recipeText);
            }
          }
          let partName = name || null;
          if (name && index > 0) partName = placement.mirror ? name + ' (mirror)' : name + ' ' + (index + 1);
          // Rotations travel as XYZ Euler degrees: the engine rounds numbers to 2 decimals, which keeps degrees
          // exact enough but would bend a quaternion.
          const mark = {
            id: partId, do: 'part3d', figure: id, n, kind,
            at: placement.at, rot: eulerFromQuat(placement.quat), scale, parent, material, cut,
          };
          if (recipeText) mark.recipe = recipeText;
          if (placement.mirror) mark.mirror = placement.mirror;
          if (partName) mark.name = partName;
          if (index > 0) mark.copyOf = ids[0];
          if (kind === 'group') mark.group = true;
          if (params.from) { mark.from = params.from; mark.to = params.to; }
          // Groups have nothing to draw; copies follow each other quickly so a ring of 80 blades doesn't take
          // a minute to build.
          if (kind === 'group') push(mark, 0, 0);
          else push(mark, 0.6, index > 0 ? 0.03 : 0.12);
          const state = {
            id: partId, n, kind, name: partName, recipe: partRecipe, material, parent,
            at: placement.at.slice(), rot: mark.rot.slice(), scale, show: true, glow: material.glow || 0,
            color: material.color || null, copyOf: mark.copyOf || null, mirror: placement.mirror, pose: { mask: 0 },
          };
          fig.parts.set(partId, state);
          if (partName && !fig.byName.has(partName)) fig.byName.set(partName, state);
          ids.push(partId);
          if (!first) first = state;
        });
        return handleFor(first, ids);
      }

      // ---- handles -----------------------------------------------------------------------------------------

      function handleFor(state, ids) {
        const h = { id: state.id, kind: state.kind === 'group' ? 'group' : 'part', name: state.name, n: state.n,
          copies: ids || [state.id] };
        // Marks the object as a part handle, so a variable holding it can name the part later (registry.nameOf).
        Object.defineProperty(h, '__figurePart', { value: state.id, enumerable: false });
        const targets = h.copies;
        const motion = (kind, fields) => {
          const mark = Object.assign({ id: nextId('m'), do: 'motion3d', figure: id, target: state.id, targets, motion: kind },
            fields);
          push(mark, 0, 0);
          return h;
        };
        h.spin = (o = {}) => {
          const period = isNum(o.period) && o.period > 0 ? o.period : 60 / num(o.rpm, 30, -600, 600);
          return motion('spin', { axis: axisVector(o.axis, [0, 1, 0]), period: clamp(period, -600, 600),
            pivot: vec3(o.pivot, null) });
        };
        h.orbit = (o = {}) => motion('orbit', { axis: axisVector(o.axis, [0, 1, 0]), center: vec3(o.center, [0, 0, 0]),
          period: num(o.period, 6, -600, 600) || 6 });
        h.swing = (o = {}) => motion('swing', { axis: axisVector(o.axis, [0, 0, 1]), angle: num(o.angle, 25, -180, 180),
          period: num(o.period, 2, 0.05, 600), pivot: vec3(o.pivot, null) });
        h.bob = (o = {}) => motion('bob', { axis: axisVector(o.axis, [0, 1, 0]), amount: num(o.amount, 0.1, -10, 10),
          period: num(o.period, 2, 0.05, 600) });
        h.pulse = (o = {}) => motion('pulse', { amount: num(o.amount, 0.08, -0.5, 0.5), period: num(o.period, 1, 0.05, 600) });
        // The handle's own part glides exactly to `to` / `rot`. Its copies keep their places around it: each moves by
        // the same offset and turns in place by the same turn, and a mirrored copy does both as a mirror image.
        // `tos` / `rots` give every target its own end pose, in the order of `targets`.
        h.glide = (o = {}) => {
          const fields = { secs: num(o.secs, 0.8, 0.05, 30) };
          const to = vec3(o.to, null), rot = vec3(o.rot, null);
          const offset = to && sub(to, state.at);
          const turn = rot && quatMul(quatFromEuler(rot), quatInverse(quatFromEuler(state.rot)));
          const tos = [], rots = [];
          for (const partId of targets) {
            const part = fig.parts.get(partId);
            if (!part) {
              if (to) tos.push(to.slice());
              if (rot) rots.push(rot.slice());
              continue;
            }
            const s = part.mirror || [1, 1, 1];
            if (offset) {
              part.at = part === state ? to.slice() : add(part.at, [offset[0] * s[0], offset[1] * s[1], offset[2] * s[2]]);
              tos.push(part.at.slice());
            }
            if (turn) {
              const det = s[0] * s[1] * s[2];
              const reflected = [det * s[0] * turn[0], det * s[1] * turn[1], det * s[2] * turn[2], turn[3]];
              part.rot = part === state ? rot.slice() : eulerFromQuat(quatMul(reflected, quatFromEuler(part.rot)));
              rots.push(part.rot.slice());
            }
          }
          if (to) fields.to = to;
          if (rot) fields.rot = rot;
          if (targets.length > 1) {
            if (to) fields.tos = tos;
            if (rot) fields.rots = rots;
          }
          return motion('glide', fields);
        };
        h.stop = () => motion('stop', {});
        // Travel along points (in the parent's space) at an even speed: round and round, or once and stay at the end.
        h.path = (points, o = {}) => {
          if (points && !Array.isArray(points) && typeof points === 'object') { o = points; points = o.points; }
          const pts = (Array.isArray(points) ? points : []).slice(0, 200).map((p) => vec3(p, null)).filter(Boolean);
          if (pts.length < 2) { warn('path() needs at least 2 points'); return h; }
          const once = o.once === true;
          return motion('path', { points: pts, closed: once ? false : o.closed !== false && pts.length > 2,
            once, period: num(o.period, 6, 0.05, 600) });
        };

        const poseProp = (key, write) => Object.defineProperty(h, key, {
          enumerable: true,
          get: () => (state.pose.mask && state.pose[key] !== undefined ? state.pose[key] : state[key]),
          set: (value) => write(value),
        });
        const inTick = () => registry.inTick === true;
        poseProp('at', (v) => {
          const p = vec3(v, null); if (!p) return;
          if (inTick()) { state.pose.at = p; state.pose.mask |= 1; return; }
          state.at = p; motion('glide', { to: p, secs: 0.35, targets: [state.id] });
        });
        poseProp('rot', (v) => {
          const r = vec3(v, null); if (!r) return;
          if (inTick()) { state.pose.rot = r; state.pose.mask |= 2; return; }
          state.rot = r; motion('glide', { rot: r, secs: 0.35, targets: [state.id] });
        });
        poseProp('scale', (v) => {
          if (!isNum(v)) return; const s = Math.max(0, v);
          if (inTick()) { state.pose.scale = s; state.pose.mask |= 4; return; }
          state.scale = s; motion('set', { scale: s, targets: [state.id] });
        });
        poseProp('show', (v) => {
          const b = !!v;
          if (inTick()) { state.pose.show = b; state.pose.mask |= 8; return; }
          state.show = b; motion('set', { show: b, targets: [state.id] });
        });
        poseProp('glow', (v) => {
          if (!isNum(v)) return; const g = clamp(v, 0, 1);
          if (inTick()) { state.pose.glow = g; state.pose.mask |= 16; return; }
          state.glow = g; motion('set', { glow: g, targets: [state.id] });
        });
        poseProp('color', (v) => {
          const hex = colorHex(v, fig.ink, false); if (!hex) return;
          if (inTick()) { state.pose.color = hex; state.pose.mask |= 32; return; }
          state.color = hex; motion('set', { color: hex, targets: [state.id] });
        });
        return h;
      }

      for (const kind of PART_KINDS) f[kind] = (op) => makePart(kind, op);
      f.cyl = f.cylinder;
      f.polyhedron = f.poly;

      // A surface z = fn(u, v) sampled on a grid: `fn(u, v)` returns [x, y, z]; u and v run over `u` and `v`
      // ([0, 1] each) in `segments` × `rows` steps. A `grid` of rows of points can be given directly instead.
      f.surface = (fn, op) => {
        if (fn && typeof fn === 'object' && !Array.isArray(fn)) { op = fn; fn = op.fn; }
        op = Object.assign({}, op || {});
        let grid = Array.isArray(op.grid) ? op.grid : null;
        if (typeof fn === 'function') {
          const segments = Math.round(num(op.segments, 48, 4, 160));
          const rows = Math.round(num(op.rows, 16, 2, 80));
          const ur = Array.isArray(op.u) && op.u.length === 2 && op.u.every(isNum) ? op.u : [0, 1];
          const vr = Array.isArray(op.v) && op.v.length === 2 && op.v.every(isNum) ? op.v : [0, 1];
          const along = (range, t) => range[0] + (range[1] - range[0]) * t;
          // A sample that throws or isn't a point is a hole (null); points keep 3 decimals.
          const sample = (u, v) => {
            let point = null;
            try { point = vec3(fn(u, v), null); } catch (e) { point = null; }
            return point && point.map((c) => Math.round(c * 1000) / 1000);
          };
          grid = Array.from({ length: rows + 1 }, (_, j) =>
            Array.from({ length: segments + 1 }, (_, i) => sample(along(ur, i / segments), along(vr, j / rows))));
        }
        if (!grid) { warn('surface() needs a function (u, v) => [x, y, z] or a grid'); return null; }
        delete op.segments; delete op.rows; delete op.u; delete op.v; delete op.fn;
        op.grid = grid;
        // A surface has two sides worth seeing.
        if (op.double === undefined) op.double = true;
        return makePart('surface', op);
      };
      f.ball = f.sphere;

      f.group = (op, fn) => {
        if (typeof op === 'function') { fn = op; op = {}; }
        const g = makePart('group', op || {});
        if (typeof fn === 'function') {
          const saved = fig.defaultParent;
          fig.defaultParent = g.id;
          try { fn(g); } finally { fig.defaultParent = saved; }
        }
        return g;
      };

      f.part = (ref) => {
        const state = lookup(ref);
        return state ? handleFor(state) : null;
      };

      // Same as part.glide(o); a handle with copies moves them all.
      f.move = (part, o) => {
        const state = lookup(part);
        if (!state) { warn('move(): unknown part'); return null; }
        const copies = part && typeof part === 'object' && Array.isArray(part.copies) ? part.copies : null;
        return handleFor(state, copies).glide(o || {});
      };

      f.label = (target, text, o = {}) => {
        if (text === undefined || text === null || String(text).trim() === '') return null;
        const str = String(text).trim().slice(0, 60);
        let point = null, follow = null;
        const state = lookup(target);
        if (state) follow = state.id;
        else point = vec3(target, [0, 0, 0]);
        const side = o.side === 'left' || o.side === 'right' ? o.side : null;
        const mark = { id: nextId('l'), do: 'label3d', figure: id, text: str, point, follow, side,
          size: num(o.size, 17, 13, 28) };
        push(mark, 0.4 + 0.015 * str.length, 0.3 + 0.01 * str.length);
        return { id: mark.id, kind: 'label' };
      };

      f.tick = (fn) => {
        if (typeof fn !== 'function') { warn('tick() needs a function'); return null; }
        const tickId = nextId('t');
        fig.ticks.set(tickId, { fn, strikes: 0 });
        push({ id: tickId, do: 'tick3d', figure: id }, 0, 0);
        return { id: tickId, kind: 'tick' };
      };

      f.readout = (values) => {
        if (!values || typeof values !== 'object') return f;
        for (const key of Object.keys(values)) {
          const k = String(key).slice(0, 24);
          const v = values[key];
          if (v === null || v === undefined) { delete fig.readouts[k]; continue; }
          if (!(k in fig.readouts) && Object.keys(fig.readouts).length >= 6) continue;
          fig.readouts[k] = String(typeof v === 'number' ? +v.toFixed(3) : v).slice(0, 32);
        }
        if (registry.inTick) registry.dirtyReadouts.add(id);
        else push({ id: nextId('r'), do: 'readout3d', figure: id, values: Object.assign({}, fig.readouts) }, 0, 0);
        return f;
      };

      f.view = (o = {}) => {
        const mark = { id: nextId('c'), do: 'camera3d', figure: id, secs: num(o.secs, 1, 0, 30) };
        if (isNum(o.tilt)) mark.tilt = clamp(o.tilt, -80, 80);
        if (isNum(o.turn)) mark.turn = clamp(o.turn, -180, 180);
        if (isNum(o.spin)) mark.spin = clamp(o.spin, 0, 12);
        if (isNum(o.zoom)) mark.zoom = clamp(o.zoom, 0.5, 3);
        if (isNum(o.fov)) mark.fov = clamp(o.fov, 15, 70);
        const target = vec3(o.target, null);
        if (target) mark.target = target;
        push(mark, 0, 0);
        return f;
      };
      f.camera = f.view;
      f.describe = () => registry.describe(id);
      return f;
    }

    api.figure = figure;
  });
})();
