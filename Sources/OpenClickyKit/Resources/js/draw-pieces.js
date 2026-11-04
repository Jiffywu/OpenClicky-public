/*
 * OpenClicky drawing pieces: the screen-marking and explanation pieces of the 2D drawing language (docs/dsl.md).
 *
 * Loaded by the host right after draw-engine.js. It adds its functions to the program's scope through
 * __engine.registerModule, the same way the 3D milestone's figure-api.js does.
 */
__engine.registerModule(function (api, ctx) {
  'use strict';

  var U = ctx.util;
  var M = Math;
  var pt = U.pt, num = U.num, isNum = U.isNum, isObj = U.isObj;
  var GEL_TEXT = '#16181D';

  function opts(o) { return isObj(o) ? o : {}; }
  // True when every value is a finite number; otherwise warns once for the piece and the call draws nothing.
  function numbers(name, values) {
    for (var i = 0; i < values.length; i++) if (!isNum(values[i])) { ctx.warn(name + '() needs numbers for its position and size'); return false; }
    return true;
  }
  function rect(x, y, w, h) { return { x: x, y: y, w: w, h: h }; }
  function canvas() { return ctx.canvas; }
  function onCanvas(r, margin) {
    var c = canvas();
    margin = margin || 2;
    return r.x >= margin && r.y >= margin && r.x + r.w <= c.width - margin && r.y + r.h <= c.height - margin;
  }
  function clampToCanvas(r) { return U.keepOnCanvas(r); }

  // How much of a rectangle is already taken by pills, words, labels, buttons, strokes and shapes drawn so far, and by
  // text and controls on the screen (0 = free).
  function taken(r, ignore) {
    var marks = U.obstaclesNear(U.inflate(r, 4), ignore ? [ignore] : null), score = 0, area = M.max(1, r.w * r.h);
    // Words' boxes end at their last line's descenders: keep a hair of space from them.
    var near = U.inflate(r, pt(3));
    for (var i = 0; i < marks.length; i++) {
      var m = marks[i], kind = m.__layout, b = U.boxOf(m);
      if (kind === 'pill' || kind === 'words' || kind === 'label') {
        var inter = U.overlapArea(near, b);
        if (inter > 0) score += 0.5 + 3 * inter / area;
      } else if (kind === 'dot') {
        if (U.overlapArea(r, b) > 0) score += 0.4;
      } else if (kind === 'container' || kind === 'shape' || kind === 'stroke') {
        // Only where its pen actually runs (a long diagonal arrow's box is mostly empty), or a fill under it.
        var paths = U.strokePaths(m), crossed = false;
        for (var k = 0; k < paths.length && !crossed; k++) crossed = U.polylineHits(paths[k].pts, r, paths[k].closed);
        if (crossed) score += 0.6;
        else if (m.fill && m.fillAlpha >= 0.5 && U.overlapArea(r, b) > 0.3 * area) score += 0.3;
      }
    }
    // Words and controls on the real screen count too, a little less than our own marks (unless a card or a solid
    // fill already covers the screen there).
    var ground = U.groundUnder(r);
    var busy = ground && (ground.card || ground.fill) ? 0 : U.screenBusy(r.x, r.y, r.w, r.h);
    if (busy > 0) score += busy * 0.8;
    return score;
  }
  // Pick the calmest spot among candidate rectangles (in order of preference). `avoid` is what the pill names: a
  // candidate on it is taken only when nothing else is possible.
  function calmest(candidates, ignore, avoid) {
    var best = null, bestScore = Infinity;
    for (var i = 0; i < candidates.length; i++) {
      var c = candidates[i], r = c.r || c;
      if (!onCanvas(r, 4)) continue;
      var s = taken(r, ignore) + (c.rank != null ? c.rank : i * 0.004);
      if (avoid && !c.inside && U.overlapArea(r, avoid) > 0) s += 3;
      if (c.penalty) s += c.penalty;
      if (s < bestScore) { best = r; bestScore = s; }
      if (s < 0.01) break;
    }
    return best || clampToCanvas(candidates[0].r || candidates[0]);
  }

  // What is on the screen around a spot: the run of text and control edges it sits in (a button's label and border,
  // a field's words), measured on the screenshot, so a name never covers the thing it names. Without a screen, or on
  // one of our own cards, it is just the box given.
  function footprint(box) {
    var cx = box.x + box.w / 2, cy = box.y + box.h / 2;
    if (!U.layoutTimeLeft()) return box;
    if (U.screenBusy(cx - 1, cy - 1, 2, 2) < 0) return box;
    var ground = U.groundUnder(box);
    if (ground && (ground.card || ground.fill)) return box;
    var cell = pt(4), threshold = 0.2;
    function scan(dir, horizontal, band, reach, gapTolerance) {
      var edge = horizontal ? (dir > 0 ? box.x + box.w : box.x) : (dir > 0 ? box.y + box.h : box.y);
      var last = edge, calm = 0, pos = edge;
      for (var d = 0; d < reach; d += cell) {
        var start = dir > 0 ? pos : pos - cell;
        var b = horizontal ? U.screenBusy(start, cy - band, cell, 2 * band) : U.screenBusy(band[0], start, band[1], cell);
        if (b < 0) break;
        if (b > threshold) { last = dir > 0 ? pos + cell : pos - cell; calm = 0; }
        else { calm += cell; if (calm > gapTolerance) break; }
        pos += dir * cell;
      }
      return last;
    }
    var band = M.max(pt(6), box.h * 0.35);
    var left = scan(-1, true, band, pt(220), pt(14)), right = scan(1, true, band, pt(220), pt(14));
    var w = M.min(right - left, pt(80)), column = [cx - w / 2, M.max(cell, w)];
    var top = scan(-1, false, column, pt(30), pt(4)), bottom = scan(1, false, column, pt(30), pt(4));
    return U.union(box, { x: left, y: top, w: right - left, h: bottom - top });
  }
  // A pill of size s beside a footprint on one side, `gap` away from it.
  function beside(foot, s, side, gap, cx, cy) {
    switch (side) {
      case 'right': return rect(foot.x + foot.w + gap, cy - s.h / 2, s.w, s.h);
      case 'left': return rect(foot.x - gap - s.w, cy - s.h / 2, s.w, s.h);
      case 'below': return rect(cx - s.w / 2, foot.y + foot.h + gap, s.w, s.h);
      case 'above': return rect(cx - s.w / 2, foot.y - gap - s.h, s.w, s.h);
      case 'below-right': return rect(foot.x + foot.w + gap * 0.7, foot.y + foot.h + gap * 0.5, s.w, s.h);
      case 'below-left': return rect(foot.x - gap * 0.7 - s.w, foot.y + foot.h + gap * 0.5, s.w, s.h);
      case 'above-right': return rect(foot.x + foot.w + gap * 0.7, foot.y - gap * 0.5 - s.h, s.w, s.h);
      default: return rect(foot.x - gap * 0.7 - s.w, foot.y - gap * 0.5 - s.h, s.w, s.h);
    }
  }
  // Where a straight line from the centre of `inner` towards `toward` leaves `outer` (both rectangles).
  function exitPoint(outer, cx, cy, toward) {
    var dx = toward[0] - cx, dy = toward[1] - cy, t = Infinity;
    if (dx > 0) t = M.min(t, (outer.x + outer.w - cx) / dx); else if (dx < 0) t = M.min(t, (outer.x - cx) / dx);
    if (dy > 0) t = M.min(t, (outer.y + outer.h - cy) / dy); else if (dy < 0) t = M.min(t, (outer.y - cy) / dy);
    if (!isFinite(t)) t = 0;
    t = U.clamp(t, 0, 1);
    return [cx + dx * t, cy + dy * t];
  }
  // A thin line from what a pill names to the pill, when the pill had to sit apart from it.
  function leader(target, foot, pillBox, o) {
    var cx = target.x + target.w / 2, cy = target.y + target.h / 2;
    var near = [U.clamp(cx, pillBox.x, pillBox.x + pillBox.w), U.clamp(cy, pillBox.y, pillBox.y + pillBox.h)];
    // From the edge of the thing on the screen (the ring's edge when nothing is known about the screen), so the
    // leader never runs over the words it names.
    var from = exitPoint(foot, cx, cy, near);
    var len = M.hypot(near[0] - from[0], near[1] - from[1]);
    if (len < pt(6)) return null;
    var ux = (near[0] - from[0]) / len, uy = (near[1] - from[1]) / len;
    var a = [from[0] + ux * pt(2), from[1] + uy * pt(2)], b = [near[0] - ux * pt(2), near[1] - uy * pt(2)];
    var hd = U.drawLine([a, b], { tone: o.tone, size: pt(2), wobble: 0, glow: [0.35, 4], dodge: false }, 'line');
    var lm = hd && U.byId(hd.id);
    if (lm) { lm.role = 'leader'; lm.__dur = 0.18; lm.__adv = 0.14; }
    return hd;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Pills and badges: names and numbers on a small gel in Clicky's ink

  function pillSize(text, o) {
    var size = U.clamp(num(o.size, pt(13)), 6, 200);
    var h = M.max(size * 1.85, pt(22));
    var w = U.textWidth(text, size, 'bold') + h * 0.9;
    return { w: w, h: h, size: size };
  }
  function makePill(r, text, o, size) {
    var m = U.newMark('pill', o, text);
    m.tone = U.toneHex(o.tone || o.color);
    m.at = [r.x, r.y]; m.w = r.w; m.h = r.h;
    m.text = String(text); m.size = size; m.color = GEL_TEXT;
    m.__box = r; m.__layout = 'pill';
    return U.handle(ctx.push(m));
  }

  api.pill = function (x, y, text, o) {
    o = opts(o);
    if (!numbers('pill', [x, y])) return null;
    if (text == null || String(text) === '') { ctx.warn('pill() needs words'); return null; }
    var s = pillSize(String(text), o);
    var left = o.align === 'center' || o.align === 'middle' ? x - s.w / 2 : o.align === 'right' ? x - s.w : x;
    var top = o.valign === 'middle' ? y - s.h / 2 : o.valign === 'bottom' ? y - s.h : y;
    var r = clampToCanvas(rect(left, top, s.w, s.h));
    if (o.place !== false) {
      var step = s.h * 1.2;
      r = calmest([r, rect(r.x, r.y + step, r.w, r.h), rect(r.x, r.y - step, r.w, r.h), rect(r.x, r.y + 2 * step, r.w, r.h),
        rect(r.x, r.y - 2 * step, r.w, r.h), rect(r.x + r.w * 0.6, r.y, r.w, r.h), rect(r.x - r.w * 0.6, r.y, r.w, r.h)]);
    }
    return makePill(r, text, o, s.size);
  };
  api.label = api.pill;

  api.badge = function (x, y, n, o) {
    o = opts(o);
    if (!numbers('badge', [x, y])) return null;
    var r = num(o.r, pt(11));
    var m = U.newMark('badge', o, String(n));
    m.tone = U.toneHex(o.tone || o.color);
    m.at = [x, y]; m.r = r;
    m.text = String(n == null ? '' : n); m.size = num(o.size, r * 1.15); m.color = GEL_TEXT;
    m.__box = rect(x - r, y - r, 2 * r, 2 * r); m.__layout = 'pill';
    return U.handle(ctx.push(m));
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Pointing at the screen

  var SIDES = ['right', 'left', 'below', 'above', 'below-right', 'below-left', 'above-right', 'above-left'];
  // Name pills drawn so far, so a later ring or callout that lands on one can move it out of the way.
  var names = [];
  ctx.onBegin(function (canvas, keep) { if (!keep) names = []; });

  function nameSpot(target, foot, s, o, keepOff) {
    var gap = foot.w > target.w + 2 || foot.h > target.h + 2 ? pt(14) : pt(8);   // room for a visible leader
    var cx = target.x + target.w / 2, cy = target.y + target.h / 2;
    var sides = SIDES.slice();
    if (o.side && sides.indexOf(o.side) >= 0) { sides.splice(sides.indexOf(o.side), 1); sides.unshift(o.side); }
    var cands = [];
    for (var tier = 0; tier < 4; tier++) {
      for (var i = 0; i < sides.length; i++) {
        var c = { r: beside(foot, s, sides[i], gap + tier * pt(24), cx, cy), rank: i * 0.006 + tier * 0.035 + (i >= 4 ? 0.02 : 0) };
        if (keepOff && U.overlapArea(U.inflate(c.r, pt(3)), keepOff) > 0) c.penalty = 5;
        cands.push(c);
      }
    }
    cands.sort(function (a, b) { return a.rank - b.rank; });
    return calmest(cands, null, U.inflate(foot, -1));
  }
  // Name a target in a pill beside it, never on it: off the whole thing on the screen (footprint), on the calmest
  // nearby side, with a thin leader back to the target when the pill had to sit apart.
  function nameNear(target, text, o) {
    var s = pillSize(String(text), o);
    var foot = footprint(target);
    var spot = nameSpot(target, foot, s, o);
    var pill = makePill(spot, text, o, s.size);
    var line = o.leader !== false ? leader(target, foot, spot, o) : null;
    names.push({ pill: U.byId(pill.id), leader: line ? U.byId(line.id) : null, target: target, foot: foot, size: s, o: o });
    return pill;
  }
  // A ring or arrow is about to land on `area`: name pills already there step aside (their leaders follow).
  function makeRoom(area) {
    for (var i = 0; i < names.length; i++) {
      var n = names[i], p = n.pill;
      if (!p || p.__erased) continue;
      var b = U.boxOf(p);
      if (U.overlapArea(U.inflate(b, pt(2)), area) <= 0) continue;
      var spot = nameSpot(n.target, n.foot, n.size, n.o, area);
      if (U.overlapArea(spot, area) > 0) continue;
      U.nudge(p, spot.x - b.x, spot.y - b.y);
      if (n.leader) U.retract([n.leader]);
      var line = n.o.leader !== false ? leader(n.target, n.foot, spot, n.o) : null;
      n.leader = line ? U.byId(line.id) : null;
    }
  }

  // Ring the exact spot, put a dot in its centre and name it.
  api.point = function (x, y, name, o) {
    if (isObj(name)) { o = name; name = null; }
    o = opts(o);
    if (!numbers('point', [x, y])) return null;
    var r = num(o.r, pt(14));
    makeRoom(rect(x - r - pt(2), y - r - pt(2), 2 * r + pt(4), 2 * r + pt(4)));
    var ring = U.drawCircle(x, y, r, r, { tone: o.tone, wobble: 0.4, size: o.size, place: false });
    // Tell the app this ring points at something on the screen, so the buddy pointer can fly to the control there
    // (or to the element the turn's list names, `{element: "e12"}`) when the line is heard.
    var ringMark = ring && U.byId(ring.id);
    if (ringMark) {
      ringMark.pointing = true;
      if (name != null && String(name) !== '') ringMark.pointLabel = String(name).replace(/\s+/g, ' ').trim().slice(0, 60);
      if (typeof o.element === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,23}$/.test(o.element)) ringMark.element = o.element;
    }
    U.drawDot(x, y, { r: pt(3), tone: o.tone });
    if (name != null && String(name) !== '') nameNear(rect(x - r, y - r, 2 * r, 2 * r), name, o);
    return ring;
  };

  // Words in a pill, with an arrow that points at a spot on the screen.
  api.callout = function (x, y, text, o) {
    o = opts(o);
    if (!numbers('callout', [x, y])) return null;
    if (text == null || String(text) === '') { ctx.warn('callout() needs words'); return null; }
    var s = pillSize(String(text), o);
    var d = num(o.distance, pt(110));
    var dirs = {
      right: [1, 0], left: [-1, 0], below: [0, 1], above: [0, -1],
      'below-right': [0.75, 0.75], 'below-left': [-0.75, 0.75], 'above-right': [0.75, -0.75], 'above-left': [-0.75, -0.75]
    };
    var names = ['right', 'below-right', 'above-right', 'left', 'below-left', 'above-left', 'below', 'above'];
    if (o.side && dirs[o.side]) { names.splice(names.indexOf(o.side), 1); names.unshift(o.side); }
    // The pill keeps off the thing it points at (its footprint on the screen), at the usual distance or a bit
    // nearer or farther when that side is busy.
    var foot = footprint(rect(x - pt(11), y - pt(11), pt(22), pt(22)));
    var cands = [];
    [1, 0.65, 1.45].forEach(function (k, tier) {
      names.forEach(function (n, i) {
        var v = dirs[n];
        var cx = x + v[0] * (d * k + s.w / 2), cy = y + v[1] * (d * k * 0.8 + s.h / 2);
        cands.push({ r: rect(cx - s.w / 2, cy - s.h / 2, s.w, s.h), rank: i * 0.004 + tier * 0.03 });
      });
    });
    // An earlier name pill on the spot this points at moves aside.
    if (o.ring !== false) makeRoom(rect(x - pt(13), y - pt(13), pt(26), pt(26)));
    var r = calmest(cands, null, U.inflate(foot, -1));
    var pill = makePill(r, text, o, s.size);
    // From the pill's nearest edge to just short of the spot.
    var px = U.clamp(x, r.x, r.x + r.w), py = U.clamp(y, r.y, r.y + r.h);
    if (px > r.x && px < r.x + r.w && py > r.y && py < r.y + r.h) py = r.y + r.h;
    var dx = x - px, dy = y - py, len = M.hypot(dx, dy) || 1, stop = pt(o.ring === false ? 6 : 16);
    var startGap = pt(4);
    if (len > stop + startGap + pt(8)) {
      U.drawLine([[px + dx / len * startGap, py + dy / len * startGap], [x - dx / len * stop, y - dy / len * stop]],
        { tone: o.tone, bend: num(o.bend, 0.12), head: o.head }, 'arrow');
    }
    if (o.ring !== false) U.drawCircle(x, y, pt(11), pt(11), { tone: o.tone, wobble: 0.4, place: false });
    return pill;
  };

  // An area on the screen: a dashed rounded frame with a light tint, named in a pill.
  api.region = function (x, y, w, h, name, o) {
    if (isObj(name)) { o = name; name = null; }
    o = opts(o);
    if (!numbers('region', [x, y, w, h])) return null;
    var r = { x: M.min(x, x + w), y: M.min(y, y + h), w: M.abs(w), h: M.abs(h) };
    var m = U.newMark('region', o, name || '');
    U.strokeStyle(m, o, r, false);
    m.at = [r.x, r.y]; m.w = r.w; m.h = r.h;
    m.r = isNum(o.r) ? o.r : (r.w > 2.5 * r.h && r.h < pt(60) ? r.h / 2 : pt(8));
    m.dash = [pt(8), pt(5)];
    m.fillAlpha = U.clamp(num(o.fillAlpha, 0.08), 0, 1);
    m.__box = r; m.__layout = name ? 'container' : 'shape';
    if (name) m.__label = String(name).slice(0, 24);
    var hd = U.handle(ctx.push(m));
    if (name != null && String(name) !== '') {
      // Like a tab on the frame: above or below it, sliding along its edge to a calm spot; inside its corner only
      // when nothing on the screen is there to cover.
      var s = pillSize(String(name), o), gap = pt(6), cands = [];
      var slide = [0, 0.25, 0.5, 0.75].map(function (f) { return r.x + M.max(0, r.w - s.w) * f; });
      slide.forEach(function (sx, i) {
        cands.push({ r: rect(sx, r.y - s.h - gap, s.w, s.h), rank: i * 0.02 });
        cands.push({ r: rect(sx, r.y + r.h + gap, s.w, s.h), rank: 0.01 + i * 0.02 });
      });
      cands.push({ r: rect(r.x + r.w + gap, r.y + M.min(pt(4), r.h / 4), s.w, s.h), rank: 0.1 });
      cands.push({ r: rect(r.x - gap - s.w, r.y + M.min(pt(4), r.h / 4), s.w, s.h), rank: 0.12 });
      var inside = rect(r.x + pt(8), r.y + pt(8), s.w, s.h);
      if (inside.x + inside.w <= r.x + r.w && inside.y + inside.h <= r.y + r.h) cands.push({ r: inside, rank: 0.4, inside: true });
      makePill(calmest(cands, m, r), name, o, s.size);
    }
    return hd;
  };

  // Short marks for the screen.
  api.underline = function (x, y, w, o) {
    o = opts(o);
    if (!numbers('underline', [x, y, w])) return null;
    return U.drawLine([[x, y + pt(3)], [x + w, y + pt(3)]], { tone: o.tone, size: o.size, wobble: num(o.wobble, 0.3), glow: o.glow }, 'line');
  };
  api.check = function (x, y, o) {
    o = opts(o);
    if (!numbers('check', [x, y])) return null;
    var s = num(o.size, pt(22));
    return U.drawLine([[x - s * 0.45, y], [x - s * 0.1, y + s * 0.38], [x + s * 0.5, y - s * 0.45]], { tone: o.tone || 'green', wobble: 0.2, smooth: false }, 'line');
  };
  api.cross = function (x, y, o) {
    o = opts(o);
    if (!numbers('cross', [x, y])) return null;
    var s = num(o.size, pt(20)) / 2;
    var m = U.newMark('line', o);
    var r = rect(x - s, y - s, 2 * s, 2 * s);
    U.strokeStyle(m, { tone: o.tone || 'red' }, r, false);
    m.pts = [[x - s, y - s], [x + s, y + s]];
    m.segs = [[[x - s, y - s], [x + s, y + s]], [[x + s, y - s], [x - s, y + s]]];
    m.__box = r; m.__layout = 'stroke';
    return U.handle(ctx.push(m));
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Paper: a small window-like card for diagrams and notes, set over a quiet part of the screen

  api.paper = function (x, y, w, h, o) {
    o = opts(o);
    var header = pt(28), pad = num(o.pad, 18);
    // A card is never larger than the screen it sits on.
    var c = canvas(), cw = M.max(40, c.width - 8), ch = M.max(40, c.height - 8);
    if (!isNum(x) || !isNum(y) || !isNum(w) || !isNum(h)) { ctx.warn('paper() needs x, y, w, h numbers'); return null; }
    if (M.abs(w) > cw || M.abs(h) > ch) ctx.warn('paper() was larger than the screen and was made to fit');
    w = U.clamp(w, -cw, cw); h = U.clamp(h, -ch, ch);
    var r = U.placeContainer({ x: M.min(x, x + w), y: M.min(y, y + h), w: M.abs(w), h: M.abs(h) }, o.title || 'paper', o);
    r = clampToCanvas(r);
    var inkRGB = U.parseHex(ctx.ink) || [51, 128, 255];
    var sheet = U.toHex(U.mix([252, 249, 243], inkRGB, 0.035));
    var m = U.newMark('paper', o, o.title || '');
    m.at = [r.x, r.y]; m.w = r.w; m.h = r.h;
    m.title = o.title != null ? String(o.title) : '';
    m.board = o.board === 'grid' || o.board === 'dots' ? o.board : 'plain';
    m.header = header; m.pad = pad;
    m.paper = o.paper ? U.toneHex(o.paper) : sheet;
    m.tone = U.toneHex(o.tone || o.color);
    m.__ground = m.paper;
    m.__box = r; m.__layout = 'container'; m.__label = m.title.slice(0, 24) || 'paper';
    var hd = ctx.push(m);
    var inner = rect(r.x + pad, r.y + header + pad * 0.6, M.max(0, r.w - 2 * pad), M.max(0, r.h - header - pad * 1.6));
    var out = U.handle(hd, inner);
    out.card = hd.id;
    out.outer = { x: r.x, y: r.y, w: r.w, h: r.h };
    return out;
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Buttons that ask a follow-up question when clicked

  // button(x, y, "words", action) or button(box, "words", action), the second hung from the bottom edge of a photo,
  // card or row like a price tag. `action` is what a click does: {ask: "…"} (or a plain string) asks it as the next
  // question (the default asks the button's words), {open: url}, {copy: "…"}, {handoff: "task"} or {card: "…"}.
  api.button = function (x, y, text, o) {
    var anchor = null;
    if (isObj(x) && isNum(x.x) && isNum(x.y) && isNum(x.w) && isNum(x.h)) { anchor = x; o = text; text = y; x = anchor.x + anchor.w / 2; y = anchor.y + anchor.h; }
    var action = { kind: 'ask', value: null };
    if (typeof o === 'string') { action.value = o; o = {}; }
    o = opts(o);
    if (!numbers('button', [x, y])) return null;
    if (text == null || String(text) === '') { ctx.warn('button() needs words'); return null; }
    if (o.open != null) {
      var url = String(o.open).trim();
      if (!/^https?:\/\/[^\s"'<>]+$/i.test(url)) { ctx.warn('a button opens web pages only ({open: "https://…"}); this one asks instead'); }
      else action = { kind: 'open', value: url };
    } else if (o.copy != null) action = { kind: 'copy', value: String(o.copy).slice(0, 20000) };
    else if (o.handoff != null) {
      var task = isObj(o.handoff) ? o.handoff.task : o.handoff;
      if (task) action = { kind: 'handoff', value: { task: String(task).slice(0, 4000), label: String(text).slice(0, 80) } };
    } else if (o.card != null) action = { kind: 'card', value: String(o.card) };
    var size = U.clamp(num(o.size, pt(14)), 6, 200);
    var h = M.max(size * 2.1, pt(30)), w = U.textWidth(String(text), size, 'bold') + h * 1.1;
    var r;
    if (anchor) {
      // Centred on the bottom edge of what it belongs to; it stays there.
      r = clampToCanvas(rect(x - w / 2, y - h / 2, w, h));
    } else {
      var left = o.align === 'center' || o.align === 'middle' ? x - w / 2 : o.align === 'right' ? x - w : x;
      r = clampToCanvas(rect(left, y, w, h));
      // Where asked if that is clear of words and pills, else the nearest clear spot below, above or beside it.
      var cands = [{ r: r, rank: 0 }], half = h * 0.5;
      for (var k = 1; k <= 8; k++) {
        cands.push({ r: rect(r.x, r.y + k * half, w, h), rank: k * 0.01 });
        cands.push({ r: rect(r.x, r.y - k * half, w, h), rank: k * 0.012 });
      }
      cands.push({ r: rect(r.x + w * 0.7, r.y, w, h), rank: 0.05 }, { r: rect(r.x - w * 0.7, r.y, w, h), rank: 0.06 });
      cands.sort(function (a, b) { return a.rank - b.rank; });
      r = calmest(cands);
    }
    var m = U.newMark('button', o, String(text));
    m.at = [r.x, r.y]; m.w = r.w; m.h = r.h;
    m.text = String(text);
    if (action.kind === 'ask' || action.kind === 'card') m.ask = String(action.value != null ? action.value : o.ask != null ? o.ask : text);
    if (action.kind !== 'ask') { m.action = action.kind; if (action.kind !== 'card') m.value = action.value; }
    m.size = size; m.tone = U.toneHex(o.tone || o.color); m.color = GEL_TEXT;
    m.__box = r; m.__layout = 'pill';
    return U.handle(ctx.push(m));
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Graphs

  function niceStep(span, target) {
    var raw = span / M.max(1, target), mag = M.pow(10, M.floor(M.log(raw) / M.LN10)), f = raw / mag;
    return (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag;
  }
  function niceTicks(lo, hi, target) {
    var stepV = niceStep(hi - lo, target || 5), out = [];
    for (var v = M.ceil(lo / stepV) * stepV; v <= hi + stepV * 1e-6 && out.length < 100; v += stepV) out.push(M.abs(v) < stepV * 1e-9 ? 0 : v);
    return out;
  }
  function shortNumber(v) {
    var a = M.abs(v);
    if (a >= 1e9) return (v / 1e9).toFixed(a % 1e9 ? 1 : 0) + 'B';
    if (a >= 1e6) return (v / 1e6).toFixed(a % 1e6 ? 1 : 0) + 'M';
    if (a >= 1e4) return (v / 1e3).toFixed(a % 1e3 ? 1 : 0) + 'k';
    return String(M.round(v * 1000) / 1000);
  }
  function tickList(spec, lo, hi, auto) {
    if (spec === false) return [];
    if (spec === true || (spec == null && auto)) return niceTicks(lo, hi, 5).map(function (v) { return [v, shortNumber(v)]; });
    if (!Array.isArray(spec)) return [];
    if (spec.length > 100) { ctx.warn('a graph axis takes at most 100 ticks'); spec = spec.slice(0, 100); }
    return spec.map(function (t) { return Array.isArray(t) ? [t[0], String(t[1])] : [t, shortNumber(t)]; })
      .filter(function (t) { return isNum(t[0]) && t[0] >= M.min(lo, hi) && t[0] <= M.max(lo, hi); });
  }

  api.graph = function (x, y, w, h, o) {
    o = opts(o);
    if (!numbers('graph', [x, y, w, h])) return null;
    var xr = Array.isArray(o.x) ? o.x : [0, 10], yr = Array.isArray(o.y) ? o.y : [0, 10];
    if (xr[1] === xr[0]) xr = [xr[0], xr[0] + 1];
    if (yr[1] === yr[0]) yr = [yr[0], yr[0] + 1];
    var X = function (v) { return x + (v - xr[0]) / (xr[1] - xr[0]) * w; };
    var Y = function (v) { return y + h - (v - yr[0]) / (yr[1] - yr[0]) * h; };
    var ox = xr[0] <= 0 && xr[1] >= 0 ? X(0) : x;
    var oy = yr[0] <= 0 && yr[1] >= 0 ? Y(0) : y + h;
    var auto = o.ticks !== false;
    var xt = tickList(o.xTicks, xr[0], xr[1], auto), yt = tickList(o.yTicks, yr[0], yr[1], auto);
    var labelSize = num(o.labelSize, 14);
    var axisTone = o.tone;

    var frame = U.newMark('graph', o);
    frame.at = [x, y]; frame.w = w; frame.h = h; frame.origin = [ox, oy];
    frame.tone = U.toneHex('grey');
    if (o.grid) {
      frame.grid = [];
      xt.forEach(function (t) { if (M.abs(X(t[0]) - ox) > 1) frame.grid.push([X(t[0]), y, X(t[0]), y + h]); });
      yt.forEach(function (t) { if (M.abs(Y(t[0]) - oy) > 1) frame.grid.push([x, Y(t[0]), x + w, Y(t[0])]); });
    }
    frame.__box = rect(x, y, w, h); frame.__layout = 'graph';
    frame.piece = 'graph';
    var frameMark = ctx.push(frame);

    var over = pt(14);
    U.drawLine([[x, oy], [x + w + over, oy]], { tone: axisTone, wobble: 0, head: pt(10), size: o.size }, 'arrow');
    U.drawLine([[ox, y + h], [ox, y - over]], { tone: axisTone, wobble: 0, head: pt(10), size: o.size }, 'arrow');
    var tick = pt(5), segs = [];
    xt.forEach(function (t) { segs.push([[X(t[0]), oy - tick], [X(t[0]), oy + tick]]); });
    yt.forEach(function (t) { segs.push([[ox - tick, Y(t[0])], [ox + tick, Y(t[0])]]); });
    if (segs.length) {
      var tm = U.newMark('line', { tone: axisTone });
      var tb = rect(x - tick, y - tick, w + 2 * tick, h + 2 * tick);
      U.strokeStyle(tm, { tone: axisTone, size: pt(2), glow: false }, tb, false);
      tm.pts = segs[0]; tm.segs = segs; tm.piece = 'graph';
      tm.__box = tb; tm.__layout = 'stroke';
      tm.__dur = 0.35; tm.__adv = 0.3;
      ctx.push(tm);
    }
    var gap = pt(4);
    xt.forEach(function (t) {
      if (M.abs(X(t[0]) - ox) < 2 && M.abs(oy - (y + h)) > 2) return;
      U.drawText(X(t[0]), oy + tick + gap, t[1], { size: labelSize, style: 'ui', align: 'center', tone: o.labelTone || 'grey', place: false }, 'piece');
    });
    yt.forEach(function (t) {
      if (M.abs(Y(t[0]) - oy) < 2 && M.abs(ox - x) > 2) return;
      U.drawText(ox - tick - gap, Y(t[0]), t[1], { size: labelSize, style: 'ui', align: 'right', valign: 'middle', tone: o.labelTone || 'grey', place: false }, 'piece');
    });
    if (o.xLabel) U.drawText(x + w, oy + tick + gap + labelSize * 1.6, o.xLabel, { size: labelSize + 2, style: 'hand', align: 'right', place: false, tone: axisTone }, 'piece');
    if (o.yLabel) U.drawText(ox + pt(10), y - over - labelSize * 0.4, o.yLabel, { size: labelSize + 2, style: 'hand', align: 'left', valign: 'bottom', place: false, tone: axisTone }, 'piece');

    // A series' name at its end (or its start), on the card and off every stroke, the series' own included.
    function seriesLabel(runs, label, size, tone) {
      var block = U.textBlock(String(label), size, 'hand', {});
      var first = runs[0][0], lastRun = runs[runs.length - 1], last = lastRun[lastRun.length - 1], g6 = pt(6);
      var area = U.cardFor(rect(x, y, w, h));
      var inside = area ? U.cardInnerOf(area.id) : null;
      var spots = [
        rect(last[0] + g6, last[1] - block.h / 2, block.w, block.h),
        rect(last[0] - block.w - g6, last[1] - block.h - g6, block.w, block.h),
        rect(last[0] - block.w - g6, last[1] + g6, block.w, block.h),
        rect(last[0] - block.w / 2, last[1] - block.h - g6, block.w, block.h),
        rect(first[0] + g6, first[1] - block.h - g6, block.w, block.h),
        rect(first[0] + g6, first[1] + g6, block.w, block.h)
      ];
      var near = U.obstaclesNear(U.inflate(rect(x, y, w, h), block.w + block.h), null);
      var best = spots[0], bestScore = Infinity;
      for (var i = 0; i < spots.length; i++) {
        var s = U.clashScore(spots[i], near, { inside: inside }) + i * 0.05;
        if (s < bestScore) { best = spots[i]; bestScore = s; }
        if (s < 0.06) break;
      }
      if (bestScore > 0.5) best = U.cleanSpot(best, { inside: inside });
      return U.drawText(best.x, best.y, label, { size: size, style: 'hand', tone: tone, place: false }, 'piece');
    }

    var g = U.handle(frameMark, rect(x, y, w, h));
    g.x = X; g.y = Y;
    g.at = function (u, v) { return [X(u), Y(v)]; };
    g.origin = [ox, oy];
    g.plot = function (fnOrPts, po) {
      po = opts(po);
      var pts = [];
      if (typeof fnOrPts === 'function') {
        var from = num(po.from, xr[0]), to = num(po.to, xr[1]), n = M.max(8, M.min(400, num(po.samples, 80)));
        for (var i = 0; i <= n; i++) {
          var u = from + (to - from) * i / n, v = fnOrPts(u);
          pts.push(isNum(v) ? [u, v] : null);
        }
      } else if (Array.isArray(fnOrPts)) {
        pts = fnOrPts.map(function (p) { return Array.isArray(p) && isNum(p[0]) && isNum(p[1]) ? [p[0], p[1]] : null; });
      }
      // Split into runs that stay inside the graph.
      var lo = M.min(yr[0], yr[1]), hi = M.max(yr[0], yr[1]), slack = (hi - lo) * 0.02;
      var runs = [], run = [];
      pts.forEach(function (p) {
        if (p && p[1] >= lo - slack && p[1] <= hi + slack) run.push([X(p[0]), Y(U.clamp(p[1], lo, hi))]);
        else { if (run.length > 1) runs.push(run); run = []; }
      });
      if (run.length > 1) runs.push(run);
      if (!runs.length) { ctx.warn('plot() drew nothing inside the graph'); return null; }
      var straight = po.straight === true || (po.smooth !== true && typeof fnOrPts !== 'function' && pts.length <= 8);
      var tone = po.tone || 'blue';
      var series = null;
      runs.forEach(function (r) {
        var hdl = U.drawLine(r, { tone: tone, size: num(po.size, pt(3.2)), smooth: !straight, wobble: 0, glow: po.glow, dash: po.dash }, 'line');
        if (!series) series = hdl;
      });
      var lastRun = runs[runs.length - 1], end = lastRun[lastRun.length - 1];
      if (po.label) seriesLabel(runs, po.label, num(po.labelSize, 16), tone);
      series.points = runs;
      series.start = runs[0][0];
      series.end = end;
      return series;
    };
    g.line = function (p1, p2, po) { return g.plot([p1, p2], Object.assign({ straight: true }, opts(po))); };
    g.point = function (u, v, po) {
      if (Array.isArray(u)) { po = v; v = u[1]; u = u[0]; }
      po = opts(po);
      var px = X(u), py = Y(v);
      if (po.guides) {
        U.drawLine([[px, py], [px, oy]], { tone: 'grey', dash: true, wobble: 0, size: pt(1.6), glow: false }, 'line');
        U.drawLine([[px, py], [ox, py]], { tone: 'grey', dash: true, wobble: 0, size: pt(1.6), glow: false }, 'line');
      }
      var d = U.drawDot(px, py, { r: num(po.r, pt(5)), tone: po.tone || 'red' });
      if (po.label) U.drawText(px + pt(8), py - pt(8), po.label, { size: num(po.labelSize, 16), style: 'hand', valign: 'bottom', tone: po.labelTone }, 'piece');
      d.data = [u, v];
      return d;
    };
    return g;
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Timelines

  api.timeline = function (x, y, w, events, o) {
    o = opts(o);
    if (!numbers('timeline', [x, y, w])) return null;
    var list = (Array.isArray(events) ? events : []).map(function (e) {
      if (Array.isArray(e)) return { date: e[0], label: e[1] != null ? String(e[1]) : '' };
      if (isObj(e)) return { date: e.date != null ? e.date : e.at, label: String(e.label != null ? e.label : e.text || '') };
      return { date: e, label: '' };
    });
    if (!list.length) { ctx.warn('timeline() needs some events'); return null; }
    var numeric = list.every(function (e) { return isNum(e.date); }) && !o.even;
    var lo = numeric ? num(o.from, M.min.apply(null, list.map(function (e) { return e.date; }))) : 0;
    var hi = numeric ? num(o.to, M.max.apply(null, list.map(function (e) { return e.date; }))) : list.length - 1;
    var pad = M.min(pt(40), w * 0.08), inner = w - 2 * pad;
    var xs = list.map(function (e, i) {
      if (numeric && hi > lo) return x + pad + (e.date - lo) / (hi - lo) * inner;
      return x + pad + (list.length === 1 ? inner / 2 : i / (list.length - 1) * inner);
    });
    // Keep neighbours far enough apart to read.
    var minGap = num(o.minGap, M.min(pt(90), inner / M.max(1, list.length - 1)));
    var spread = false;
    for (var i = 1; i < xs.length; i++) if (xs[i] - xs[i - 1] < minGap) { xs[i] = xs[i - 1] + minGap; spread = true; }
    var overflow = xs[xs.length - 1] - (x + w - pad);
    if (overflow > 0) for (var j = 0; j < xs.length; j++) xs[j] -= overflow * (j / M.max(1, xs.length - 1)) + (j === 0 ? 0 : 0);
    if (spread) ctx.warn('spread out timeline events that were too close to read');

    var line = U.drawLine([[x, y], [x + w, y]], { tone: o.tone, wobble: 0.3, head: pt(11) }, 'arrow');
    var out = { line: line, events: [] };
    var labelSize = num(o.labelSize, 16), dateSize = num(o.dateSize, 15);
    var wrap = M.max(pt(70), M.min(pt(150), minGap * 0.95));
    list.forEach(function (e, k) {
      var ex = xs[k];
      U.drawDot(ex, y, { r: pt(5), tone: o.dotTone || 'orange' });
      var below = o.alternate ? k % 2 === 0 : true;
      var dateY = below ? y + pt(10) : y - pt(10);
      U.drawText(ex, dateY, String(e.date), { size: dateSize, style: 'bold', align: 'center', valign: below ? 'top' : 'bottom', place: false }, 'piece');
      var labelY = below ? dateY + dateSize * 1.5 : dateY - dateSize * 1.5;
      if (e.label) U.drawText(ex, labelY, e.label, { size: labelSize, style: 'hand', align: 'center', valign: below ? 'top' : 'bottom', wrap: wrap, place: false }, 'piece');
      out.events.push({ date: e.date, label: e.label, x: ex, y: y });
    });
    out.at = function (index) { var ev = out.events[index]; return ev ? [ev.x, ev.y] : null; };
    return out;
  };

  // For the modules loaded after this one (draw-extras.js): naming things beside them, calm spots, gel pills.
  U.pieces = {
    nameNear: nameNear, footprint: footprint, makeRoom: makeRoom, pillSize: pillSize, makePill: makePill,
    calmest: calmest, taken: taken, beside: beside, leader: leader
  };
});
