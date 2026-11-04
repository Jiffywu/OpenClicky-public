/*
 * OpenClicky guided steps: the drawing-language calls that turn an answer into one step of a walkthrough
 * (docs/dsl-guided.md).
 *
 * target() and hover() name the control the user should click or rest the pointer on next. They draw nothing
 * themselves: they push an invisible marker that the app reads when its line is spoken. The app then rings the real
 * control (snapped to the nearest Accessibility element), waits for the click, and starts the next turn by itself.
 * task() names the how-to, and waitForUser() marks a step the app can't watch (typing, dragging), so the next turn
 * starts once the user has done something and paused.
 */
__engine.registerModule(function (api, ctx) {
  'use strict';

  var U = ctx.util;
  var isNum = U.isNum, num = U.num, isObj = U.isObj, pt = U.pt;
  var pointers = 0, waits = 0;

  ctx.onBegin(function () { pointers = 0; waits = 0; });

  function words(v, max) { return v == null ? '' : String(v).replace(/\s+/g, ' ').trim().slice(0, max || 120); }
  function marker(kind, o) {
    var m = U.newMark(kind, o || {});
    // Invisible and instant: it only tells the app what to watch for, when its line is heard.
    m.__dur = 0.05; m.__adv = 0;
    return m;
  }

  // target(x, y, w, h, "Export")   a box around the control (top-left corner, width, height)
  // target(x, y, r, "Export")      a ring: centre and radius
  // target("e12", "Export")        an element id from the element list
  function pointer(role, args) {
    var a = Array.prototype.slice.call(args);
    var o = a.length && isObj(a[a.length - 1]) ? a.pop() : {};
    var label = '', box = null, element = null, ring = null;
    if (typeof a[0] === 'string') {
      element = words(a[0], 24);
      label = words(a[1]);
      if (!/^[A-Za-z][A-Za-z0-9_-]{0,23}$/.test(element)) { ctx.warn(role + '("…") needs an element id like "e12"'); return null; }
    } else if (a.length >= 4 && isNum(a[0]) && isNum(a[1]) && isNum(a[2]) && isNum(a[3])) {
      box = { x: Math.min(a[0], a[0] + a[2]), y: Math.min(a[1], a[1] + a[3]), w: Math.abs(a[2]), h: Math.abs(a[3]) };
      label = words(a[4]);
    } else if (a.length >= 2 && isNum(a[0]) && isNum(a[1])) {
      var r = isNum(a[2]) ? Math.abs(a[2]) : pt(24);
      ring = r;
      box = { x: a[0] - r, y: a[1] - r, w: 2 * r, h: 2 * r };
      label = words(isNum(a[2]) ? a[3] : a[2]);
    } else {
      ctx.warn(role + '() needs a box (x, y, w, h, "name"), a ring (x, y, r, "name") or an element id ("e12", "name")');
      return null;
    }
    if (pointers >= 1) { ctx.warn('one target() or hover() per answer: the walkthrough waits for one thing at a time; this one was skipped'); return null; }
    if (waits) ctx.warn(role + '() and waitForUser() don\'t go together: the step is either a click the app can see or manual work');
    pointers++;
    var m = marker(role, o);
    m.role = role;
    if (label) m.label = label;
    if (o.say || o.instruction) m.instruction = words(o.say || o.instruction, 200);
    if (element) m.element = element;
    if (box) {
      m.box = [box.x, box.y, box.w, box.h];
      m.at = [box.x + box.w / 2, box.y + box.h / 2];
      m.__box = box;
    } else {
      m.at = [0, 0];
    }
    if (ring != null) m.ring = ring;
    m.text = label || element || role;
    ctx.push(m);
    var h = U.handle(m, box || { x: 0, y: 0, w: 0, h: 0 });
    h.element = element;
    return h;
  }

  api.target = function () { return pointer('target', arguments); };
  api.hover = function () { return pointer('hover', arguments); };

  // task("Export the report as a PDF"): names the how-to this answer is a step of. Leaves no ink.
  api.task = function (label) {
    var text = words(label, 160);
    if (!text) { ctx.warn('task() needs the name of what the user is doing'); return null; }
    var m = marker('task');
    m.label = text;
    m.text = text;
    m.at = [0, 0];
    ctx.push(m);
    return null;
  };

  // waitForUser("Type your name in the box"): the user does this step by hand (typing, dragging), out of the app's
  // sight; the walkthrough resumes once they have acted and paused. Leaves no ink.
  api.waitForUser = function (note) {
    if (pointers) ctx.warn('waitForUser() and target() don\'t go together: the step is either a click the app can see or manual work');
    if (waits) return null;
    waits++;
    var m = marker('wait');
    var text = words(note, 200);
    if (text) m.note = text;
    m.text = text || 'waiting for the user';
    m.at = [0, 0];
    ctx.push(m);
    return null;
  };
});
