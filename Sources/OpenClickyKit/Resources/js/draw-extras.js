/*
 * OpenClicky drawing pieces, continued: more ways to mark the screen (ring, frame, trace, connect, strike, scroll,
 * cheer, spotlight) and more cards (sticky notes, receipts, clippings, legends, source lines, ties from words to a
 * picture). docs/dsl.md lists them for the model.
 *
 * Uses draw-pieces.js's helpers through ctx.util.pieces, looked up when a piece runs (the host loads draw-*.js in name
 * order, so this file loads first).
 */
__engine.registerModule(function (api, ctx) {
  'use strict';

  var U = ctx.util;
  // draw-pieces.js's helpers (nameNear, …), there by the time a program runs.
  var P = {
    nameNear: function (target, text, o) { return U.pieces.nameNear(target, text, o); }
  };
  var M = Math;
  var pt = U.pt, num = U.num, isNum = U.isNum, isObj = U.isObj;
  var cheers = 0;
  ctx.onBegin(function (canvas, keep) { if (!keep) cheers = 0; });

  function opts(o) { return isObj(o) ? o : {}; }
  function rect(x, y, w, h) { return { x: x, y: y, w: w, h: h }; }
  function numbers(name, values) {
    for (var i = 0; i < values.length; i++) if (!isNum(values[i])) { ctx.warn(name + '() needs numbers for its position and size'); return false; }
    return true;
  }
  // A box from a handle, a [x, y, w, h] list or a point.
  function boxFrom(v) {
    if (isObj(v) && isNum(v.x) && isNum(v.y)) return rect(v.x, v.y, num(v.w, 0), num(v.h, 0));
    if (Array.isArray(v) && isNum(v[0]) && isNum(v[1])) return rect(v[0], v[1], num(v[2], 0), num(v[3], 0));
    return null;
  }
  function edgeToward(b, tx, ty, gap) {
    var cx = b.x + b.w / 2, cy = b.y + b.h / 2, dx = tx - cx, dy = ty - cy, t = Infinity;
    if (b.w <= 0 && b.h <= 0) t = 0;
    else {
      if (dx) t = M.min(t, (b.w / 2) / M.abs(dx));
      if (dy) t = M.min(t, (b.h / 2) / M.abs(dy));
      if (!isFinite(t)) t = 0;
    }
    var len = M.hypot(dx, dy) || 1;
    return [cx + dx * t + dx / len * gap, cy + dy * t + dy / len * gap];
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Marking the screen

  // ring(x, y, w, h, "name"): a loop around one thing. Thin things get a pill-shaped loop, small square ones a round
  // loop, bigger ones a rounded box; the name sits beside it.
  api.ring = function (x, y, w, h, name, o) {
    if (isObj(name)) { o = name; name = null; }
    o = opts(o);
    if (!numbers('ring', [x, y, w, h])) return null;
    var b = rect(M.min(x, x + w), M.min(y, y + h), M.abs(w), M.abs(h));
    var pad = num(o.pad, pt(6)), short = M.min(b.w, b.h), long = M.max(b.w, b.h), hd;
    if (short <= pt(56) && long <= short * 1.4) {
      var rr = long / 2 + pad;
      hd = U.drawCircle(b.x + b.w / 2, b.y + b.h / 2, rr, rr, { tone: o.tone, size: o.size, wobble: 0.5, place: false });
    } else {
      var radius = isNum(o.r) ? o.r : short <= pt(56) ? short / 2 + pad : U.clamp(short * 0.12, pt(8), pt(18));
      hd = U.drawBox(b.x - pad, b.y - pad, b.w + 2 * pad, b.h + 2 * pad, { tone: o.tone, size: o.size, r: radius, wobble: 0.6, place: false });
    }
    if (hd) { var m = U.byId(hd.id); if (m) m.role = 'ring'; }
    if (name != null && String(name) !== '') P.nameNear(U.inflate(b, pad), name, o);
    return hd;
  };

  // frame(x, y, w, h, "name"): an area, the same as region().
  api.frame = function (x, y, w, h, name, o) { return api.region(x, y, w, h, name, o); };

  // trace([[x, y], …], {straight, fill, label}): a loop around an oddly shaped area.
  api.trace = function (pts, o) {
    o = opts(o);
    var list = U.toPoints(pts);
    if (list.length < 3) { ctx.warn('trace() needs at least three points around the area'); return null; }
    var hd = api.poly(list, { tone: o.tone, size: o.size, smooth: !o.straight, wobble: o.straight ? 0.6 : 0, fill: o.fill ? (o.fill === true ? o.tone || true : o.fill) : null, fillAlpha: num(o.fillAlpha, 0.18) });
    if (hd) { var m = U.byId(hd.id); if (m) m.role = 'trace'; }
    if (o.label) P.nameNear(U.boundsOf(list), o.label, o);
    return hd;
  };

  // connect(a, b, {label, bend}): a curved arrow from one thing on the screen to another (handles, boxes or points).
  api.connect = function (a, b, o) {
    o = opts(o);
    var ba = boxFrom(a), bb = boxFrom(b);
    if (!ba || !bb) { ctx.warn('connect(a, b) needs two things drawn before, or two points'); return null; }
    var from = edgeToward(ba, bb.x + bb.w / 2, bb.y + bb.h / 2, pt(6));
    var to = edgeToward(bb, ba.x + ba.w / 2, ba.y + ba.h / 2, pt(6));
    var hd = U.drawLine([from, to], { tone: o.tone, bend: num(o.bend, 0.2), label: o.label, size: o.size }, 'arrow');
    if (hd) { var m = U.byId(hd.id); if (m) m.role = 'connect'; }
    return hd;
  };

  // strike(x, y, w): a line through words on the screen.
  api.strike = function (x, y, w, o) {
    o = opts(o);
    if (!numbers('strike', [x, y, w])) return null;
    var hd = U.drawLine([[x, y], [x + w, y]], { tone: o.tone || 'red', size: o.size, wobble: num(o.wobble, 0.3), dodge: false }, 'line');
    if (hd) { var m = U.byId(hd.id); if (m) m.role = 'strike'; }
    return hd;
  };

  // scroll(x, y, "down", name): two chevrons saying "scroll this way".
  api.scroll = function (x, y, dir, name, o) {
    if (isObj(name)) { o = name; name = null; }
    o = opts(o);
    if (!numbers('scroll', [x, y])) return null;
    var up = String(dir || 'down').toLowerCase() === 'up', s = num(o.size, pt(14)), sign = up ? -1 : 1, gap = s * 0.7;
    var segs = [0, 1].map(function (k) {
      var cy = y + sign * k * gap;
      return [[x - s, cy - sign * s * 0.5], [x, cy + sign * s * 0.5], [x + s, cy - sign * s * 0.5]];
    });
    var m = U.newMark('line', o, 'scroll');
    var r = rect(x - s, M.min(y - s, y + sign * gap - s), 2 * s, gap + 2 * s);
    U.strokeStyle(m, { tone: o.tone }, r, false);
    m.pts = segs[0]; m.segs = segs; m.role = 'scroll';
    m.__box = r; m.__layout = 'stroke';
    var hd = U.handle(ctx.push(m));
    var label = name != null ? name : up ? 'scroll up' : 'scroll down';
    if (label) P.nameNear(r, label, o);
    return hd;
  };

  // cheer(x, y, "＼(^o^)／"): a little face in a pill, at most once per drawing.
  api.cheer = function (x, y, face, o) {
    o = opts(o);
    if (!numbers('cheer', [x, y])) return null;
    if (cheers >= 1) { ctx.warn('one cheer() per drawing'); return null; }
    cheers++;
    var hd = api.pill(x, y, face != null && String(face) !== '' ? String(face).slice(0, 16) : '(^o^)/', { tone: o.tone, size: o.size, align: o.align });
    if (hd) { var m = U.byId(hd.id); if (m) m.role = 'cheer'; }
    return hd;
  };

  api.num = function (x, y, n, o) { return api.badge(x, y, n, o); };

  // spotlight(x, y, w, h, {pad, r, alpha}): dims the screen except one area. With no box it dims everything.
  api.spotlight = function (x, y, w, h, o) {
    if (isObj(x)) { o = x; x = null; }
    o = opts(o);
    var c = ctx.canvas, m = U.newMark('spotlight', o, 'spotlight');
    m.at = [0, 0]; m.w = c.width; m.h = c.height;
    if (isNum(x) && isNum(y) && isNum(w) && isNum(h)) {
      var pad = num(o.pad, pt(8));
      m.hole = [M.min(x, x + w) - pad, M.min(y, y + h) - pad, M.abs(w) + 2 * pad, M.abs(h) + 2 * pad];
      m.r = num(o.r, pt(10));
    }
    m.tone = '#0C0E12';
    m.alpha = U.clamp(num(o.alpha, 0.6), 0.1, 0.9);
    m.role = 'stage';
    m.__noCard = true;
    m.__dur = 0.5; m.__adv = 0.2;
    return U.handle(ctx.push(m), m.hole ? rect(m.hole[0], m.hole[1], m.hole[2], m.hole[3]) : rect(0, 0, c.width, c.height));
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Cards

  var STICKY = { butter: '#FFE98A', yellow: '#FFE98A', mint: '#C8F0D2', green: '#C8F0D2', peach: '#FFD3C0', orange: '#FFD3C0',
    lilac: '#DCD3FA', purple: '#DCD3FA', sky: '#CFE6FB', blue: '#CFE6FB', pink: '#FBD3E2', white: '#FBFAF7' };

  // sticky(x, y, "words", "butter", {size, tilt, textSize}): a square note, a little crooked, words fitted inside.
  api.sticky = function (x, y, text, color, o) {
    if (isObj(color)) { o = color; color = null; }
    o = opts(o);
    if (!numbers('sticky', [x, y])) return null;
    var side = U.clamp(num(o.size, 170), 80, 420);
    var r = U.keepOnCanvas(U.placeContainer(rect(x, y, side, side), 'sticky', o));
    var m = U.newMark('sticky', o, String(text || ''));
    var key = String(color || o.color || 'butter').toLowerCase();
    m.paper = STICKY[key] || U.toneHex(color || 'cream');
    m.at = [r.x, r.y]; m.w = side; m.h = side;
    m.tilt = U.clamp(num(o.tilt, -2), -12, 12);
    var words = String(text == null ? '' : text);
    if (words) {
      var block = U.textBlock(words, num(o.textSize, 24), 'hand', { fit: [side - 30, side - 40] });
      m.text = words; m.lines = block.lines; m.size = block.size; m.lh = block.lh;
    }
    m.tone = U.toneHex(o.tone || '#2A2C33');
    m.__box = r; m.__layout = 'container'; m.__label = words.slice(0, 24) || 'sticky';
    m.__ground = m.paper;
    m.__dur = 0.45; m.__adv = 0.35;
    return U.handle(ctx.push(m));
  };

  // receipt(x, y, "Title", ["first", "second", …], {w}): a card with a numbered list.
  api.receipt = function (x, y, title, items, o) {
    o = opts(o);
    if (!numbers('receipt', [x, y])) return null;
    var list = (Array.isArray(items) ? items : []).map(function (i) { return String(i); }).filter(function (i) { return i; }).slice(0, 30);
    if (!list.length) { ctx.warn('receipt() needs a list of items'); return null; }
    var w = num(o.w, 340), lh = 30;
    var card = api.paper(x, y, w, 28 + 18 * 1.6 + list.length * lh + 6, { title: title != null ? String(title) : '', board: o.board || 'plain' });
    if (!card) return null;
    list.forEach(function (item, i) {
      U.drawText(card.x, card.y + i * lh, (i + 1) + '.  ' + item, { size: num(o.textSize, 18), style: 'hand', wrap: card.w, place: false });
    });
    return card;
  };

  // clipping(x, y, w, "Title", "body words", "source.com", {h}): a cutting from an article, credited.
  api.clipping = function (x, y, w, title, body, source, o) {
    o = opts(o);
    if (!numbers('clipping', [x, y, w])) return null;
    var words = String(body == null ? '' : body);
    var block = U.textBlock(words, 17, 'ui', { wrap: M.max(80, w - 36) });
    var h = num(o.h, 28 + 18 * 1.6 + block.h + (source ? 30 : 8));
    var card = api.paper(x, y, w, h, { title: title != null ? String(title) : '', board: 'plain' });
    if (!card) return null;
    if (words) U.drawText(card.x, card.y, words, { size: 17, style: 'ui', tone: 'dark', wrap: card.w, place: false });
    if (source) U.drawText(card.x, card.y + card.h - 18, String(source), { size: 13, style: 'ui', tone: 'grey', place: false });
    return card;
  };

  // legend(x, y, [["red", "hot"], ["blue", "cold"]]): colour keys in a row. Returns its width.
  api.legend = function (x, y, entries, o) {
    o = opts(o);
    if (!numbers('legend', [x, y])) return 0;
    var cx = x, size = num(o.size, 16);
    (Array.isArray(entries) ? entries : []).slice(0, 12).forEach(function (e) {
      if (!Array.isArray(e) || e.length < 2) return;
      var d = U.drawDot(cx + pt(6), y + size * 0.6, { r: pt(6), tone: e[0], contrast: false, glow: false });
      if (d) { var dm = U.byId(d.id); if (dm) dm.role = 'key'; }
      var t = U.drawText(cx + pt(16), y, String(e[1]), { size: size, style: 'hand', place: false });
      cx += pt(16) + (t ? t.w : 0) + pt(18);
    });
    return cx - x;
  };

  // sources(x, y, [["nasa.gov", "NASA"], …]): one grey credit line, duplicates removed.
  api.sources = function (x, y, list, o) {
    o = opts(o);
    if (!numbers('sources', [x, y])) return null;
    var seen = {}, names = [];
    (Array.isArray(list) ? list : []).forEach(function (s) {
      var name = Array.isArray(s) ? (s[1] || s[0]) : s;
      name = name == null ? '' : String(name).trim();
      if (name && !seen[name.toLowerCase()]) { seen[name.toLowerCase()] = 1; names.push(name); }
    });
    if (!names.length) { ctx.warn('sources() needs the sites it credits'); return null; }
    var t = U.drawText(x, y, 'Sources: ' + names.join(' · '), { size: num(o.size, 13), style: 'ui', tone: 'grey', wrap: o.maxWidth, place: false });
    if (t) { var m = U.byId(t.id); if (m) m.role = 'source'; }
    return t;
  };

  // tie([x, y], photoOrBox, {bend}): a thin pen arrow from a row of words to its picture. It starts just past the end of
  // the words written on that row (whatever their measured width), and stops short of the picture.
  api.tie = function (from, target, o) {
    o = opts(o);
    var start = Array.isArray(from) && isNum(from[0]) ? from : isObj(from) && isNum(from.x) ? [from.x + num(from.w, 0), from.y + num(from.h, 0) / 2] : null;
    var box = boxFrom(target);
    if (!start || !box) { ctx.warn('tie([x, y], photo) needs a point and the picture to tie it to'); return null; }
    var toward = box.x + box.w / 2 >= start[0] ? 1 : -1;
    // Snap to the row's words: the text on this row that starts on the near side and reaches farthest toward the box.
    var best = null, marks = U.marks();
    for (var i = 0; i < marks.length; i++) {
      var m = marks[i];
      if (m.__erased || m.do !== 'text' || m.role === 'source') continue;
      var b = U.boxOf(m), cy = b.y + b.h / 2;
      if (M.abs(cy - start[1]) > M.max(b.h, 20)) continue;
      var reach = toward > 0 ? b.x + b.w : b.x;
      if (toward > 0 ? b.x > start[0] + 40 : b.x + b.w < start[0] - 40) continue;
      if (!best || (toward > 0 ? reach > best.reach : reach < best.reach)) best = { reach: reach, cy: cy };
    }
    if (best) start = [best.reach + toward * pt(8), best.cy];
    var end = edgeToward(box, start[0], start[1], pt(6));
    var hd = U.drawLine([start, end], { tone: o.tone || 'dark', size: num(o.size, pt(1.8)), bend: num(o.bend, 0.18), glow: false, head: pt(9), dodge: false }, 'arrow');
    if (hd) { var lm = U.byId(hd.id); if (lm) { lm.role = 'tie'; lm.tieTo = [box.x, box.y, box.w, box.h]; } }
    return hd;
  };

  // molecule(): HeyClicky draws structures with a library this app doesn't carry.
  api.molecule = function () {
    ctx.warn('molecule() is not available; draw the structure with circle(), line() and text()');
    return null;
  };
});
