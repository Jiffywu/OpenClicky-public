// OpenClicky 3D geometry kernel: turns a figure part's recipe into packed typed arrays.
//
// Runs in its own JavaScriptCore context (FigureKernel.swift) after three-slice.js, the geometry-only build of
// three.js. Entry points:
//   ocKernelKinds                      -> the part kinds this kernel builds
//   ocKernelBuild(kind, recipeJSON)    -> { positions, normals, uvs: Float32Array, indices: Uint32Array,
//                                          samples: Float32Array (framing points), bounds: [min xyz, max xyz] }
// Recipes are described in docs/dsl-3d.md. Everything here is plain math with no allocation per sample in the hot
// loops, so it stays quick even when the context runs without the JIT.
(function () {
  'use strict';
  const T = globalThis.OCThree;
  if (!T) throw new Error('three-slice.js must be loaded before three-kernel.js');

  const MAX_VERTICES = 150000;
  const MAX_SAMPLES = 512;
  const BLOB_FIELD_BUDGET = 1.2e6;
  const MAX_OUTLINE_POINTS = 3000;
  const TAU = Math.PI * 2;
  const DEG = Math.PI / 180;

  // ---- recipe readers --------------------------------------------------------------------------------------

  const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const num = (v, fallback, lo, hi) => clamp(isNum(v) ? v : fallback, lo === undefined ? -Infinity : lo, hi === undefined ? Infinity : hi);
  const int = (v, fallback, lo, hi) => Math.round(num(v, fallback, lo, hi));
  const vec3 = (v, fallback) => (Array.isArray(v) && v.length >= 3 && isNum(v[0]) && isNum(v[1]) && isNum(v[2]) ? [v[0], v[1], v[2]] : fallback);
  const points3 = (list, max, fallback) => {
    const out = Array.isArray(list) ? list.slice(0, max).map((p) => vec3(p, null)).filter(Boolean) : [];
    return out.length >= 2 ? out : fallback;
  };
  const points2 = (list, max) => (Array.isArray(list) ? list.slice(0, max)
    .filter((p) => Array.isArray(p) && isNum(p[0]) && isNum(p[1])).map((p) => [p[0], p[1]]) : []);
  const AXIS_NAMES = { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] };
  /** "x", "-z", "+y" or a vector -> a unit Vector3; anything else -> null. */
  function axisVector(spec) {
    if (typeof spec === 'string') {
      const word = spec.replace(/\s+/g, '').toLowerCase();
      const negative = word.startsWith('-');
      const named = AXIS_NAMES[/^[+-]/.test(word) ? word.slice(1) : word];
      if (!named) return null;
      // `+ 0` keeps the untouched components at +0 rather than -0.
      return new T.Vector3(...named.map((c) => (negative ? -c : c) + 0));
    }
    const a = vec3(spec, null);
    if (!a) return null;
    const v = new T.Vector3(a[0], a[1], a[2]);
    return v.lengthSq() > 1e-12 ? v.normalize() : null;
  }
  const sweep = (r) => (isNum(r.arc) ? clamp(r.arc, 1, 360) : 360);

  // ---- geometry assembly -----------------------------------------------------------------------------------

  /** A growable mesh in plain arrays; becomes a BufferGeometry at the end. */
  class Builder {
    constructor() { this.p = []; this.n = []; this.uv = []; this.idx = []; }
    get count() { return this.p.length / 3; }
    vertex(x, y, z, nx, ny, nz, u, v) {
      this.p.push(x, y, z); this.n.push(nx, ny, nz); this.uv.push(u, v);
      return this.p.length / 3 - 1;
    }
    tri(a, b, c) { this.idx.push(a, b, c); }
    geometry() {
      const g = new T.BufferGeometry();
      g.setAttribute('position', new T.Float32BufferAttribute(this.p, 3));
      g.setAttribute('normal', new T.Float32BufferAttribute(this.n, 3));
      g.setAttribute('uv', new T.Float32BufferAttribute(this.uv, 2));
      g.setIndex(this.idx);
      return g;
    }
  }

  /** Same attribute set on every geometry (position, normal, uv), indexed, so pieces can be merged. */
  function normalise(g) {
    if (!g.getAttribute('normal')) g.computeVertexNormals();
    if (!g.getAttribute('uv')) g.setAttribute('uv', new T.Float32BufferAttribute(new Float32Array(g.getAttribute('position').count * 2), 2));
    for (const name of Object.keys(g.attributes)) if (name !== 'position' && name !== 'normal' && name !== 'uv') g.deleteAttribute(name);
    if (!g.index) {
      // Corners shared by neighbouring triangles (same position, normal and uv) become one vertex.
      g = T.mergeVertices(g, 1e-5);
    }
    if (!g.index) {
      const count = g.getAttribute('position').count;
      const idx = new Uint32Array(count);
      for (let i = 0; i < count; i++) idx[i] = i;
      g.setIndex(new T.BufferAttribute(idx, 1));
    }
    g.clearGroups();
    return g;
  }

  function merge(geometries) {
    const parts = geometries.filter(Boolean).map(normalise);
    if (parts.length === 1) return parts[0];
    const merged = T.mergeGeometries(parts, false);
    if (!merged) throw new Error('could not merge part pieces');
    return merged;
  }

  // ---- fillets ---------------------------------------------------------------------------------------------

  /**
   * Replace chosen corners of a polyline (points as [x, y, z] arrays) with circular arcs tangent to both edges.
   * `radii[i]` is the wanted radius at corner i (0 keeps it sharp); each is shrunk so neighbouring arcs never
   * overlap. Works for 2D outlines too (z = 0).
   */
  function fillet(points, radii, steps, closed) {
    const n = points.length;
    const out = [];
    for (let i = 0; i < n; i++) {
      const p = points[i];
      const hasPrev = closed || i > 0, hasNext = closed || i < n - 1;
      const radius = radii[i] || 0;
      if (!hasPrev || !hasNext || radius <= 5e-4) { out.push(p); continue; }
      const a = points[(i - 1 + n) % n], b = points[(i + 1) % n];
      const ua = [a[0] - p[0], a[1] - p[1], a[2] - p[2]], ub = [b[0] - p[0], b[1] - p[1], b[2] - p[2]];
      const la = Math.hypot(ua[0], ua[1], ua[2]), lb = Math.hypot(ub[0], ub[1], ub[2]);
      if (la < 1e-9 || lb < 1e-9) { out.push(p); continue; }
      for (let k = 0; k < 3; k++) { ua[k] /= la; ub[k] /= lb; }
      const cosPhi = clamp(ua[0] * ub[0] + ua[1] * ub[1] + ua[2] * ub[2], -1, 1);
      const phi = Math.acos(cosPhi);
      if (phi > Math.PI - 1e-3 || phi < 1e-3) { out.push(p); continue; }
      // An edge shared with another rounded corner gives each half; an edge ending at a sharp point gives almost all.
      const share = (j) => ((closed || (j > 0 && j < n - 1)) && (radii[j] || 0) > 5e-4 ? 0.5 : 0.95);
      const d = Math.min(radius / Math.tan(phi / 2), la * share((i - 1 + n) % n), lb * share((i + 1) % n));
      const rho = d * Math.tan(phi / 2);
      const bis = [ua[0] + ub[0], ua[1] + ub[1], ua[2] + ub[2]];
      const bl = Math.hypot(bis[0], bis[1], bis[2]);
      const h = rho / Math.sin(phi / 2);
      const c = [p[0] + bis[0] / bl * h, p[1] + bis[1] / bl * h, p[2] + bis[2] / bl * h];
      const t1 = [p[0] + ua[0] * d, p[1] + ua[1] * d, p[2] + ua[2] * d];
      const t2 = [p[0] + ub[0] * d, p[1] + ub[1] * d, p[2] + ub[2] * d];
      const v1 = [t1[0] - c[0], t1[1] - c[1], t1[2] - c[2]], v2 = [t2[0] - c[0], t2[1] - c[1], t2[2] - c[2]];
      const sweepAngle = Math.PI - phi;
      for (let s = 0; s <= steps; s++) {
        const t = s / steps;
        // Spherical interpolation between the two radius vectors keeps the arc circular.
        const w1 = Math.sin((1 - t) * sweepAngle) / Math.sin(sweepAngle), w2 = Math.sin(t * sweepAngle) / Math.sin(sweepAngle);
        out.push([c[0] + v1[0] * w1 + v2[0] * w2, c[1] + v1[1] * w1 + v2[1] * w2, c[2] + v1[2] * w1 + v2[2] * w2]);
      }
    }
    return out;
  }

  const FILLET_STEPS = 6;

  // ---- surfaces of revolution ------------------------------------------------------------------------------

  /** Signed area of a profile in the (radius, y) plane, closed along the axis unless `closed`. */
  function profileArea(profile, closed) {
    const ring = closed ? profile : profile.concat([[0, profile[profile.length - 1][1]], [0, profile[0][1]]]);
    let area = 0;
    for (let i = 0; i < ring.length; i++) {
      const a = ring[i], b = ring[(i + 1) % ring.length];
      area += a[0] * b[1] - b[0] * a[1];
    }
    return area / 2;
  }

  /**
   * Turn a profile of [radius, y] points around the y axis. Corners sharper than `crease` degrees keep hard
   * edges; gentler bends are smoothed. A partial `arc` gets flat caps on both open sides. The profile is put in
   * counter-clockwise order first so faces always point outward.
   */
  function revolve(profileIn, options) {
    const seg = int(options.seg, 48, 3, 160);
    const arc = (options.arc === undefined ? 360 : options.arc) * DEG;
    const closed = !!options.closed;
    const crease = Math.cos((options.crease === undefined ? 40 : options.crease) * DEG);
    let profile = [];
    for (const p of profileIn) {
      const q = [Math.max(0, p[0]), p[1]];
      const last = profile[profile.length - 1];
      if (!last || Math.hypot(last[0] - q[0], last[1] - q[1]) > 1e-7) profile.push(q);
    }
    if (closed && profile.length > 2) {
      const a = profile[0], b = profile[profile.length - 1];
      if (Math.hypot(a[0] - b[0], a[1] - b[1]) < 1e-7) profile.pop();
    }
    if (profile.length < 2) throw new Error('profile needs at least 2 distinct points');
    if (profileArea(profile, closed) < 0) profile.reverse();

    const m = profile.length;
    const segCount = closed ? m : m - 1;
    // Outward normal of each profile segment, in (r, y).
    const segN = [];
    let totalLength = 0;
    const segLen = [];
    for (let i = 0; i < segCount; i++) {
      const a = profile[i], b = profile[(i + 1) % m];
      const dr = b[0] - a[0], dy = b[1] - a[1];
      const l = Math.hypot(dr, dy);
      segN.push([dy / l, -dr / l]);
      segLen.push(l);
      totalLength += l;
    }
    // Rows: one per profile point; a crease emits the point twice, once with each side's normal, and only the
    // second starts a new strip. A closed ring repeats its first point at the end so the strip wraps around.
    const rows = [];
    let along = 0;
    const last = closed ? m : m - 1;
    for (let i = 0; i <= last; i++) {
      const p = profile[i % m];
      const v = along / totalLength;
      const prevSeg = i > 0 ? i - 1 : closed ? segCount - 1 : -1;
      const nextSeg = i < segCount ? i : closed ? 0 : -1;
      const nb = prevSeg >= 0 ? segN[prevSeg] : null;
      const na = nextSeg >= 0 ? segN[nextSeg] : null;
      const smooth = nb && na && nb[0] * na[0] + nb[1] * na[1] >= crease;
      let avg = null;
      if (smooth) {
        const sr = nb[0] + na[0], sy = nb[1] + na[1], sl = Math.hypot(sr, sy) || 1;
        avg = [sr / sl, sy / sl];
      }
      const startsStrip = i === 0;
      const endsStrip = i === last;
      if (!startsStrip) rows.push({ r: p[0], y: p[1], nr: (avg || nb)[0], ny: (avg || nb)[1], v, joinPrev: true });
      if (!endsStrip && (startsStrip || !smooth)) rows.push({ r: p[0], y: p[1], nr: (avg || na)[0], ny: (avg || na)[1], v, joinPrev: false });
      if (i < segCount) along += segLen[i];
    }

    const b = new Builder();
    const start = options.arcStart === undefined ? 0 : options.arcStart;
    const sinT = new Float64Array(seg + 1), cosT = new Float64Array(seg + 1);
    for (let j = 0; j <= seg; j++) {
      const t = start + (j / seg) * arc;
      sinT[j] = Math.sin(t); cosT[j] = Math.cos(t);
    }
    const base = [];
    for (const row of rows) {
      base.push(b.count);
      for (let j = 0; j <= seg; j++) {
        b.vertex(row.r * sinT[j], row.y, row.r * cosT[j], row.nr * sinT[j], row.ny, row.nr * cosT[j], j / seg, row.v);
      }
    }
    for (let k = 1; k < rows.length; k++) {
      if (!rows[k].joinPrev) continue;
      const lower = rows[k - 1], upper = rows[k];
      const a0 = base[k - 1], b0 = base[k];
      for (let j = 0; j < seg; j++) {
        const aj = a0 + j, aj1 = a0 + j + 1, bj = b0 + j, bj1 = b0 + j + 1;
        if (lower.r > 1e-9) b.tri(aj, aj1, bj1);
        if (upper.r > 1e-9) b.tri(aj, bj1, bj);
      }
    }

    if (arc < TAU - 1e-6) {
      // Cap both open sides with the profile polygon (closed along the axis for open profiles).
      const outline = closed ? profile.slice() : profile.concat(profile[m - 1][0] > 1e-9 ? [[0, profile[m - 1][1]]] : [])
        .concat(profile[0][0] > 1e-9 ? [[0, profile[0][1]]] : []);
      const contour = outline.map((p) => new T.Vector2(p[0], p[1]));
      const faces = T.ShapeUtils.triangulateShape(contour, []);
      for (const side of [0, 1]) {
        const t = start + side * arc;
        const s = Math.sin(t), c = Math.cos(t);
        // Direction of increasing angle is (cos t, 0, -sin t); the start cap faces against it.
        const sign = side === 0 ? -1 : 1;
        const nx = sign * c, nz = -sign * s;
        const first = b.count;
        for (const p of outline) b.vertex(p[0] * s, p[1], p[0] * c, nx, 0, nz, p[0], p[1]);
        for (const f of faces) {
          const i0 = first + f[0], i1 = first + f[1], i2 = first + f[2];
          if (facesAlong(b, i0, i1, i2, nx, 0, nz)) b.tri(i0, i1, i2); else b.tri(i0, i2, i1);
        }
      }
    }
    return b.geometry();
  }

  /** Whether triangle (i0, i1, i2) of a Builder winds counter-clockwise when seen from direction n. */
  function facesAlong(b, i0, i1, i2, nx, ny, nz) {
    const p = b.p;
    const ax = p[i1 * 3] - p[i0 * 3], ay = p[i1 * 3 + 1] - p[i0 * 3 + 1], az = p[i1 * 3 + 2] - p[i0 * 3 + 2];
    const bx = p[i2 * 3] - p[i0 * 3], by = p[i2 * 3 + 1] - p[i0 * 3 + 1], bz = p[i2 * 3 + 2] - p[i0 * 3 + 2];
    return (ay * bz - az * by) * nx + (az * bx - ax * bz) * ny + (ax * by - ay * bx) * nz >= 0;
  }

  /** A flat disc closing the ring of vertices `ring` (Vector3s), facing `normal`. */
  function capDisc(ring, center, normal) {
    const b = new Builder();
    const c = b.vertex(center.x, center.y, center.z, normal.x, normal.y, normal.z, 0.5, 0.5);
    const first = b.count;
    ring.forEach((p, i) => b.vertex(p.x, p.y, p.z, normal.x, normal.y, normal.z, i / ring.length, 1));
    for (let i = 0; i < ring.length - 1; i++) {
      const i1 = first + i, i2 = first + i + 1;
      if (facesAlong(b, c, i1, i2, normal.x, normal.y, normal.z)) b.tri(c, i1, i2); else b.tri(c, i2, i1);
    }
    return b.geometry();
  }

  /** TubeGeometry along a curve, with flat caps when the ends are open. */
  function tubeAlong(curve, tubular, radius, radial, closed) {
    const tube = new T.TubeGeometry(curve, tubular, radius, radial, closed);
    if (closed) return tube;
    const pos = tube.getAttribute('position');
    const ring = (row) => {
      const out = [];
      for (let j = 0; j <= radial; j++) out.push(new T.Vector3().fromBufferAttribute(pos, row * (radial + 1) + j));
      return out;
    };
    const start = curve.getPointAt(0), end = curve.getPointAt(1);
    const startCap = capDisc(ring(0), start, curve.getTangentAt(0).negate());
    const endCap = capDisc(ring(tubular), end, curve.getTangentAt(1));
    return merge([tube, startCap, endCap]);
  }

  /** A polyline with rounded elbows, parameterised by arc length. */
  class ElbowCurve extends T.Curve {
    constructor(points, radius, closed) {
      super();
      const dense = fillet(points, points.map(() => radius), 8, closed);
      if (closed) dense.push(dense[0]);
      this.pts = dense;
      this.acc = [0];
      for (let i = 1; i < dense.length; i++) {
        const a = dense[i - 1], b = dense[i];
        this.acc.push(this.acc[i - 1] + Math.hypot(b[0] - a[0], b[1] - a[1], b[2] - a[2]));
      }
    }
    getPoint(t, target = new T.Vector3()) {
      const total = this.acc[this.acc.length - 1];
      const d = clamp(t, 0, 1) * total;
      let lo = 0, hi = this.acc.length - 1;
      while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (this.acc[mid] <= d) lo = mid; else hi = mid; }
      const span = this.acc[hi] - this.acc[lo] || 1;
      const f = (d - this.acc[lo]) / span;
      const a = this.pts[lo], b = this.pts[hi];
      return target.set(a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f);
    }
  }

  /** The first `fraction` of another curve, by arc length. */
  class HeadlessCurve extends T.Curve {
    constructor(curve, fraction) { super(); this.curve = curve; this.fraction = fraction; }
    getPoint(t, target = new T.Vector3()) { return this.curve.getPointAt(clamp(t, 0, 1) * this.fraction, target); }
  }

  class Helix extends T.Curve {
    constructor(radius, height, turns) { super(); this.r = radius; this.h = height; this.turns = turns; }
    getPoint(t, target = new T.Vector3()) {
      const a = TAU * this.turns * t;
      return target.set(this.r * Math.cos(a), -this.h / 2 + this.h * t, -this.r * Math.sin(a));
    }
  }

  // ---- SVG path data -> ShapePath ------------------------------------------------------------------------

  // How many numbers each path command takes per use. A command letter followed by more numbers repeats.
  const PATH_ARITY = { M: 2, L: 2, T: 2, H: 1, V: 1, S: 4, Q: 4, C: 6, A: 7, Z: 0 };
  const PATH_GROUP = /([MLHVCSQTAZ])([^MLHVCSQTAZ]*)/gi;
  const PATH_NUMBER = /[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g;
  const MAX_PATH_COMMANDS = 20000;

  /**
   * Split path data into single commands, each with exactly its own numbers: `{ op: 'C', relative, args }`.
   * Extra coordinate pairs after a move become lines; a set left incomplete at the end of a group is dropped.
   */
  function pathCommands(d) {
    const commands = [];
    for (const [, letter, rest] of String(d).slice(0, 20000).matchAll(PATH_GROUP)) {
      const op = letter.toUpperCase();
      const relative = letter !== op;
      const size = PATH_ARITY[op];
      if (size === 0) { commands.push({ op, relative, args: [] }); continue; }
      const numbers = (rest.match(PATH_NUMBER) || []).map(Number);
      for (let k = 0; k + size <= numbers.length && commands.length < MAX_PATH_COMMANDS; k += size) {
        commands.push({ op: op === 'M' && k > 0 ? 'L' : op, relative, args: numbers.slice(k, k + size) });
      }
    }
    return commands;
  }

  /** SVG path data (all commands, either case) -> a three ShapePath in figure units. SVG's y runs down, ours up. */
  function parseSvgPath(d, unit) {
    const path = new T.ShapePath();
    const X = (v) => v * unit, Y = (v) => -v * unit;
    let pen = [0, 0], figureStart = [0, 0], control = null, previous = '';
    for (const { op, relative, args } of pathCommands(d)) {
      const origin = relative ? pen : [0, 0];
      const point = (k) => [origin[0] + args[k], origin[1] + args[k + 1]];
      // S and T reuse the last control point mirrored through the pen, if the command before was the same kind.
      const reflected = (kinds) => (kinds.includes(previous) && control ? [2 * pen[0] - control[0], 2 * pen[1] - control[1]] : pen);
      switch (op) {
        case 'M':
          pen = point(0);
          figureStart = pen;
          path.moveTo(X(pen[0]), Y(pen[1]));
          break;
        case 'L':
          pen = point(0);
          path.lineTo(X(pen[0]), Y(pen[1]));
          break;
        case 'H':
          pen = [origin[0] + args[0], pen[1]];
          path.lineTo(X(pen[0]), Y(pen[1]));
          break;
        case 'V':
          pen = [pen[0], origin[1] + args[0]];
          path.lineTo(X(pen[0]), Y(pen[1]));
          break;
        case 'C':
        case 'S': {
          const first = op === 'C' ? point(0) : reflected('CS');
          const second = op === 'C' ? point(2) : point(0);
          const end = op === 'C' ? point(4) : point(2);
          path.bezierCurveTo(X(first[0]), Y(first[1]), X(second[0]), Y(second[1]), X(end[0]), Y(end[1]));
          control = second;
          pen = end;
          break;
        }
        case 'Q':
        case 'T': {
          const handle = op === 'Q' ? point(0) : reflected('QT');
          const end = op === 'Q' ? point(2) : point(0);
          path.quadraticCurveTo(X(handle[0]), Y(handle[1]), X(end[0]), Y(end[1]));
          control = handle;
          pen = end;
          break;
        }
        case 'A': {
          const end = point(5);
          ellipticalArc(path, pen, end, args[0], args[1], args[2], args[3] !== 0, args[4] !== 0, X, Y);
          pen = end;
          break;
        }
        case 'Z':
          pen = figureStart;
          if (path.currentPath) path.currentPath.closePath();
          break;
      }
      previous = op;
    }
    return path;
  }

  /**
   * An SVG elliptical arc given by its end points, drawn as cubic Béziers of at most a quarter turn each. The centre
   * and angles come from the endpoint-to-centre conversion in the SVG 1.1 implementation notes (appendix F.6).
   */
  function ellipticalArc(path, from, to, radiusX, radiusY, tiltDegrees, largeArc, positiveSweep, X, Y) {
    let rx = Math.abs(radiusX), ry = Math.abs(radiusY);
    if (from[0] === to[0] && from[1] === to[1]) return;  // nothing to draw
    if (rx < 1e-9 || ry < 1e-9) { path.lineTo(X(to[0]), Y(to[1])); return; }
    const cos = Math.cos(tiltDegrees * DEG), sin = Math.sin(tiltDegrees * DEG);
    // Half the chord, in the ellipse's own (untilted) frame.
    const halfX = (from[0] - to[0]) / 2, halfY = (from[1] - to[1]) / 2;
    const u = cos * halfX + sin * halfY, w = cos * halfY - sin * halfX;
    // Radii too short to span the chord grow just enough.
    const stretch = (u * u) / (rx * rx) + (w * w) / (ry * ry);
    if (stretch > 1) { rx *= Math.sqrt(stretch); ry *= Math.sqrt(stretch); }
    const rx2 = rx * rx, ry2 = ry * ry, uu = u * u, ww = w * w;
    const ratio = Math.max(0, rx2 * ry2 - rx2 * ww - ry2 * uu) / (rx2 * ww + ry2 * uu);
    const along = (largeArc === positiveSweep ? -1 : 1) * Math.sqrt(ratio);
    // The centre, first in the ellipse's frame, then on the page.
    const centreU = (along * rx * w) / ry, centreW = (-along * ry * u) / rx;
    const cx = cos * centreU - sin * centreW + (from[0] + to[0]) / 2;
    const cy = sin * centreU + cos * centreW + (from[1] + to[1]) / 2;
    // Start angle and sweep on the unit circle the ellipse is stretched from.
    const startAngle = Math.atan2((w - centreW) / ry, (u - centreU) / rx);
    let turn = Math.atan2((-w - centreW) / ry, (-u - centreU) / rx) - startAngle;
    if (positiveSweep && turn < 0) turn += TAU;
    else if (!positiveSweep && turn > 0) turn -= TAU;
    const pieces = Math.max(1, Math.ceil(Math.abs(turn) / (Math.PI / 2) - 1e-6));
    const span = turn / pieces;
    const handle = (4 / 3) * Math.tan(span / 4);
    const at = (angle) => {
      const a = rx * Math.cos(angle), b = ry * Math.sin(angle);
      return [cx + cos * a - sin * b, cy + sin * a + cos * b];
    };
    const direction = (angle) => {
      const a = -rx * Math.sin(angle), b = ry * Math.cos(angle);
      return [cos * a - sin * b, sin * a + cos * b];
    };
    for (let piece = 0; piece < pieces; piece++) {
      const a0 = startAngle + piece * span, a1 = a0 + span;
      const p0 = at(a0), p1 = at(a1), d0 = direction(a0), d1 = direction(a1);
      path.bezierCurveTo(X(p0[0] + handle * d0[0]), Y(p0[1] + handle * d0[1]),
        X(p1[0] - handle * d1[0]), Y(p1[1] - handle * d1[1]), X(p1[0]), Y(p1[1]));
    }
  }

  // ---- soft shapes (blob) ----------------------------------------------------------------------------------

  /**
   * Metaball-style blob: balls and tapered sticks melted together with a smooth minimum of their distance
   * fields, meshed with surface nets (one vertex per surface cell at the mean of its edge crossings).
   */
  function softShape(recipe) {
    // Balls as {centre, radius}; sticks as {start, end - start, radius at the start, radius at the end}.
    const balls = [];
    const sticks = [];
    for (const ball of (Array.isArray(recipe.balls) ? recipe.balls : []).slice(0, 64)) {
      const centre = Array.isArray(ball) ? vec3(ball, null) : ball && vec3(ball.at, null);
      const radius = Array.isArray(ball) ? ball[3] : ball && ball.r;
      if (centre && isNum(radius) && radius > 0) balls.push({ centre, radius });
    }
    for (const stick of (Array.isArray(recipe.sticks) ? recipe.sticks : []).slice(0, 64)) {
      let start = null, end = null, r1, r2;
      if (Array.isArray(stick) && Array.isArray(stick[0])) {
        // [[x1, y1, z1], [x2, y2, z2], r1, r2]
        [start, end, r1, r2] = [vec3(stick[0], null), vec3(stick[1], null), stick[2], stick[3]];
      } else if (Array.isArray(stick) && stick.length >= 7) {
        // [x1, y1, z1, x2, y2, z2, r1, r2]
        [start, end, r1, r2] = [vec3(stick.slice(0, 3), null), vec3(stick.slice(3, 6), null), stick[6], stick[7]];
      } else if (stick && typeof stick === 'object') {
        [start, end, r1, r2] = [vec3(stick.from, null), vec3(stick.to, null), stick.r, stick.r2];
      }
      if (!start || !end || !isNum(r1) || r1 <= 0) continue;
      const span = [end[0] - start[0], end[1] - start[1], end[2] - start[2]];
      sticks.push({ start, span, r1, r2: Math.max(1e-3, isNum(r2) ? r2 : r1) });
    }
    if (!balls.length && !sticks.length) throw new Error('blob needs balls or sticks');
    const radiusSum = balls.reduce((s, b) => s + b.radius, 0) + sticks.reduce((s, q) => s + (q.r1 + q.r2) / 2, 0);
    const meanR = radiusSum / (balls.length + sticks.length);
    const k = num(recipe.smooth, 0.5 * meanR, 0, 4 * meanR);

    // Flat arrays for the hot loop: 4 numbers per ball, 9 per stick (start, span, |span|², r1, r2).
    const ballData = new Float64Array(balls.length * 4);
    balls.forEach((b, n) => ballData.set([b.centre[0], b.centre[1], b.centre[2], b.radius], n * 4));
    const stickData = new Float64Array(sticks.length * 9);
    sticks.forEach((q, n) => {
      const s = q.span;
      stickData.set([q.start[0], q.start[1], q.start[2], s[0], s[1], s[2], s[0] * s[0] + s[1] * s[1] + s[2] * s[2], q.r1, q.r2], n * 9);
    });
    // Signed distance (negative inside) to everything, melted together with a polynomial smooth minimum of width k.
    const meld = k > 0
      ? (sofar, d) => { const h = Math.max(k - Math.abs(sofar - d), 0) / k; return Math.min(sofar, d) - h * h * k * 0.25; }
      : (sofar, d) => Math.min(sofar, d);
    const field = (x, y, z) => {
      let nearest = 1e9;
      for (let o = 0; o < ballData.length; o += 4) {
        nearest = meld(nearest, Math.hypot(x - ballData[o], y - ballData[o + 1], z - ballData[o + 2]) - ballData[o + 3]);
      }
      for (let o = 0; o < stickData.length; o += 9) {
        const qx = x - stickData[o], qy = y - stickData[o + 1], qz = z - stickData[o + 2];
        const sx = stickData[o + 3], sy = stickData[o + 4], sz = stickData[o + 5], length2 = stickData[o + 6];
        const t = length2 > 1e-12 ? clamp((qx * sx + qy * sy + qz * sz) / length2, 0, 1) : 0;
        const r1 = stickData[o + 7];
        nearest = meld(nearest, Math.hypot(qx - sx * t, qy - sy * t, qz - sz * t) - (r1 + (stickData[o + 8] - r1) * t));
      }
      return nearest;
    };

    // The sampled box: every ball and both ends of every stick, padded so the melted surface fits inside.
    const reach = balls.map((b) => [b.centre, b.radius]).concat(...sticks.map((q) => {
      const r = Math.max(q.r1, q.r2), end = [q.start[0] + q.span[0], q.start[1] + q.span[1], q.start[2] + q.span[2]];
      return [[q.start, r], [end, r]];
    }));
    const pad = k * 0.5 + meanR * 0.3;
    const lo = [0, 1, 2].map((axis) => Math.min(...reach.map(([c, r]) => c[axis] - r)) - pad);
    const hi = [0, 1, 2].map((axis) => Math.max(...reach.map(([c, r]) => c[axis] + r)) + pad);
    const longest = Math.max(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]);
    // Every grid sample measures every primitive, so a blob of many primitives gets a coarser grid. That keeps the
    // work to about a million distance checks, and a 128-primitive blob builds in seconds even without the JIT.
    const affordable = Math.floor(Math.cbrt(BLOB_FIELD_BUDGET / (balls.length + sticks.length)));
    const cells = Math.max(12, Math.min(int(recipe.res, 44, 12, 72), affordable));
    const h = longest / cells;
    const nx = Math.ceil((hi[0] - lo[0]) / h) + 1, ny = Math.ceil((hi[1] - lo[1]) / h) + 1, nz = Math.ceil((hi[2] - lo[2]) / h) + 1;
    const values = new Float32Array(nx * ny * nz);
    const at = (i, j, l) => i + nx * (j + ny * l);
    for (let l = 0; l < nz; l++) for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) {
      values[at(i, j, l)] = field(lo[0] + i * h, lo[1] + j * h, lo[2] + l * h);
    }

    const b = new Builder();
    const cellVertex = new Int32Array((nx - 1) * (ny - 1) * (nz - 1)).fill(-1);
    const cellAt = (i, j, l) => i + (nx - 1) * (j + (ny - 1) * l);
    const EDGES = [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]];
    const corner = new Float64Array(8);
    const e = h * 0.5;
    for (let l = 0; l < nz - 1; l++) for (let j = 0; j < ny - 1; j++) for (let i = 0; i < nx - 1; i++) {
      let inside = 0;
      for (let c = 0; c < 8; c++) {
        corner[c] = values[at(i + (c & 1), j + ((c >> 1) & 1), l + ((c >> 2) & 1))];
        if (corner[c] < 0) inside++;
      }
      if (inside === 0 || inside === 8) continue;
      let sx = 0, sy = 0, sz = 0, crossings = 0;
      for (const [c0, c1] of EDGES) {
        const v0 = corner[c0], v1 = corner[c1];
        if ((v0 < 0) === (v1 < 0)) continue;
        const t = v0 / (v0 - v1);
        sx += (c0 & 1) + ((c1 & 1) - (c0 & 1)) * t;
        sy += ((c0 >> 1) & 1) + (((c1 >> 1) & 1) - ((c0 >> 1) & 1)) * t;
        sz += ((c0 >> 2) & 1) + (((c1 >> 2) & 1) - ((c0 >> 2) & 1)) * t;
        crossings++;
      }
      const px = lo[0] + (i + sx / crossings) * h, py = lo[1] + (j + sy / crossings) * h, pz = lo[2] + (l + sz / crossings) * h;
      // Tetrahedral gradient: four samples are enough for a smooth normal.
      const f1 = field(px + e, py - e, pz - e), f2 = field(px - e, py - e, pz + e);
      const f3 = field(px - e, py + e, pz - e), f4 = field(px + e, py + e, pz + e);
      let gx = f1 - f2 - f3 + f4, gy = -f1 - f2 + f3 + f4, gz = -f1 + f2 - f3 + f4;
      const gl = Math.hypot(gx, gy, gz) || 1;
      gx /= gl; gy /= gl; gz /= gl;
      cellVertex[cellAt(i, j, l)] = b.vertex(px, py, pz, gx, gy, gz, 0, 0);
    }
    // One quad around every grid edge whose ends straddle the surface, wound so it faces along the gradient.
    const quad = (a, c, d, f, inward) => {
      if (a < 0 || c < 0 || d < 0 || f < 0) return;
      if (inward) { b.tri(a, c, d); b.tri(a, d, f); } else { b.tri(a, d, c); b.tri(a, f, d); }
    };
    for (let l = 1; l < nz - 1; l++) for (let j = 1; j < ny - 1; j++) for (let i = 0; i < nx - 1; i++) {
      const v0 = values[at(i, j, l)], v1 = values[at(i + 1, j, l)];
      if ((v0 < 0) === (v1 < 0)) continue;
      quad(cellVertex[cellAt(i, j - 1, l - 1)], cellVertex[cellAt(i, j, l - 1)], cellVertex[cellAt(i, j, l)], cellVertex[cellAt(i, j - 1, l)], v0 < 0);
    }
    for (let l = 1; l < nz - 1; l++) for (let j = 0; j < ny - 1; j++) for (let i = 1; i < nx - 1; i++) {
      const v0 = values[at(i, j, l)], v1 = values[at(i, j + 1, l)];
      if ((v0 < 0) === (v1 < 0)) continue;
      quad(cellVertex[cellAt(i - 1, j, l - 1)], cellVertex[cellAt(i - 1, j, l)], cellVertex[cellAt(i, j, l)], cellVertex[cellAt(i, j, l - 1)], v0 < 0);
    }
    for (let l = 0; l < nz - 1; l++) for (let j = 1; j < ny - 1; j++) for (let i = 1; i < nx - 1; i++) {
      const v0 = values[at(i, j, l)], v1 = values[at(i, j, l + 1)];
      if ((v0 < 0) === (v1 < 0)) continue;
      quad(cellVertex[cellAt(i - 1, j - 1, l)], cellVertex[cellAt(i, j - 1, l)], cellVertex[cellAt(i, j, l)], cellVertex[cellAt(i - 1, j, l)], v0 < 0);
    }
    orientAlongNormals(b);
    return b.geometry();
  }

  /** Make every triangle wind counter-clockwise around its vertices' mean normal. */
  function orientAlongNormals(b) {
    const idx = b.idx, n = b.n;
    for (let t = 0; t < idx.length; t += 3) {
      const a = idx[t], c = idx[t + 1], d = idx[t + 2];
      const nx = n[a * 3] + n[c * 3] + n[d * 3], ny = n[a * 3 + 1] + n[c * 3 + 1] + n[d * 3 + 1], nz = n[a * 3 + 2] + n[c * 3 + 2] + n[d * 3 + 2];
      if (!facesAlong(b, a, c, d, nx, ny, nz)) { idx[t + 1] = d; idx[t + 2] = c; }
    }
  }

  /** A lumpy rock: a fine icosphere pushed in and out by a seeded mix of waves. */
  function lumpy(recipe) {
    const detail = int(recipe.detail, 10, 1, 20);
    const r = num(recipe.r, 1, 1e-4, 1000);
    const lumps = num(recipe.lumps, 0.12, 0, 0.3);
    const seed = num(recipe.seed, 1, -1e6, 1e6);
    const size = vec3(recipe.size, null);
    const squash = num(recipe.squash, 1, 0.1, 10);
    let g = new T.IcosahedronGeometry(1, detail);
    g.deleteAttribute('normal'); g.deleteAttribute('uv');
    g = T.mergeVertices(g);
    const pos = g.getAttribute('position');
    const waves = [];
    let s = seed * 9301 + 49297;
    const rand = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
    for (let w = 0; w < 4; w++) waves.push([1.3 + rand() * 2.2, rand() * TAU, 1.1 + rand() * 2.4, rand() * TAU, 1.2 + rand() * 2, rand() * TAU]);
    for (let i = 0; i < pos.count; i++) {
      const x = pos.getX(i), y = pos.getY(i), z = pos.getZ(i);
      let bump = 0;
      for (const w of waves) bump += Math.sin(x * w[0] + w[1]) * Math.sin(y * w[2] + w[3]) * Math.sin(z * w[4] + w[5]);
      const k = 1 + lumps * bump / 2;
      const sx = size ? size[0] / 2 : r, sy = size ? size[1] / 2 : r * squash, sz = size ? size[2] / 2 : r;
      pos.setXYZ(i, x * k * sx, y * k * sy, z * k * sz);
    }
    g.computeVertexNormals();
    return g;
  }

  // ---- shell (thick) ---------------------------------------------------------------------------------------

  /**
   * Give a surface thickness: an inner copy pushed inward along welded, area-weighted normals (reversed so it
   * faces in), plus a rim strip along every open edge. A closed mesh becomes hollow, which shows when cut.
   */
  function solidify(g, thick) {
    g = normalise(g);
    const pos = g.getAttribute('position').array, nrm = g.getAttribute('normal').array, uv = g.getAttribute('uv').array;
    const idx = g.index.array;
    const n = pos.length / 3;
    const weld = new Int32Array(n);
    const keys = new Map();
    for (let i = 0; i < n; i++) {
      const key = Math.round(pos[i * 3] * 1e5) + ',' + Math.round(pos[i * 3 + 1] * 1e5) + ',' + Math.round(pos[i * 3 + 2] * 1e5);
      let w = keys.get(key);
      if (w === undefined) keys.set(key, (w = keys.size));
      weld[i] = w;
    }
    const wn = new Float64Array(keys.size * 3);
    const faceNormals = new Float64Array(idx.length);
    for (let t = 0; t < idx.length; t += 3) {
      const a = idx[t], b = idx[t + 1], c = idx[t + 2];
      const ax = pos[b * 3] - pos[a * 3], ay = pos[b * 3 + 1] - pos[a * 3 + 1], az = pos[b * 3 + 2] - pos[a * 3 + 2];
      const bx = pos[c * 3] - pos[a * 3], by = pos[c * 3 + 1] - pos[a * 3 + 1], bz = pos[c * 3 + 2] - pos[a * 3 + 2];
      const fx = ay * bz - az * by, fy = az * bx - ax * bz, fz = ax * by - ay * bx;
      faceNormals[t] = fx; faceNormals[t + 1] = fy; faceNormals[t + 2] = fz;
      for (const v of [a, b, c]) { wn[weld[v] * 3] += fx; wn[weld[v] * 3 + 1] += fy; wn[weld[v] * 3 + 2] += fz; }
    }
    for (let w = 0; w < keys.size; w++) {
      const l = Math.hypot(wn[w * 3], wn[w * 3 + 1], wn[w * 3 + 2]) || 1;
      wn[w * 3] /= l; wn[w * 3 + 1] /= l; wn[w * 3 + 2] /= l;
    }
    const b = new Builder();
    for (let i = 0; i < n; i++) b.vertex(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2], nrm[i * 3], nrm[i * 3 + 1], nrm[i * 3 + 2], uv[i * 2], uv[i * 2 + 1]);
    for (let i = 0; i < n; i++) {
      const w = weld[i];
      b.vertex(pos[i * 3] - wn[w * 3] * thick, pos[i * 3 + 1] - wn[w * 3 + 1] * thick, pos[i * 3 + 2] - wn[w * 3 + 2] * thick,
        -nrm[i * 3], -nrm[i * 3 + 1], -nrm[i * 3 + 2], uv[i * 2], uv[i * 2 + 1]);
    }
    for (let t = 0; t < idx.length; t += 3) {
      b.tri(idx[t], idx[t + 1], idx[t + 2]);
      b.tri(n + idx[t], n + idx[t + 2], n + idx[t + 1]);
    }
    // Open edges are used by exactly one triangle (in welded terms).
    const edgeUse = new Map();
    const edgeKey = (a, c) => (weld[a] < weld[c] ? weld[a] + ':' + weld[c] : weld[c] + ':' + weld[a]);
    for (let t = 0; t < idx.length; t += 3) {
      for (let e = 0; e < 3; e++) {
        const k = edgeKey(idx[t + e], idx[t + (e + 1) % 3]);
        edgeUse.set(k, (edgeUse.get(k) || 0) + 1);
      }
    }
    for (let t = 0; t < idx.length; t += 3) {
      for (let e = 0; e < 3; e++) {
        const a = idx[t + e], c = idx[t + (e + 1) % 3];
        if (edgeUse.get(edgeKey(a, c)) !== 1) continue;
        const ex = pos[c * 3] - pos[a * 3], ey = pos[c * 3 + 1] - pos[a * 3 + 1], ez = pos[c * 3 + 2] - pos[a * 3 + 2];
        const fx = faceNormals[t], fy = faceNormals[t + 1], fz = faceNormals[t + 2];
        let rx = ey * fz - ez * fy, ry = ez * fx - ex * fz, rz = ex * fy - ey * fx;
        const rl = Math.hypot(rx, ry, rz) || 1;
        rx /= rl; ry /= rl; rz /= rl;
        const wa = weld[a], wc = weld[c];
        const A = b.vertex(pos[a * 3], pos[a * 3 + 1], pos[a * 3 + 2], rx, ry, rz, 0, 0);
        const B = b.vertex(pos[c * 3], pos[c * 3 + 1], pos[c * 3 + 2], rx, ry, rz, 1, 0);
        const C = b.vertex(pos[c * 3] - wn[wc * 3] * thick, pos[c * 3 + 1] - wn[wc * 3 + 1] * thick, pos[c * 3 + 2] - wn[wc * 3 + 2] * thick, rx, ry, rz, 1, 1);
        const D = b.vertex(pos[a * 3] - wn[wa * 3] * thick, pos[a * 3 + 1] - wn[wa * 3 + 1] * thick, pos[a * 3 + 2] - wn[wa * 3 + 2] * thick, rx, ry, rz, 0, 1);
        b.tri(A, C, B);
        b.tri(A, D, C);
      }
    }
    return b.geometry();
  }

  // ---- the part kinds --------------------------------------------------------------------------------------

  // Kinds built standing along z (a gear's or an extrusion's face looks at the viewer); every other kind stands along y.
  const BUILT_ALONG_Z = new Set(['gear', 'extrude']);

  const SHAPES = {
    /** A sampled surface: `grid` is rows of [x, y, z] (null for a missing sample); two triangles per cell. */
    surface(r) {
      const rows = (Array.isArray(r.grid) ? r.grid : []).slice(0, 161).filter(Array.isArray);
      const cols = rows.length ? Math.min(161, ...rows.map((row) => row.length)) : 0;
      if (rows.length < 2 || cols < 2) return new T.BoxGeometry(1, 1e-3, 1);
      const b = new Builder();
      const index = [];
      for (let j = 0; j < rows.length; j++) {
        index.push([]);
        for (let i = 0; i < cols; i++) {
          const p = vec3(rows[j][i], null);
          index[j].push(p ? b.vertex(p[0], p[1], p[2], 0, 0, 0, i / (cols - 1), j / (rows.length - 1)) : -1);
        }
      }
      for (let j = 0; j + 1 < rows.length; j++) {
        for (let i = 0; i + 1 < cols; i++) {
          const a = index[j][i], c = index[j][i + 1], d = index[j + 1][i + 1], e = index[j + 1][i];
          if (a >= 0 && c >= 0 && d >= 0) b.tri(a, c, d);
          if (a >= 0 && d >= 0 && e >= 0) b.tri(a, d, e);
        }
      }
      if (!b.idx.length) throw new Error('surface has no complete cells');
      const g = b.geometry();
      g.deleteAttribute('normal');
      g.computeVertexNormals();
      return g;
    },

    box(r) {
      const size = vec3(r.size, null) || [num(r.w, 1), num(r.h, 1), num(r.d, 1)];
      const [w, h, d] = size.map((v) => clamp(Math.abs(v), 1e-4, 1e4));
      const round = num(r.round, 0, 0, 0.45 * Math.min(w, h, d));
      if (round > 5e-4) return new T.RoundedBoxGeometry(w, h, d, 3, round);
      return new T.BoxGeometry(w, h, d);
    },

    cylinder(r) {
      const radius = num(r.r, 0.5, 1e-4, 1e4);
      const top = num(r.top, radius, 0, 1e4);
      const h = num(r.h, 1, 1e-4, 1e4);
      const seg = int(r.seg, 48, 3, 128);
      if (r.open === true) return revolve([[radius, -h / 2], [top, h / 2]], { seg, arc: sweep(r), crease: 40 });
      const outline = top > 1e-6
        ? [[0, -h / 2], [radius, -h / 2], [top, h / 2], [0, h / 2]]
        : [[0, -h / 2], [radius, -h / 2], [0, h / 2]];
      const round = num(r.round, 0, 0, 0.45 * Math.min(radius, top > 1e-6 ? top : radius, h));
      const radii = outline.map((p, i) => (i > 0 && i < outline.length - 1 ? round : 0));
      const profile = round > 5e-4 ? fillet(outline.map((p) => [p[0], p[1], 0]), radii, FILLET_STEPS, false) : outline;
      return revolve(profile, { seg, arc: sweep(r), crease: 40 });
    },

    cone(r) {
      return SHAPES.cylinder(Object.assign({}, r, { top: 0, round: num(r.round, 0, 0, 0.45 * Math.min(num(r.r, 0.5), num(r.h, 1))) }));
    },

    tube(r) {
      const outer = num(r.r, 0.5, 1e-4, 1e4);
      const inner = num(r.inner, 0.8 * outer, 0, 0.999 * outer);
      const h = num(r.h, 1, 1e-4, 1e4);
      if (inner < 1e-6) return SHAPES.cylinder(r);
      const ring = [[inner, -h / 2], [outer, -h / 2], [outer, h / 2], [inner, h / 2]];
      const round = num(r.round, 0, 0, 0.45 * Math.min(outer - inner, h));
      const profile = round > 5e-4 ? fillet(ring.map((p) => [p[0], p[1], 0]), [round, round, round, round], FILLET_STEPS, true) : ring;
      return revolve(profile, { seg: int(r.seg, 48, 3, 128), arc: sweep(r), closed: true, crease: 40 });
    },

    lathe(r) {
      let profile = points2(r.profile, 400).map((p) => [Math.max(0, p[0]), p[1]]);
      if (profile.length < 2) profile = [[0, -0.5], [0.5, -0.5], [0.5, 0.5], [0, 0.5]];
      const closed = r.closed === true && profile.length >= 3;
      const round = num(r.round, 0, 0, 10);
      if (round > 5e-4) {
        const radii = profile.map((p) => (p[0] > 1e-6 ? round : 0));
        profile = fillet(profile.map((p) => [p[0], p[1], 0]), radii, FILLET_STEPS, closed);
      }
      return revolve(profile, { seg: int(r.seg, 64, 8, 128), arc: sweep(r), closed, crease: num(r.crease, 40, 1, 180) });
    },

    sphere(r) {
      const radius = num(r.r, 0.5, 1e-4, 1e4);
      const seg = int(r.seg, 48, 8, 128);
      const rings = clamp(Math.round(seg / 2), 4, 64);
      const profile = [];
      const from = r.dome === true ? 0 : -Math.PI / 2;
      const steps = r.dome === true ? Math.max(2, Math.round(rings / 2)) : rings;
      if (r.dome === true) profile.push([0, 0]);
      for (let i = 0; i <= steps; i++) {
        const a = from + (i / steps) * (Math.PI / 2 - from);
        profile.push([radius * Math.cos(a), radius * Math.sin(a)]);
      }
      profile[profile.length - 1][0] = 0;
      return revolve(profile, { seg, arc: sweep(r), crease: 40 });
    },

    torus(r) {
      const R = num(r.r, 1, 1e-4, 1e4);
      const tube = num(r.tube, 0.2, 1e-4, R);
      const around = int(r.tubeSeg, 24, 6, 64);
      const ring = [];
      for (let i = 0; i < around; i++) {
        const a = (i / around) * TAU;
        ring.push([R + tube * Math.cos(a), tube * Math.sin(a)]);
      }
      return revolve(ring, { seg: int(r.seg, 72, 8, 160), arc: sweep(r), closed: true, crease: 60 });
    },

    capsule(r) {
      const radius = num(r.r, 0.3, 1e-4, 1e4);
      const h = num(r.h, 1, 0, 1e4);
      const steps = 8;
      const profile = [];
      for (let i = 0; i <= steps; i++) {
        const a = -Math.PI / 2 + (i / steps) * (Math.PI / 2);
        profile.push([radius * Math.cos(a), -h / 2 + radius * Math.sin(a)]);
      }
      for (let i = 0; i <= steps; i++) {
        const a = (i / steps) * (Math.PI / 2);
        profile.push([radius * Math.cos(a), h / 2 + radius * Math.sin(a)]);
      }
      profile[0][0] = 0;
      profile[profile.length - 1][0] = 0;
      return revolve(profile, { seg: int(r.seg, 32, 6, 128), arc: sweep(r), crease: 40 });
    },

    pipe(r) {
      const pts = points3(r.points, 200, [[0, -0.5, 0], [0, 0.5, 0]]);
      const closed = r.closed === true && pts.length >= 3;
      const radius = num(r.r, 0.08, 1e-4, 1e3);
      const radial = int(r.seg, 16, 4, 32);
      const tubular = clamp(24 * pts.length, 24, 2400);
      const vectors = pts.map((p) => new T.Vector3(p[0], p[1], p[2]));
      let curve;
      if (r.smooth === false) {
        let shortest = Infinity;
        for (let i = 1; i < pts.length; i++) shortest = Math.min(shortest, vectors[i].distanceTo(vectors[i - 1]));
        curve = new ElbowCurve(pts, Math.min(radius * 2.5, shortest * 0.45), closed);
      } else {
        curve = pts.length === 2 && !closed ? new T.LineCurve3(vectors[0], vectors[1]) : new T.CatmullRomCurve3(vectors, closed, 'centripetal');
      }
      return tubeAlong(curve, tubular, radius, radial, closed);
    },

    spring(r) {
      const radius = num(r.r, 0.4, 1e-4, 1e3);
      const h = num(r.h, 1.5, 0, 1e3);
      const turns = num(r.turns, 8, 0.25, 60);
      const wire = num(r.wire, 0.05, 1e-4, radius);
      return tubeAlong(new Helix(radius, h, turns), clamp(Math.round(40 * turns), 16, 2400), wire, 10, false);
    },

    gear(r) {
      const teeth = int(r.teeth, 16, 6, 200);
      const pitch = num(r.r, 1, 1e-3, 1e3);
      const depth = num(r.depth, 0.15 * pitch, 0.02 * pitch, 0.5 * pitch);
      const width = num(r.width, 0.3, 1e-3, 1e3);
      const tip = pitch + depth / 2, root = pitch - depth / 2;
      const step = TAU / teeth;
      const shape = new T.Shape();
      for (let k = 0; k < teeth; k++) {
        const c = k * step;
        const pts = [[root, c - 0.27 * step], [tip, c - 0.15 * step], [tip, c + 0.15 * step], [root, c + 0.27 * step], [root, c + 0.5 * step]];
        pts.forEach(([rad, a], i) => {
          const x = rad * Math.cos(a), y = rad * Math.sin(a);
          if (k === 0 && i === 0) shape.moveTo(x, y); else shape.lineTo(x, y);
        });
      }
      shape.closePath();
      const hole = num(r.hole, 0, 0, root * 0.95);
      if (hole > 1e-4) {
        const path = new T.Path();
        path.absarc(0, 0, hole, 0, TAU, true);
        shape.holes.push(path);
      }
      const bevel = isNum(r.round) ? clamp(r.round, 0, Math.min(0.45 * width, 0.45 * depth)) : Math.min(0.02, 0.2 * width);
      return extrudeCentered([shape], width, bevel, 2, 4, false);
    },

    extrude(r) {
      const depth = num(r.depth, 0.3, 1e-4, 1e3);
      let shapes;
      let center = false;
      if (typeof r.path === 'string' && r.path.trim()) {
        shapes = parseSvgPath(r.path, num(r.unit, 0.01, 1e-6, 1e3)).toShapes(true);
        center = true;
      } else {
        let outline = points2(r.shape, 2000);
        if (outline.length < 3) outline = [[-0.5, -0.4], [0.5, -0.4], [0, 0.5]];
        const shape = new T.Shape(outline.map((p) => new T.Vector2(p[0], p[1])));
        for (const holeList of Array.isArray(r.holes) ? r.holes.slice(0, 64) : []) {
          const hole = points2(holeList, 2000);
          if (hole.length >= 3) shape.holes.push(new T.Path(hole.map((p) => new T.Vector2(p[0], p[1]))));
        }
        shapes = [shape];
      }
      if (!shapes.length) throw new Error('extrude path has no closed shapes');
      let bevel, bevelSegments;
      if (r.round === false || r.round === 0) { bevel = 0; bevelSegments = 0; }
      else if (isNum(r.round)) { bevel = clamp(r.round, 0, 0.45 * depth); bevelSegments = 3; }
      else { bevel = Math.min(0.015, 0.2 * depth); bevelSegments = 2; }
      return extrudeCentered(shapes, depth, bevel, bevelSegments, 12, center);
    },

    blob(r) {
      if (Array.isArray(r.balls) || Array.isArray(r.sticks)) return softShape(r);
      return lumpy(r);
    },

    poly(r) {
      const radius = num(r.r, 0.5, 1e-4, 1e4);
      const detail = int(r.detail, 0, 0, 3);
      switch (int(r.faces, 20, 4, 20)) {
        case 4: return new T.TetrahedronGeometry(radius, detail);
        case 6: { const s = (2 * radius) / Math.sqrt(3); return new T.BoxGeometry(s, s, s); }
        case 8: return new T.OctahedronGeometry(radius, detail);
        case 12: return new T.DodecahedronGeometry(radius, detail);
        default: return new T.IcosahedronGeometry(radius, detail);
      }
    },

    arrow(r) {
      const pts = points3(r.points, 200, [[0, 0, 0], [1, 0, 0]]);
      const radius = num(r.r, 0.04, 1e-4, 1e3);
      const vectors = pts.map((p) => new T.Vector3(p[0], p[1], p[2]));
      const curve = pts.length === 2 ? new T.LineCurve3(vectors[0], vectors[1]) : new T.CatmullRomCurve3(vectors, false, 'centripetal');
      const length = curve.getLength();
      if (length < 1e-6) throw new Error('arrow has zero length');
      const head = Math.min(num(r.head, 5 * radius, 0, 1e3), 0.6 * length);
      const headR = num(r.headR, 2.5 * radius, radius, 1e3);
      const shaftFraction = (length - head) / length;
      const pieces = [];
      if (shaftFraction > 1e-3) {
        const segments = clamp(Math.round((length / radius) * 2), 16, 400);
        pieces.push(new T.TubeGeometry(new HeadlessCurve(curve, shaftFraction), segments, radius, 12, false));
      }
      const tail = new T.SphereGeometry(radius, 12, 8);
      const start = curve.getPointAt(0);
      tail.translate(start.x, start.y, start.z);
      pieces.push(tail);
      if (head > 1e-6) {
        const cone = new T.ConeGeometry(headR, head, 24);
        const dir = curve.getTangentAt(1).normalize();
        cone.applyQuaternion(new T.Quaternion().setFromUnitVectors(new T.Vector3(0, 1, 0), dir));
        const base = curve.getPointAt(shaftFraction);
        cone.translate(base.x + dir.x * head / 2, base.y + dir.y * head / 2, base.z + dir.z * head / 2);
        pieces.push(cone);
      }
      return merge(pieces);
    },
  };
  SHAPES.cyl = SHAPES.cylinder;

  // ---- extrusion -------------------------------------------------------------------------------------------

  /**
   * Extrude flat shapes (three Shapes, with holes) along z, centred on z = 0, with an optional rounded edge.
   *
   * Written for speed without the JIT: one earcut per shape for the faces, then the side wall as rings of the
   * outline. With a bevel the outline is pulled inward by up to `bevel` (each corner moves along its miter, capped
   * so spikes stay sane) over a quarter circle, so the edge is rounded and the outer outline stays where it was
   * drawn. Corners sharper than 35° keep hard edges.
   */
  function extrudeShapes(shapes, depth, bevelWanted, bevelSegments, curveSegments) {
    const b = new Builder();
    const half = depth / 2;
    // Triangulating the faces slows down sharply with the number of outline points (far more when an outline crosses
    // itself), so outlines made of many curves get fewer points per curve, and one that is still too long is refused.
    let straight = 0, bendy = 0;
    for (const path of shapes.flatMap((shape) => [shape, ...shape.holes])) {
      for (const curve of path.curves) {
        if (curve.isLineCurve) straight += 1;
        else bendy += curve.isEllipseCurve ? 2 : curve.isSplineCurve ? curve.points.length : 1;
      }
    }
    const perCurve = clamp(Math.floor((MAX_OUTLINE_POINTS - straight) / Math.max(1, bendy)), 1, curveSegments);
    const extractedShapes = shapes.map((shape) => shape.extractPoints(perCurve));
    const outlinePoints = extractedShapes.reduce((n, e) => n + e.shape.length + e.holes.reduce((m, h) => m + h.length, 0), 0);
    if (outlinePoints > MAX_OUTLINE_POINTS) {
      throw new Error(`an extruded outline may have at most ${MAX_OUTLINE_POINTS} points; this one has ${outlinePoints}`);
    }
    for (const extracted of extractedShapes) {
      let outer = cleanContour(extracted.shape);
      if (outer.length < 3) continue;
      if (T.ShapeUtils.isClockWise(outer.map((p) => new T.Vector2(p[0], p[1])))) outer.reverse();
      const holes = [];
      for (const hole of extracted.holes) {
        const h = cleanContour(hole);
        if (h.length < 3) continue;
        if (!T.ShapeUtils.isClockWise(h.map((p) => new T.Vector2(p[0], p[1])))) h.reverse();
        holes.push(h);
      }
      const contours = [outer].concat(holes);
      // The bevel may not eat more than a quarter of the shortest edge or 45% of the thickness.
      let shortest = Infinity;
      for (const c of contours) for (let i = 0; i < c.length; i++) {
        const a = c[i], d = c[(i + 1) % c.length];
        shortest = Math.min(shortest, Math.hypot(d[0] - a[0], d[1] - a[1]));
      }
      const bevel = Math.min(bevelWanted, 0.45 * depth, 0.25 * shortest);
      const steps = bevel > 1e-5 ? Math.max(1, bevelSegments) : 0;
      // Rings across the thickness, back to front: [inset fraction, z, normal weight in plane, normal z].
      const rings = [];
      if (steps === 0) {
        rings.push([0, -half, 1, 0], [0, half, 1, 0]);
      } else {
        for (let k = steps; k >= 0; k--) {
          const a = (k / steps) * (Math.PI / 2);
          rings.push([1 - Math.cos(a), -(half - bevel) - bevel * Math.sin(a), Math.cos(a), -Math.sin(a)]);
        }
        for (let k = 0; k <= steps; k++) {
          const a = (k / steps) * (Math.PI / 2);
          rings.push([1 - Math.cos(a), (half - bevel) + bevel * Math.sin(a), Math.cos(a), Math.sin(a)]);
        }
      }
      const insetContours = [];
      for (const contour of contours) {
        const info = contourFrames(contour);
        insetContours.push(contour.map((p, i) => [p[0] + info.miter[i][0] * bevel, p[1] + info.miter[i][1] * bevel]));
        sideWall(b, contour, info, rings, bevel);
      }
      // Faces: one triangulation of the outline, used for the front (inset) and back.
      const flat = insetContours[0].map((p) => new T.Vector2(p[0], p[1]));
      const holeVectors = insetContours.slice(1).map((c) => c.map((p) => new T.Vector2(p[0], p[1])));
      const faces = T.ShapeUtils.triangulateShape(flat, holeVectors);
      const all = [].concat(...insetContours);
      for (const side of [1, -1]) {
        const first = b.count;
        for (const p of all) b.vertex(p[0], p[1], side * half, 0, 0, side, p[0], p[1]);
        for (const f of faces) {
          const i0 = first + f[0], i1 = first + f[1], i2 = first + f[2];
          if (facesAlong(b, i0, i1, i2, 0, 0, side)) b.tri(i0, i1, i2); else b.tri(i0, i2, i1);
        }
      }
    }
    if (!b.count) throw new Error('extrude has no closed shapes');
    return b.geometry();
  }

  /** Points of a contour as [x, y] without repeats (including a closing point equal to the first). */
  function cleanContour(points) {
    const out = [];
    for (const p of points) {
      const last = out[out.length - 1];
      if (!last || Math.hypot(p.x - last[0], p.y - last[1]) > 1e-7) out.push([p.x, p.y]);
    }
    while (out.length > 1 && Math.hypot(out[0][0] - out[out.length - 1][0], out[0][1] - out[out.length - 1][1]) <= 1e-7) out.pop();
    return out;
  }

  /**
   * Per edge: outward normal. Per corner: the inward miter (moves the corner so both edges shift by one unit,
   * capped at 2.5 units), whether the corner is smooth, and the averaged outward normal. Contours run with the solid
   * on their left (outer counter-clockwise, holes clockwise), so the outward normal is the right-hand one.
   */
  function contourFrames(c) {
    const n = c.length;
    const edgeN = [];
    for (let i = 0; i < n; i++) {
      const a = c[i], d = c[(i + 1) % n];
      const dx = d[0] - a[0], dy = d[1] - a[1], l = Math.hypot(dx, dy) || 1;
      edgeN.push([dy / l, -dx / l]);
    }
    const miter = [], smooth = [], avg = [];
    const cosLimit = Math.cos(35 * DEG);
    for (let i = 0; i < n; i++) {
      const n1 = edgeN[(i - 1 + n) % n], n2 = edgeN[i];
      const dot = n1[0] * n2[0] + n1[1] * n2[1];
      let mx = -(n1[0] + n2[0]), my = -(n1[1] + n2[1]);
      const scale = 1 / Math.max(1 + dot, 0.16);
      mx *= scale; my *= scale;
      const ml = Math.hypot(mx, my);
      if (ml > 2.5) { mx *= 2.5 / ml; my *= 2.5 / ml; }
      miter.push([mx, my]);
      smooth.push(dot >= cosLimit);
      const sx = n1[0] + n2[0], sy = n1[1] + n2[1], sl = Math.hypot(sx, sy) || 1;
      avg.push([sx / sl, sy / sl]);
    }
    return { edgeN, miter, smooth, avg };
  }

  /** The side wall of one contour: a column of ring vertices at each corner (two at a hard corner). */
  function sideWall(b, c, info, rings, bevel) {
    const n = c.length;
    let perimeter = 0;
    const along = [0];
    for (let i = 0; i < n; i++) {
      const a = c[i], d = c[(i + 1) % n];
      perimeter += Math.hypot(d[0] - a[0], d[1] - a[1]);
      along.push(perimeter);
    }
    const column = (i, normal, u) => {
      const first = b.count;
      const p = c[i % n], m = info.miter[i % n];
      rings.forEach((ring, k) => {
        const inset = ring[0] * bevel;
        let nx = normal[0] * ring[2], ny = normal[1] * ring[2], nz = ring[3];
        const nl = Math.hypot(nx, ny, nz) || 1;
        b.vertex(p[0] + m[0] * inset, p[1] + m[1] * inset, ring[1], nx / nl, ny / nl, nz / nl, u, k / (rings.length - 1));
      });
      return first;
    };
    // Start and end column of each edge.
    const starts = [], ends = [];
    for (let i = 0; i < n; i++) {
      const u = along[i] / (perimeter || 1);
      if (info.smooth[i]) {
        const shared = column(i, info.avg[i], u);
        starts[i] = shared;
        ends[(i - 1 + n) % n] = shared;
      } else {
        ends[(i - 1 + n) % n] = column(i, info.edgeN[(i - 1 + n) % n], u);
        starts[i] = column(i, info.edgeN[i], u);
      }
    }
    for (let i = 0; i < n; i++) {
      const s = starts[i], e = ends[i];
      const en = info.edgeN[i];
      for (let k = 0; k < rings.length - 1; k++) {
        const a = s + k, a1 = s + k + 1, d = e + k, d1 = e + k + 1;
        const nz = rings[k][3] + rings[k + 1][3];
        if (facesAlong(b, a, d, d1, en[0], en[1], nz * 0.5)) { b.tri(a, d, d1); b.tri(a, d1, a1); }
        else { b.tri(a, d1, d); b.tri(a, a1, d1); }
      }
    }
  }

  /** Extrude, then optionally centre the outline on x = y = 0 (for SVG paths, which live wherever they were drawn). */
  function extrudeCentered(shapes, depth, bevel, bevelSegments, curveSegments, centerXY) {
    const g = extrudeShapes(shapes, depth, bevel, bevelSegments, curveSegments);
    if (centerXY) {
      g.computeBoundingBox();
      const box = g.boundingBox;
      g.translate(-(box.min.x + box.max.x) / 2, -(box.min.y + box.max.y) / 2, 0);
    }
    return g;
  }

  // ---- finishing and packing -------------------------------------------------------------------------------

  function finish(kind, recipe, geometry) {
    let g = normalise(geometry);
    const thick = num(recipe.thick, 0, 0, 10);
    if (thick > 1e-5) g = solidify(g, thick);

    const target = axisVector(recipe.axis);
    if (target) {
      const natural = BUILT_ALONG_Z.has(kind) ? new T.Vector3(0, 0, 1) : new T.Vector3(0, 1, 0);
      if (natural.distanceToSquared(target) > 1e-10) g.applyQuaternion(new T.Quaternion().setFromUnitVectors(natural, target));
    }

    const stretch = vec3(recipe.stretch, [1, 1, 1]).map((v) => (Math.abs(v) < 1e-4 ? (v < 0 ? -1e-4 : 1e-4) : v));
    const mirror = vec3(recipe.mirror, [1, 1, 1]).map((v) => (v < 0 ? -1 : 1));
    const s = [stretch[0] * mirror[0], stretch[1] * mirror[1], stretch[2] * mirror[2]];
    const pos = g.getAttribute('position'), nrm = g.getAttribute('normal');
    if (s[0] !== 1 || s[1] !== 1 || s[2] !== 1) {
      for (let i = 0; i < pos.count; i++) {
        pos.setXYZ(i, pos.getX(i) * s[0], pos.getY(i) * s[1], pos.getZ(i) * s[2]);
        // Normals transform by the inverse transpose: divide by the scale, then renormalise.
        const nx = nrm.getX(i) / s[0], ny = nrm.getY(i) / s[1], nz = nrm.getZ(i) / s[2];
        const l = Math.hypot(nx, ny, nz) || 1;
        nrm.setXYZ(i, nx / l, ny / l, nz / l);
      }
      if (s[0] * s[1] * s[2] < 0) {
        // A reflection turns every triangle inside out; swap two corners so faces point outward again.
        const idx = g.index.array;
        for (let t = 0; t < idx.length; t += 3) { const tmp = idx[t + 1]; idx[t + 1] = idx[t + 2]; idx[t + 2] = tmp; }
      }
    }
    return g;
  }

  function pack(g) {
    const positions = Float32Array.from(g.getAttribute('position').array);
    const count = positions.length / 3;
    if (count > MAX_VERTICES) throw new Error(`a part may have at most ${MAX_VERTICES} vertices; this one has ${count}`);
    if (count === 0) throw new Error('part has no geometry');
    const normals = Float32Array.from(g.getAttribute('normal').array);
    const uvs = Float32Array.from(g.getAttribute('uv').array);
    const indices = Uint32Array.from(g.index.array);
    const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
    const extreme = [0, 0, 0, 0, 0, 0];
    for (let i = 0; i < count; i++) {
      for (let a = 0; a < 3; a++) {
        const v = positions[i * 3 + a];
        if (!Number.isFinite(v)) throw new Error('part geometry has invalid numbers');
        if (v < lo[a]) { lo[a] = v; extreme[a * 2] = i; }
        if (v > hi[a]) { hi[a] = v; extreme[a * 2 + 1] = i; }
      }
    }
    for (let i = 0; i < normals.length; i++) if (!Number.isFinite(normals[i])) normals[i] = 0;
    // Framing points: the six extremes first, then an even spread over the rest.
    const chosen = extreme.slice();
    const stride = Math.max(1, Math.ceil(count / (MAX_SAMPLES - chosen.length)));
    for (let i = 0; i < count && chosen.length < MAX_SAMPLES; i += stride) chosen.push(i);
    const samples = new Float32Array(chosen.length * 3);
    chosen.forEach((v, k) => { samples[k * 3] = positions[v * 3]; samples[k * 3 + 1] = positions[v * 3 + 1]; samples[k * 3 + 2] = positions[v * 3 + 2]; });
    return { positions, normals, uvs, indices, samples, bounds: [lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]] };
  }

  globalThis.ocKernelKinds = Object.keys(SHAPES).filter((k) => k !== 'cyl');
  globalThis.ocKernelBuild = function (kind, recipeJSON) {
    const shape = SHAPES[kind];
    if (!shape) throw new Error('unknown 3D part "' + kind + '"');
    let recipe = {};
    if (typeof recipeJSON === 'string' && recipeJSON.trim()) recipe = JSON.parse(recipeJSON);
    else if (recipeJSON && typeof recipeJSON === 'object') recipe = recipeJSON;
    if (!recipe || typeof recipe !== 'object' || Array.isArray(recipe)) recipe = {};
    return pack(finish(kind, recipe, shape(recipe)));
  };
})();
