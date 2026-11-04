/*
 * OpenClicky drawing engine (2D).
 *
 * Runs a drawing program written in OpenClicky's drawing language (docs/dsl.md) one top-level statement at a time
 * while the program text is still streaming in, turns drawing calls into marks, paces the marks against the voice
 * and hands events to the host. The interface with the host is fixed in docs/drawing-contract.md.
 *
 * It runs inside a JavaScriptCore context created by DrawingEngineHost (Swift). Nothing here can open a socket, read
 * a file or schedule a timer; the host's few measurement functions (`__host`) are its only contact with the outside.
 */
(function (global) {
  'use strict';

  var VERSION = '1';
  var MAX_MARKS = 2000;
  // Programs are model-written, so what reaches the painter (on the app's main thread) is kept to sane sizes.
  var MAX_COORD = 100000;      // canvas units; 2D mark numbers are clamped to ±this when released
  var MAX_POINTS = 5000;       // points in one line or curve
  var MAX_TEXT = 4000;         // characters in one text mark
  var MAX_LINES = 200;         // wrapped lines in one text mark
  var MAX_TEXT_SIZE = 400;     // units
  var MAX_WARNINGS = 40;
  var DEFAULT_INK = '#3380FF';
  var PAPER_INK = '#2A2C33';
  var nowMs = Date.now.bind(Date);
  var stringify = JSON.stringify.bind(JSON);
  var M = Math;
  var indirectEval = global.eval;
  var FunctionCtor = Function;
  // The language's own globals (Object, Array, JSON, …), named before any script adds to them. sealGlobals() freezes
  // them, so a program can't change how later programs, or this engine, behave.
  var INTRINSIC_NAMES = Object.getOwnPropertyNames(global).filter(function (n) { return n !== '__host'; });
  // The host's functions, taken off the global object by sealGlobals() so program code can't reach them.
  var hostObject = null;

  // ---------------------------------------------------------------------------------------------------------------
  // Small helpers

  function hostFn(name) {
    var h = hostObject || global.__host;
    return h && typeof h[name] === 'function' ? h[name] : null;
  }
  function clock() {
    var f = hostFn('now');
    var t = f ? +f() : NaN;
    return isFinite(t) ? t : nowMs() / 1000;
  }
  // The drawing's own time: the host clock less the time spent paused (pause() and resume()), frozen while paused.
  // The painter keeps the same time (DrawingPainter.pause), so marks paced after a pause land where they should.
  function drawNow() {
    if (!prog) return clock();
    return (prog.paused ? prog.pausedAt : clock()) - prog.pausedTotal;
  }
  function log(message) {
    var f = hostFn('log');
    if (f) f(String(message));
  }
  function isNum(v) { return typeof v === 'number' && isFinite(v); }
  function num(v, fallback) { return isNum(v) ? v : fallback; }
  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }
  function round(v, places) { var k = M.pow(10, places); return M.round(v * k) / k; }
  function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
  function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }

  function hashString(s) {
    var h = 2166136261;
    for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = M.imul(h, 16777619); }
    return h >>> 0;
  }
  // A small deterministic generator: hand-drawn wobble depends only on the program, never on chance.
  function seeded(seed) {
    var a = seed >>> 0;
    return function () {
      a = (a + 0x6D2B79F5) >>> 0;
      var t = a;
      t = M.imul(t ^ (t >>> 15), t | 1);
      t ^= t + M.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Colour

  var TONES = {
    dark: '#26282E', grey: '#7D828C', white: '#FFFFFF', black: '#121317', yellow: '#FFD23F', orange: '#FF8F3A',
    red: '#E5484D', pink: '#F28DB2', purple: '#8A6CE0', blue: '#2F6FDB', sky: '#5DB0F5', teal: '#22A99A',
    green: '#3C9F5B', mint: '#8CDCAB', brown: '#9A6842', cream: '#FFF5DC'
  };
  var TONE_ALIASES = {
    gray: 'grey', gold: 'yellow', golden: 'yellow', amber: 'yellow', violet: 'purple', lilac: 'purple', lavender: 'purple',
    lime: 'mint', cyan: 'sky', lightblue: 'sky', navy: 'blue', magenta: 'pink', rose: 'pink', crimson: 'red',
    coral: 'red', beige: 'cream', tan: 'brown', olive: 'green', turquoise: 'teal', charcoal: 'dark'
  };

  function parseHex(s) {
    if (typeof s !== 'string') return null;
    var m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(s.trim());
    if (!m) return null;
    var h = m[1];
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
  }
  function toHex(rgb) {
    var s = '#';
    for (var i = 0; i < 3; i++) {
      var v = clamp(M.round(rgb[i]), 0, 255).toString(16).toUpperCase();
      s += v.length < 2 ? '0' + v : v;
    }
    return s;
  }
  function linear(c) { c /= 255; return c <= 0.04045 ? c / 12.92 : M.pow((c + 0.055) / 1.055, 2.4); }
  function luminance(rgb) { return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2]); }
  function contrast(a, b) { var hi = M.max(a, b), lo = M.min(a, b); return (hi + 0.05) / (lo + 0.05); }
  function mix(a, b, t) { return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]; }
  function toHSL(rgb) {
    var r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255;
    var max = M.max(r, g, b), min = M.min(r, g, b), l = (max + min) / 2, h = 0, s = 0;
    if (max !== min) {
      var d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
      else if (max === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h /= 6;
    }
    return [h, s, l];
  }
  function fromHSL(hsl) {
    var h = hsl[0], s = hsl[1], l = hsl[2];
    function f(p, q, t) {
      if (t < 0) t += 1; if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }
    if (s === 0) return [l * 255, l * 255, l * 255];
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    return [f(p, q, h + 1 / 3) * 255, f(p, q, h) * 255, f(p, q, h - 1 / 3) * 255];
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Lexing complete statements (for transforms and for finding spoken lines)

  function identStart(c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_' || c === '$' || c > '\u007f'; }
  function identChar(c) { return identStart(c) || (c >= '0' && c <= '9'); }
  var REGEX_AFTER_WORDS = { 'return': 1, 'typeof': 1, 'instanceof': 1, 'in': 1, 'of': 1, 'new': 1, 'delete': 1, 'void': 1, 'throw': 1, 'case': 1, 'do': 1, 'else': 1, 'yield': 1, 'await': 1 };

  function regexAllowed(prev) {
    if (!prev) return true;
    if (prev.t === 'p') return prev.v !== ')' && prev.v !== ']' && prev.v !== '}';
    if (prev.t === 'id') return !!REGEX_AFTER_WORDS[prev.v];
    return false;
  }

  // Skip a template literal starting at the backtick at `i`. Returns {end, subst}.
  function skipTemplate(src, i) {
    var n = src.length, j = i + 1, subst = false;
    while (j < n) {
      var c = src[j];
      if (c === '\\') { j += 2; continue; }
      if (c === '`') return { end: j + 1, subst: subst };
      if (c === '$' && src[j + 1] === '{') { subst = true; j = skipCode(src, j + 2, '}'); continue; }
      j++;
    }
    return { end: n, subst: subst };
  }
  // Skip code until the closing character at depth 0 (used inside `${…}`). Returns the index after it.
  function skipCode(src, i, close) {
    var n = src.length, depth = 0, j = i;
    while (j < n) {
      var c = src[j];
      if (c === '"' || c === "'") { j = skipString(src, j); continue; }
      if (c === '`') { j = skipTemplate(src, j).end; continue; }
      if (c === '/' && src[j + 1] === '/') { while (j < n && src[j] !== '\n') j++; continue; }
      if (c === '/' && src[j + 1] === '*') { var e = src.indexOf('*/', j + 2); j = e < 0 ? n : e + 2; continue; }
      if (c === '{' || c === '(' || c === '[') depth++;
      else if (c === '}' || c === ')' || c === ']') {
        if (depth === 0 && c === close) return j + 1;
        depth--;
      }
      j++;
    }
    return n;
  }
  function skipString(src, i) {
    var q = src[i], n = src.length, j = i + 1;
    while (j < n) {
      var c = src[j];
      if (c === '\\') { j += 2; continue; }
      if (c === q || c === '\n') return j + 1;
      j++;
    }
    return n;
  }

  // Tokens: {t: 'id'|'num'|'str'|'tpl'|'re'|'p', v, s, e}. Comments and whitespace are dropped.
  function lex(src) {
    var toks = [], n = src.length, i = 0, prev = null;
    while (i < n) {
      var c = src[i], s = i, tok;
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === ' ' || c === '﻿') { i++; continue; }
      if (c === '/' && src[i + 1] === '/') { while (i < n && src[i] !== '\n') i++; continue; }
      if (c === '/' && src[i + 1] === '*') { var e = src.indexOf('*/', i + 2); i = e < 0 ? n : e + 2; continue; }
      if (c === '"' || c === "'") { i = skipString(src, i); tok = { t: 'str', v: src.slice(s, i), s: s, e: i }; }
      else if (c === '`') { var tp = skipTemplate(src, i); i = tp.end; tok = { t: 'tpl', v: src.slice(s, i), s: s, e: i, subst: tp.subst }; }
      else if (identStart(c)) { while (i < n && identChar(src[i])) i++; tok = { t: 'id', v: src.slice(s, i), s: s, e: i }; }
      else if ((c >= '0' && c <= '9') || (c === '.' && src[i + 1] >= '0' && src[i + 1] <= '9')) {
        while (i < n && (identChar(src[i]) || src[i] === '.')) i++;
        tok = { t: 'num', v: src.slice(s, i), s: s, e: i };
      } else if (c === '/' && regexAllowed(prev)) {
        var j = i + 1, inClass = false;
        while (j < n && src[j] !== '\n') {
          var d = src[j];
          if (d === '\\') { j += 2; continue; }
          if (d === '[') inClass = true; else if (d === ']') inClass = false;
          else if (d === '/' && !inClass) { j++; break; }
          j++;
        }
        while (j < n && identChar(src[j])) j++;
        i = j;
        tok = { t: 're', v: src.slice(s, i), s: s, e: i };
      } else if (c === '=' && src[i + 1] === '>') { i += 2; tok = { t: 'p', v: '=>', s: s, e: i }; }
      else if (c === '?' && src[i + 1] === '.' && !(src[i + 2] >= '0' && src[i + 2] <= '9')) { i += 2; tok = { t: 'p', v: '?.', s: s, e: i }; }
      else { i++; tok = { t: 'p', v: c, s: s, e: i }; }
      toks.push(tok);
      prev = tok;
    }
    return toks;
  }

  function matchParen(toks, i) {
    var depth = 0;
    for (var j = i; j < toks.length; j++) {
      var v = toks[j].t === 'p' ? toks[j].v : '';
      if (v === '(' || v === '[' || v === '{') depth++;
      else if (v === ')' || v === ']' || v === '}') { depth--; if (depth === 0) return j; }
    }
    return -1;
  }

  // Decode a string or template literal the way SayLineExtractor does, so spoken-line texts match.
  function decodeLiteral(lit) {
    var body = lit.slice(1, lit.length > 1 && lit[lit.length - 1] === lit[0] ? lit.length - 1 : lit.length);
    var out = '';
    for (var i = 0; i < body.length; i++) {
      var c = body[i];
      if (c !== '\\') { out += c; continue; }
      var d = body[++i];
      if (d === undefined) break;
      if (d === 'n') out += '\n';
      else if (d === 't') out += '\t';
      else if (d === 'r' || d === '\n') { /* dropped */ }
      else if (d === 'u') {
        var hexDigits;
        if (body[i + 1] === '{') { var close = body.indexOf('}', i + 2); hexDigits = body.slice(i + 2, close < 0 ? body.length : close); i = close < 0 ? body.length : close; }
        else { hexDigits = body.slice(i + 1, i + 5); i += 4; }
        var cp = parseInt(hexDigits, 16);
        if (isFinite(cp)) { try { out += String.fromCodePoint(cp); } catch (e) { /* invalid code point */ } }
      } else out += d;
    }
    return out.trim();
  }

  // The say("…") literals in a statement, in source order, as SayLineExtractor sees them.
  function sayLiterals(src) {
    var toks = lex(src), found = [];
    for (var i = 0; i + 2 < toks.length; i++) {
      var t = toks[i];
      if (t.t !== 'id' || t.v !== 'say') continue;
      var before = toks[i - 1];
      if (before && before.t === 'p' && (before.v === '.' || before.v === '?.')) continue;
      if (toks[i + 1].t !== 'p' || toks[i + 1].v !== '(') continue;
      var lit = toks[i + 2];
      if (lit.t === 'str' || (lit.t === 'tpl' && !lit.subst)) {
        var text = decodeLiteral(lit.v);
        if (text) found.push(text);
      }
    }
    return found;
  }

  // Statements run one at a time in separate evaluations, so each is adjusted first:
  //  - a leading const or let is turned into var: the binding then outlives this evaluation and later statements
  //    (and follow-up turns) can still use it;
  //  - a function or class declaration is turned into an assignment, which lets the program define its own
  //    `box`, `say`, … over the vocabulary's version;
  //  - loop conditions and function bodies call __lp(), the guard that throws once the statement's time is up.
  function transform(src) {
    var toks = lex(src), edits = [];
    function insert(at, text) { edits.push({ s: at, e: at, text: text }); }
    function replace(tok, text) { edits.push({ s: tok.s, e: tok.e, text: text }); }

    var head = toks[0];
    if (head && head.t === 'id') {
      if ((head.v === 'const' || head.v === 'let') && toks[1] && (toks[1].t === 'id' || toks[1].v === '{' || toks[1].v === '[')) replace(head, 'var');
      else if (head.v === 'function' || (head.v === 'async' && toks[1] && toks[1].v === 'function')) {
        var k = head.v === 'async' ? 2 : 1;
        if (toks[k] && toks[k].v === '*') k++;
        if (toks[k] && toks[k].t === 'id') insert(head.s, 'var ' + toks[k].v + ' = ');
      } else if (head.v === 'class' && toks[1] && toks[1].t === 'id') insert(head.s, 'var ' + toks[1].v + ' = ');
    }

    for (var i = 0; i < toks.length; i++) {
      var t = toks[i], next = toks[i + 1];
      if (t.t === 'id' && t.v === 'while' && next && next.v === '(') {
        var close = matchParen(toks, i + 1);
        if (close > 0) { insert(next.e, '__lp() && ('); insert(toks[close].s, ')'); }
      } else if (t.t === 'id' && t.v === 'for' && next && next.v === '(') {
        var end = matchParen(toks, i + 1), semis = [], depth = 0;
        for (var j = i + 1; end > 0 && j < end; j++) {
          var v = toks[j].t === 'p' ? toks[j].v : '';
          if (v === '(' || v === '[' || v === '{') depth++;
          else if (v === ')' || v === ']' || v === '}') depth--;
          else if (v === ';' && depth === 1) semis.push(j);
        }
        if (semis.length === 2) {
          if (semis[1] === semis[0] + 1) insert(toks[semis[0]].e, ' __lp() ');
          else { insert(toks[semis[0]].e, ' __lp() && ('); insert(toks[semis[1]].s, ')'); }
        }
      } else if (t.t === 'id' && t.v === 'function') {
        var p = i + 1;
        if (toks[p] && toks[p].v === '*') p++;
        if (toks[p] && toks[p].t === 'id') p++;
        if (toks[p] && toks[p].v === '(') {
          var pc = matchParen(toks, p);
          if (pc > 0 && toks[pc + 1] && toks[pc + 1].v === '{') insert(toks[pc + 1].e, '__lp();');
        }
      } else if (t.t === 'p' && t.v === '=>' && next && next.v === '{') {
        insert(next.e, '__lp();');
      }
    }
    if (!edits.length) return src;
    edits.sort(function (a, b) { return b.s - a.s || b.e - a.e; });
    var out = src;
    for (var x = 0; x < edits.length; x++) out = out.slice(0, edits[x].s) + edits[x].text + out.slice(edits[x].e);
    return out;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Streaming statement splitter
  //
  // Walks the program text once as it arrives and reports where each top-level statement ends. It tracks brackets,
  // strings, template literals (with nested `${}`), comments, regular expressions and ``` fence lines. A statement
  // ends after `;`, a newline or a closing `}` at depth 0, once the next significant character shows the code does
  // not continue the same expression (`.`, an operator, `else`, `catch`, …).

  var CONTINUE_CHARS = '.?:+-*/%&|^,=<>)]';
  var NO_END_CHARS = '=+-*/%&|^,([{:?<>!~.';
  var NO_END_WORDS = { 'else': 1, 'new': 1, 'typeof': 1, 'in': 1, 'of': 1, 'instanceof': 1, 'void': 1, 'delete': 1, 'case': 1, 'do': 1, 'var': 1, 'let': 1, 'const': 1, 'function': 1, 'class': 1, 'extends': 1, 'throw': 1, 'yield': 1, 'await': 1, 'async': 1 };

  function Splitter() {
    this.text = '';
    this.pos = 0;
    this.start = 0;
    this.done = false;
    this.mode = 'code';
    this.quote = '';
    this.escape = false;
    this.inClass = false;
    this.stack = [];
    this.pending = -1;
    this.last = '';
    this.last2 = '';
    this.lastKind = '';
    this.lastWord = '';
    this.firstWord = '';
    this.significant = false;
    this.lineStart = true;
    this.fenceStart = -1;
    this.fences = [];
    this.out = [];
  }
  Splitter.prototype.push = function (s) { this.text += s; this.scan(); };
  Splitter.prototype.finish = function () {
    this.done = true;
    this.scan();
    if (this.mode === 'fence') { this.fences.push([this.fenceStart, this.text.length]); this.mode = 'code'; }
    if (this.significant) this.emit(this.text.length);
  };
  Splitter.prototype.take = function () { var o = this.out; this.out = []; return o; };
  Splitter.prototype.emit = function (end) {
    if (end > this.start) this.out.push({ s: this.start, e: end });
    this.start = end;
    this.pending = -1;
    this.significant = false;
    this.firstWord = '';
    this.last = this.last2 = this.lastKind = this.lastWord = '';
  };
  // The source of a range with fence lines blanked out.
  Splitter.prototype.slice = function (s, e) {
    var src = this.text.slice(s, e);
    for (var i = 0; i < this.fences.length; i++) {
      var f = this.fences[i];
      if (f[1] <= s || f[0] >= e) continue;
      var a = M.max(f[0], s) - s, b = M.min(f[1], e) - s;
      src = src.slice(0, a) + new Array(b - a + 1).join(' ') + src.slice(b);
    }
    return src;
  };
  Splitter.prototype.canEndAtNewline = function () {
    if (!this.significant) return false;
    if (this.lastKind === 'p' && NO_END_CHARS.indexOf(this.last) >= 0) {
      return (this.last === '+' && this.last2 === '+') || (this.last === '-' && this.last2 === '-');
    }
    if (this.lastKind === 'id' && NO_END_WORDS[this.lastWord]) return false;
    return true;
  };
  Splitter.prototype.note = function (kind, value) {
    this.last2 = this.lastKind === 'p' ? this.last : '';
    this.lastKind = kind;
    this.last = kind === 'id' || kind === 'num' ? value[value.length - 1] : value;
    if (kind === 'id') { this.lastWord = value; if (!this.firstWord) this.firstWord = value; }
    else this.lastWord = '';
    this.significant = true;
  };
  // Decide a candidate statement end once the next significant character is visible.
  Splitter.prototype.resolve = function (i) {
    var T = this.text, c = T[i];
    if (CONTINUE_CHARS.indexOf(c) >= 0) return 'continue';
    if (identStart(c)) {
      var j = i;
      while (j < T.length && identChar(T[j])) j++;
      if (j >= T.length && !this.done) return 'wait';
      var w = T.slice(i, j);
      if (w === 'else' || w === 'catch' || w === 'finally' || w === 'instanceof' || w === 'in' || w === 'of') return 'continue';
      if (w === 'while' && this.firstWord === 'do') return 'continue';
    }
    return 'split';
  };
  Splitter.prototype.scan = function () {
    var T = this.text, n = T.length;
    while (this.pos < n) {
      var i = this.pos, c = T[i];
      switch (this.mode) {
        case 'line':
          if (c === '\n') { this.mode = 'code'; continue; }
          this.pos++; continue;
        case 'block':
          if (c === '*' && T[i + 1] === '/') { this.mode = 'code'; this.pos += 2; continue; }
          if (c === '*' && i + 1 >= n && !this.done) return;
          this.pos++; continue;
        case 'fence':
          if (c === '\n') { this.fences.push([this.fenceStart, i]); this.mode = 'code'; continue; }
          this.pos++; continue;
        case 'str':
          if (this.escape) this.escape = false;
          else if (c === '\\') this.escape = true;
          else if (c === this.quote || c === '\n') { this.mode = 'code'; this.note('str', c); }
          this.pos++; continue;
        case 'tpl':
          if (this.escape) { this.escape = false; this.pos++; continue; }
          if (c === '\\') { this.escape = true; this.pos++; continue; }
          if (c === '`') { this.mode = 'code'; this.note('str', c); this.pos++; continue; }
          if (c === '$') {
            if (i + 1 >= n && !this.done) return;
            if (T[i + 1] === '{') { this.stack.push('${'); this.mode = 'code'; this.pos += 2; continue; }
          }
          this.pos++; continue;
        case 're':
          if (this.escape) this.escape = false;
          else if (c === '\\') this.escape = true;
          else if (c === '[') this.inClass = true;
          else if (c === ']') this.inClass = false;
          else if (c === '\n') { this.mode = 'code'; continue; }
          else if (c === '/' && !this.inClass) { this.mode = 'code'; this.note('re', '/'); }
          this.pos++; continue;
      }

      // Code.
      if (this.lineStart && c === '`') {
        if (n - i < 3 && !this.done) return;
        if (T.substr(i, 3) === '```') {
          if (this.stack.length === 0 && this.pending >= 0) this.emit(this.pending);
          this.mode = 'fence'; this.fenceStart = i; this.pos += 3; continue;
        }
      }
      if (c === ' ' || c === '\t' || c === '\r' || c === '\n' || c === ' ' || c === '﻿') {
        if (c === '\n') {
          this.lineStart = true;
          if (this.stack.length === 0 && this.pending < 0 && this.canEndAtNewline()) this.pending = i;
        }
        this.pos++; continue;
      }
      if (c === '/') {
        if (i + 1 >= n && !this.done) return;
        if (T[i + 1] === '/') { this.mode = 'line'; this.pos += 2; continue; }
        if (T[i + 1] === '*') { this.mode = 'block'; this.pos += 2; continue; }
      }
      this.lineStart = false;
      if (this.stack.length === 0 && this.pending >= 0) {
        var r = this.resolve(i);
        if (r === 'wait') return;
        if (r === 'split') this.emit(this.pending);
        this.pending = -1;
      }
      if (identStart(c) || (c >= '0' && c <= '9')) {
        var j = i;
        while (j < n && (identChar(T[j]) || (c >= '0' && c <= '9' && T[j] === '.'))) j++;
        if (j >= n && !this.done) return;
        this.note(c >= '0' && c <= '9' ? 'num' : 'id', T.slice(i, j));
        this.pos = j;
        continue;
      }
      if (c === '"' || c === "'") { this.mode = 'str'; this.quote = c; this.escape = false; this.significant = true; this.pos++; continue; }
      if (c === '`') { this.mode = 'tpl'; this.escape = false; this.significant = true; this.pos++; continue; }
      if (c === '/') {
        var prevTok = this.lastKind ? { t: this.lastKind === 'str' || this.lastKind === 're' ? 'str' : this.lastKind, v: this.lastKind === 'id' ? this.lastWord : this.last } : null;
        if (regexAllowed(prevTok)) { this.mode = 're'; this.escape = false; this.inClass = false; this.significant = true; this.pos++; continue; }
      }
      if (c === '(' || c === '[' || c === '{') { this.stack.push(c); this.note('p', c); this.pos++; continue; }
      if (c === ')' || c === ']' || c === '}') {
        var top = this.stack.pop();
        if (top === '${' && c === '}') { this.mode = 'tpl'; this.pos++; continue; }
        this.note('p', c);
        this.pos++;
        if (c === '}' && this.stack.length === 0 && this.pending < 0) this.pending = i + 1;
        continue;
      }
      this.note('p', c);
      this.pos++;
      if (c === ';' && this.stack.length === 0 && this.pending < 0) this.pending = i + 1;
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Engine state

  var modules = [];          // registered plugin functions
  var beginHooks = [];       // plugin callbacks run on every begin()
  var patchHooks = [];       // plugin callbacks run when the host patches a mark (host requests, below)
  var requestSerial = 0;     // host request refs are never reused, so a late answer can't reach another card's mark
  var api = Object.create(null);  // everything a program can call; the prototype of each card's scope
  var card = null;           // what is on the canvas (survives `keep` turns)
  var prog = null;           // the program being run
  var events = [];
  var baselineGlobals = null;
  var guard = { deadline: 0, count: 0, tripped: false, limitMs: 400 };
  var currentScope = null;

  Object.defineProperty(global, '__drawScope', { get: function () { return currentScope; }, configurable: false });

  function timeoutError() {
    var e = new Error('this statement ran longer than ' + guard.limitMs + ' ms and was stopped');
    e.__drawTimeout = true;
    return e;
  }
  function loopGuard() {
    if (guard.tripped) throw timeoutError();
    if ((++guard.count & 255) === 0 && nowMs() > guard.deadline) { guard.tripped = true; throw timeoutError(); }
    return true;
  }
  function checkDeadline() {
    if (guard.tripped || (guard.deadline && nowMs() > guard.deadline)) { guard.tripped = true; throw timeoutError(); }
  }

  function refuse(what) {
    return function () { throw new Error(what + ' is not available in drawings: they have no network, files or timers'); };
  }
  var BLOCKED = ['require', 'importScripts', 'fetch', 'WebSocket', 'XMLHttpRequest', 'WebTransport', 'EventSource',
    'setInterval', 'setTimeout', 'setImmediate', 'SharedWorker', 'Worker', 'WebAssembly', 'process', 'location',
    'navigator', '__engine', '__host'];

  function makeScope() {
    var scope = Object.create(api);
    for (var i = 0; i < BLOCKED.length; i++) {
      var name = BLOCKED[i];
      var value = name === '__host' || name === '__engine' || name === 'navigator' || name === 'location' || name === 'process' ? undefined : refuse(name);
      Object.defineProperty(scope, name, { value: value, writable: false, enumerable: false, configurable: false });
    }
    Object.defineProperty(scope, '__lp', { value: loopGuard, writable: false, enumerable: false, configurable: false });
    return scope;
  }

  function newCard() {
    card = {
      marks: [], byId: {}, parts: [], partsById: {}, partCount: 0, markCount: 0, history: [], ids: {},
      warnings: {}, warningCount: 0, requests: {}
    };
    currentScope = makeScope();
  }

  function cleanGlobals() {
    if (!baselineGlobals) return;
    var names = Object.getOwnPropertyNames(global);
    for (var i = 0; i < names.length; i++) {
      if (own(baselineGlobals, names[i])) continue;
      try { delete global[names[i]]; } catch (e) { /* not configurable */ }
    }
  }

  var pendingMarks = [];
  var pendingSounds = [];
  function flushMarks() {
    if (pendingMarks.length) { events.push({ type: 'marks', marks: pendingMarks }); pendingMarks = []; }
  }
  function emit(ev) { flushMarks(); events.push(ev); }

  function warn(message) {
    message = String(message);
    if (!card) return;
    if (card.warnings[message] || card.warningCount >= MAX_WARNINGS) return;
    card.warnings[message] = true;
    card.warningCount++;
    emit({ type: 'warning', message: message });
  }
  function reportError(e, statement) {
    var message = e && e.message ? String(e.message) : String(e);
    if (e && e.name && e.name !== 'Error' && message.indexOf(e.name) !== 0) message = e.name + ': ' + message;
    var text = statement == null ? null : String(statement).trim();
    if (text && text.length > 240) text = text.slice(0, 237) + '…';
    emit({ type: 'error', message: message, statement: text });
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Canvas facts

  function W() { return prog ? prog.canvas.width : 1280; }
  function H() { return prog ? prog.canvas.height : 832; }
  function scale() { return prog ? prog.canvas.scale : 1; }
  function pt(v) { return v / scale(); }          // points to canvas units
  function ink() { return prog ? prog.ink : DEFAULT_INK; }

  function textWidth(text, size, style) {
    var f = hostFn('textWidth');
    var s = String(text);
    if (f) { var w = +f(s, size, style || 'ui'); if (isFinite(w) && w >= 0) return w; }
    var k = style === 'mono' ? 0.6 : style === 'hand' || style === 'title' ? 0.48 : 0.52;
    return s.length * size * k;
  }
  // Mean luminance (0…1) of the screen under a canvas rectangle, or -1 when the host can't tell.
  function screenLum(x, y, w, h) {
    var f = hostFn('lum');
    if (!f) return -1;
    var v = +f(x, y, w, h);
    return isFinite(v) ? v : -1;
  }

  // How busy (0…1: text, controls) the screen is under a canvas rectangle, or -1 when the host can't tell.
  function screenBusy(x, y, w, h) {
    var f = hostFn('busy');
    if (!f) return -1;
    var v = +f(x, y, w, h);
    return isFinite(v) ? v : -1;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Tones and readable ink

  function toneHex(t, fallback) {
    var base = fallback || ink();
    if (t == null || t === '' || t === 'ink') return base;
    if (typeof t !== 'string') { warn('colours are names like "red" or hex like "#3380FF"'); return base; }
    var k = t.trim().toLowerCase().replace(/[\s_-]/g, '');
    if (own(TONES, k)) return TONES[k];
    if (own(TONE_ALIASES, k)) return TONES[TONE_ALIASES[k]];
    var p = parseHex(t);
    if (p) return toHex(p);
    warn('unknown colour "' + t + '"; used the ink instead');
    return base;
  }

  // What is under a rectangle: the topmost card or solid fill drawn earlier, else the screen's brightness.
  function groundUnder(box) {
    var cx = box.x + box.w / 2, cy = box.y + box.h / 2;
    for (var i = card.marks.length - 1; i >= 0; i--) {
      var m = card.marks[i];
      if (m.__erased || !m.__box || !m.__ground) continue;
      var b = boxOf(m);
      if (cx >= b.x && cx <= b.x + b.w && cy >= b.y && cy <= b.y + b.h) {
        return { lum: luminance(parseHex(m.__ground)), color: m.__ground, card: m.do === 'paper' ? m : null, fill: m };
      }
    }
    var pad = 8;
    var lum = screenLum(box.x - pad, box.y - pad, box.w + 2 * pad, box.h + 2 * pad);
    return lum >= 0 ? { lum: lum, color: null, card: null } : null;
  }

  // Make a colour readable on a ground: coloured ink keeps its hue and gets darker or lighter, grey ink flips to
  // near-black or white.
  function readable(hexColor, ground, words) {
    if (!ground) return hexColor;
    var rgb = parseHex(hexColor);
    if (!rgb) return hexColor;
    // Words need more contrast on dark grounds, where thin light strokes blur into the background.
    var need = words ? (ground.lum > 0.4 ? 4.0 : 5.5) : 2.6;
    var L = luminance(rgb);
    if (contrast(L, ground.lum) >= need) return hexColor;
    var lightGround = ground.lum > 0.4;
    var hsl = toHSL(rgb);
    if (hsl[1] > 0.25) {
      for (var step = 1; step <= 16; step++) {
        var l = lightGround ? hsl[2] * (1 - 0.06 * step) : hsl[2] + (1 - hsl[2]) * 0.07 * step;
        var c = fromHSL([hsl[0], hsl[1], clamp(l, 0, 1)]);
        if (contrast(luminance(c), ground.lum) >= need) return toHex(c);
      }
    }
    return lightGround ? '#1B1D22' : '#FFFFFF';
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Geometry

  function rectOf(x, y, w, h) {
    if (w < 0) { x += w; w = -w; }
    if (h < 0) { y += h; h = -h; }
    return { x: x, y: y, w: w, h: h };
  }
  function boundsOf(pts) {
    var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (var i = 0; i < pts.length; i++) {
      var p = pts[i];
      if (p[0] < x0) x0 = p[0]; if (p[0] > x1) x1 = p[0];
      if (p[1] < y0) y0 = p[1]; if (p[1] > y1) y1 = p[1];
    }
    return pts.length ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : { x: 0, y: 0, w: 0, h: 0 };
  }
  function polyLength(pts, closed) {
    var len = 0;
    for (var i = 1; i < pts.length; i++) len += M.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
    if (closed && pts.length > 2) len += M.hypot(pts[0][0] - pts[pts.length - 1][0], pts[0][1] - pts[pts.length - 1][1]);
    return len;
  }
  function overlapArea(a, b) {
    var w = M.min(a.x + a.w, b.x + b.w) - M.max(a.x, b.x);
    var h = M.min(a.y + a.h, b.y + b.h) - M.max(a.y, b.y);
    return w > 0 && h > 0 ? w * h : 0;
  }
  function contains(outer, inner, slack) {
    slack = slack || 0;
    return inner.x >= outer.x - slack && inner.y >= outer.y - slack &&
      inner.x + inner.w <= outer.x + outer.w + slack && inner.y + inner.h <= outer.y + outer.h + slack;
  }
  function toPoints(list) {
    var out = [];
    if (!Array.isArray(list)) return out;
    if (list.length > MAX_POINTS) warn('a line takes at most ' + MAX_POINTS + ' points; the rest were left out');
    for (var i = 0; i < list.length && out.length < MAX_POINTS; i++) {
      var p = list[i];
      if (Array.isArray(p) && isNum(p[0]) && isNum(p[1])) out.push([p[0], p[1]]);
      else if (isObj(p) && isNum(p.x) && isNum(p.y)) out.push([p.x, p.y]);
    }
    return out;
  }

  // A hand-drawn edge: each straight run bows a little to one side, the way a pen does.
  function handEdge(a, b, rand, amount) {
    var dx = b[0] - a[0], dy = b[1] - a[1], len = M.hypot(dx, dy);
    if (len < 1e-6) return [a, b];
    var bow = M.min(pt(5), len * 0.025) * amount * (rand() < 0.5 ? -1 : 1) * (0.6 + 0.4 * rand());
    var nx = -dy / len, ny = dx / len;
    var steps = M.max(2, M.min(10, M.round(len / pt(40))));
    var out = [];
    for (var i = 0; i <= steps; i++) {
      var t = i / steps, s = M.sin(M.PI * t) * bow;
      out.push([a[0] + dx * t + nx * s, a[1] + dy * t + ny * s]);
    }
    return out;
  }
  function handPolyline(pts, rand, amount, closed) {
    if (amount <= 0 || pts.length < 2) return pts.slice();
    var out = [], count = closed ? pts.length : pts.length - 1;
    for (var i = 0; i < count; i++) {
      var seg = handEdge(pts[i], pts[(i + 1) % pts.length], rand, amount);
      if (i > 0) seg.shift();
      out = out.concat(seg);
    }
    return out;
  }
  // A loop around an ellipse that overshoots its start a little, like a quick pen circle.
  function handEllipse(cx, cy, rx, ry, rand, amount) {
    var n = M.max(28, M.min(72, M.round((rx + ry) * scale() / 6)));
    var start = rand() * M.PI * 2, turns = amount > 0 ? 1.06 : 1, out = [];
    var w1 = 0.018 * amount, w2 = 0.012 * amount, ph = rand() * 6;
    for (var i = 0; i <= n; i++) {
      var t = i / n, a = start + t * turns * M.PI * 2;
      var k = 1 + w1 * M.sin(2 * a + ph) + w2 * M.sin(3 * a) + 0.02 * amount * t;
      out.push([cx + M.cos(a) * rx * k, cy + M.sin(a) * ry * k]);
    }
    return out;
  }
  function roundedRectPoints(x, y, w, h, r) {
    r = M.max(0, M.min(r, w / 2, h / 2));
    if (r <= 0.5) return [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
    var pts = [], corners = [[x + w - r, y + r, -90], [x + w - r, y + h - r, 0], [x + r, y + h - r, 90], [x + r, y + r, 180]];
    for (var c = 0; c < 4; c++) {
      for (var i = 0; i <= 6; i++) {
        var a = (corners[c][2] + i * 15) * M.PI / 180;
        pts.push([corners[c][0] + M.cos(a) * r, corners[c][1] + M.sin(a) * r]);
      }
    }
    return pts;
  }
  // A hand-drawn rounded rectangle, starting at the top-left: each corner shifts a little as a whole, each edge bows
  // once to one side, and the pen runs a short way past where it started.
  function handRoundedRect(r, radius, rand, amount) {
    radius = M.max(0, M.min(radius, r.w / 2, r.h / 2));
    var shift = amount * pt(1.5);
    var corners = [[r.x + radius, r.y + radius, 180], [r.x + r.w - radius, r.y + radius, 270],
      [r.x + r.w - radius, r.y + r.h - radius, 0], [r.x + radius, r.y + r.h - radius, 90]];
    var arcs = corners.map(function (c) {
      var ox = (rand() - 0.5) * 2 * shift, oy = (rand() - 0.5) * 2 * shift, n = radius > 0.5 ? 6 : 0, out = [];
      for (var i = 0; i <= n; i++) {
        var a = (c[2] + (n ? i * 90 / n : 45)) * M.PI / 180;
        out.push([c[0] + M.cos(a) * radius + ox, c[1] + M.sin(a) * radius + oy]);
      }
      return out;
    });
    var pts = [];
    for (var k = 0; k < 4; k++) {
      var arc = arcs[k], next = arcs[(k + 1) % 4];
      pts = pts.concat(arc);
      pts = pts.concat(handEdge(arc[arc.length - 1], next[0], rand, amount).slice(1, -1));
    }
    // Close the loop, then run on along the top edge.
    var first = arcs[0], drift = amount * pt(1.2);
    for (var j = 0; j < first.length; j++) pts.push([first[j][0], first[j][1] - drift * j / M.max(1, first.length - 1)]);
    var top = first[first.length - 1], over = M.min(r.w * 0.08, pt(14));
    pts.push([top[0] + over, top[1] - drift]);
    return pts;
  }
  function arrowHead(pts, size, angle) {
    var tip = pts[pts.length - 1], back = pts[M.max(0, pts.length - 2)];
    for (var i = pts.length - 2; i >= 0; i--) {
      back = pts[i];
      if (M.hypot(tip[0] - back[0], tip[1] - back[1]) >= size * 0.6) break;
    }
    var a = M.atan2(tip[1] - back[1], tip[0] - back[0]);
    return [
      [tip[0] - size * M.cos(a - angle), tip[1] - size * M.sin(a - angle)],
      [tip[0], tip[1]],
      [tip[0] - size * M.cos(a + angle), tip[1] - size * M.sin(a + angle)]
    ];
  }
  function bendPoints(a, b, bend) {
    var dx = b[0] - a[0], dy = b[1] - a[1], len = M.hypot(dx, dy);
    if (!bend || len < 1e-6) return [a, b];
    var k = bend === true ? 0.15 : bend;
    if (M.abs(k) > 1) k = k / len;
    if (M.abs(k) > 0.6) { warn('bend is at most 0.6 of the arrow length'); k = k < 0 ? -0.6 : 0.6; }
    var nx = -dy / len, ny = dx / len;
    return [a, [a[0] + dx / 2 + nx * k * len, a[1] + dy / 2 + ny * k * len], b];
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Text layout (wrapping and blocks), measured through the host

  function wrapLines(text, size, style, maxWidth) {
    var paragraphs = String(text).split('\n'), lines = [];
    for (var p = 0; p < paragraphs.length; p++) {
      var words = paragraphs[p].split(/\s+/).filter(function (w) { return w.length; });
      if (!maxWidth || !words.length) { lines.push(paragraphs[p].trim()); continue; }
      var line = '';
      for (var i = 0; i < words.length; i++) {
        var candidate = line ? line + ' ' + words[i] : words[i];
        if (line && textWidth(candidate, size, style) > maxWidth) { lines.push(line); line = words[i]; }
        else line = candidate;
      }
      lines.push(line);
    }
    if (lines.length > MAX_LINES) { warn('words wrapped past ' + MAX_LINES + ' lines; the rest were left out'); lines.length = MAX_LINES; }
    return lines;
  }
  function textBlock(text, size, style, o) {
    var lh = num(o.lineHeight, 1.25) * size;
    var lines = wrapLines(text, size, style, isNum(o.wrap) ? o.wrap : isNum(o.width) ? o.width : 0);
    if (isNum(o.fit) || Array.isArray(o.fit)) {
      var fw = Array.isArray(o.fit) ? o.fit[0] : o.fit, fh = Array.isArray(o.fit) ? o.fit[1] : Infinity;
      var original = size;
      for (var guardN = 0; guardN < 30; guardN++) {
        lines = wrapLines(text, size, style, fw);
        lh = num(o.lineHeight, 1.25) * size;
        var widest = 0;
        for (var i = 0; i < lines.length; i++) widest = M.max(widest, textWidth(lines[i], size, style));
        if ((widest <= fw && lines.length * lh <= fh) || size <= 11) break;
        size *= 0.92;
      }
      if (size < original * 0.7) warn('shrank the words "' + String(text).slice(0, 24) + '" to fit');
    }
    var w = 0;
    for (var j = 0; j < lines.length; j++) w = M.max(w, textWidth(lines[j], size, style));
    return { lines: lines, size: size, lh: lh, w: w, h: lines.length * lh };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Layout: labelled containers don't pile up, loose words don't land on each other

  function liveBoxes(kind, exceptPart) {
    var out = [];
    for (var i = 0; i < card.marks.length; i++) {
      var m = card.marks[i];
      if (m.__erased || !m.__box || m.__layout !== kind) continue;
      if (exceptPart && m.part === exceptPart) continue;
      out.push(m);
    }
    return out;
  }
  function clashes(r, other) {
    var b = boxOf(other), inter = overlapArea(r, b);
    if (inter <= 0) return false;
    var small = M.min(r.w * r.h, b.w * b.h) || 1;
    if (contains(b, r, 2) || contains(r, b, 2)) return false;   // intended nesting
    return inter > 0.08 * small && inter < 0.92 * small;
  }
  function freeSpot(r, avoid, test) {
    var margin = 6, best = null;
    var maxR = 0.3 * M.min(W(), H()), stepR = M.max(8, M.min(r.w, r.h) * 0.15);
    var candidates = [];
    for (var radius = stepR; radius <= maxR; radius += stepR) {
      for (var k = 0; k < 16; k++) {
        var a = k * M.PI / 8;
        candidates.push([M.cos(a) * radius, M.sin(a) * radius]);
      }
    }
    for (var i = 0; i < avoid.length; i++) {
      var b = boxOf(avoid[i]), gap = 10;
      candidates.push([b.x + b.w + gap - r.x, 0], [b.x - gap - r.w - r.x, 0], [0, b.y + b.h + gap - r.y], [0, b.y - gap - r.h - r.y]);
    }
    candidates.sort(function (p, q) { return (p[0] * p[0] + 1.3 * p[1] * p[1]) - (q[0] * q[0] + 1.3 * q[1] * q[1]); });
    for (var c = 0; c < candidates.length; c++) {
      var cand = { x: r.x + candidates[c][0], y: r.y + candidates[c][1], w: r.w, h: r.h };
      if (cand.x < margin || cand.y < margin || cand.x + cand.w > W() - margin || cand.y + cand.h > H() - margin) continue;
      if (test(cand)) { best = cand; break; }
    }
    return best;
  }
  // Where a labelled container should go: where the program asked, unless that half-covers another labelled one.
  function placeContainer(r, label, o) {
    if (o && o.place === false) return r;
    var others = liveBoxes('container');
    var hit = null;
    for (var i = 0; i < others.length; i++) if (clashes(r, others[i])) { hit = others[i]; break; }
    if (!hit) return r;
    var spot = freeSpot(r, others, function (cand) {
      for (var j = 0; j < others.length; j++) {
        var b = boxOf(others[j]);
        if (clashes(cand, others[j])) return false;
        if (!contains(b, cand, 2) && overlapArea(cand, b) > 0.05 * cand.w * cand.h) return false;
      }
      return true;
    });
    var name = label ? '"' + String(label).slice(0, 24) + '"' : 'a box';
    var otherName = hit.__label ? '"' + hit.__label + '"' : hit.part;
    if (!spot) { warn('the box ' + name + ' overlaps ' + otherName + ' and there was no free spot nearby'); return r; }
    warn('moved the box ' + name + ' by ' + M.round(spot.x - r.x) + ',' + M.round(spot.y - r.y) + ' so it no longer covers ' + otherName);
    return spot;
  }
  // Loose words step off earlier words, pills and labels and off the strokes already drawn, and stay on their card.
  function placeWords(r, o, onCard) {
    if (o && o.place === false) return r;
    return cleanSpot(r, { inside: onCard ? cardInnerOf(onCard.id, r) : null });
  }
  function keepOnCanvas(r) {
    var x = clamp(r.x, 2, M.max(2, W() - r.w - 2)), y = clamp(r.y, 2, M.max(2, H() - r.h - 2));
    return { x: x, y: y, w: r.w, h: r.h };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Layout on cards and around strokes
  //
  // Words keep off the lines and arrows already drawn and stay inside the card they were written on; a card grows to
  // hold what is drawn on it; a later stroke that would cross loose words moves them aside first.

  function inflate(r, d) { return { x: r.x - d, y: r.y - d, w: r.w + 2 * d, h: r.h + 2 * d }; }
  function rectsTouch(a, b) { return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h; }
  // Does the segment a-b pass through rectangle r? (Liang-Barsky clipping.)
  function segmentHits(a, b, r) {
    var t0 = 0, t1 = 1, dx = b[0] - a[0], dy = b[1] - a[1];
    var p = [-dx, dx, -dy, dy], q = [a[0] - r.x, r.x + r.w - a[0], a[1] - r.y, r.y + r.h - a[1]];
    for (var i = 0; i < 4; i++) {
      if (p[i] === 0) { if (q[i] < 0) return false; continue; }
      var t = q[i] / p[i];
      if (p[i] < 0) { if (t > t1) return false; if (t > t0) t0 = t; }
      else { if (t < t0) return false; if (t < t1) t1 = t; }
    }
    return t0 <= t1;
  }
  function polylineHits(pts, r, closed) {
    if (!pts || pts.length < 2) return false;
    for (var i = 1; i < pts.length; i++) if (segmentHits(pts[i - 1], pts[i], r)) return true;
    return !!closed && pts.length > 2 && segmentHits(pts[pts.length - 1], pts[0], r);
  }
  function applyXf(pts, xf) {
    if (!xf) return pts;
    return pts.map(function (p) { return [p[0] * xf[0] + xf[1], p[1] * xf[0] + xf[2]]; });
  }
  // The pen paths of a mark, in canvas units, as {pts, closed, box}: what a word placed there would collide with.
  // Cached per mark until the mark moves.
  function strokePaths(m) {
    var key = m.xf ? m.xf.join(',') : '';
    if (m.__paths && m.__pathsKey === key) return m.__paths;
    var raw = [], xf = m.xf;
    if (m.segs) for (var s = 0; s < m.segs.length; s++) raw.push([m.segs[s], false]);
    else if (m.pts && (m.do === 'line' || m.do === 'arrow')) raw.push([m.pts, false]);
    else if (m.pts && m.outline !== false && (m.do === 'box' || m.do === 'circle')) raw.push([m.pts, true]);
    if (m.head) raw.push([m.head, false]);
    if (m.tail) raw.push([m.tail, false]);
    if (m.do === 'region' && m.__box) {
      var rb = m.__box;
      raw.push([[[rb.x, rb.y], [rb.x + rb.w, rb.y], [rb.x + rb.w, rb.y + rb.h], [rb.x, rb.y + rb.h]], true]);
    }
    var out = [];
    for (var i = 0; i < raw.length; i++) {
      var pts = applyXf(raw[i][0], xf);
      if (pts.length >= 2) out.push({ pts: pts, closed: raw[i][1], box: boundsOf(pts) });
    }
    m.__paths = out;
    m.__pathsKey = key;
    return out;
  }
  function crossesStroke(r, m) {
    var paths = strokePaths(m);
    for (var i = 0; i < paths.length; i++) {
      var p = paths[i];
      if (!rectsTouch(inflate(p.box, 0.5), r)) continue;
      if (polylineHits(p.pts, r, p.closed)) return true;
    }
    return false;
  }
  var WORDLIKE = { words: 1, label: 1, pill: 1 };
  // The marks near a search area that could clash with words placed in it.
  function obstaclesNear(area, except) {
    var out = [];
    for (var i = 0; i < card.marks.length; i++) {
      var m = card.marks[i];
      if (m.__erased || m.do === 'edit' || !m.__box || (except && except.indexOf(m) >= 0)) continue;
      if (!rectsTouch(inflate(boxOf(m), 4), area)) continue;
      out.push(m);
    }
    return out;
  }
  // How badly words at `r` would clash: overlapping words, pills or labels count most, then strokes crossing them,
  // dots under them, leaving their card, and leaving the canvas. 0 means a clean spot.
  function clashScore(r, obstacles, o) {
    o = o || {};
    var score = 0, area = M.max(1, r.w * r.h), probe = inflate(r, num(o.pad, pt(2)));
    if (r.x < 2 || r.y < 2 || r.x + r.w > W() - 2 || r.y + r.h > H() - 2) score += 10;
    if (o.inside && !contains(o.inside, r, 1)) score += 5;
    for (var i = 0; i < obstacles.length; i++) {
      var m = obstacles[i], b = boxOf(m);
      if (!rectsTouch(inflate(b, 3), probe)) continue;
      if (WORDLIKE[m.__layout]) {
        var inter = overlapArea(probe, b);
        if (inter > 0) score += 2 + 3 * inter / M.min(area, M.max(1, b.w * b.h));
      } else if (m.do === 'dot') {
        if (overlapArea(probe, b) > 0) score += 0.6;
      } else if (crossesStroke(probe, m)) score += 1.5;
    }
    if (o.extra) for (var k = 0; k < o.extra.length; k++) if (polylineHits(o.extra[k], probe, false)) score += 1.5;
    return score;
  }

  // Paper cards. The writing area inside a card, from its outer box (docs/dsl.md, paper()).
  function paperInner(p) {
    var b = boxOf(p), k = p.xf ? p.xf[0] : 1, pad = num(p.pad, 18) * k, header = num(p.header, pt(28)) * k;
    return { x: b.x + pad, y: b.y + header + pad * 0.6, w: M.max(0, b.w - 2 * pad), h: M.max(0, b.h - header - pad * 1.6) };
  }
  // The topmost card under a point.
  function cardAt(x, y) {
    for (var i = card.marks.length - 1; i >= 0; i--) {
      var m = card.marks[i];
      if (m.do !== 'paper' || m.__erased || !m.__box) continue;
      var b = boxOf(m);
      if (x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h) return m;
    }
    return null;
  }
  // The card a mark sits on: its centre is on the card, or it hangs from it (its top edge starts on the card and it
  // is centred over it, like a row of words or a button written at the card's bottom), or most of it is on the card.
  // A mark bigger than the card isn't on it.
  function cardFor(box) {
    var cx = box.x + box.w / 2, cy = box.y + box.h / 2;
    for (var i = card.marks.length - 1; i >= 0; i--) {
      var m = card.marks[i];
      if (m.do !== 'paper' || m.__erased || !m.__box) continue;
      var b = boxOf(m);
      if (box.w * box.h > b.w * b.h) continue;
      var overX = cx >= b.x && cx <= b.x + b.w;
      if (overX && cy >= b.y && cy <= b.y + b.h) return m;
      if (overX && box.y >= b.y && box.y <= b.y + b.h + 1) return m;
      // (A line has no area: only its centre or top edge can put it on a card.)
      if (box.w * box.h > 1 && overlapArea(box, b) >= 0.4 * box.w * box.h) return m;
    }
    return null;
  }
  // Grow a card so `box` (something drawn on it) fits inside its writing area plus most of its padding: the bottom,
  // the right or the left edge moves out, never past the canvas, never the title bar. If the card is already on the
  // screen it glides to its new size just before the mark that needed the room is drawn.
  function fitCard(p, box) {
    // Only what reaches into the outer quarter of the padding (or past the edge) needs more room.
    var b = boxOf(p), pad = num(p.pad, 18), slack = pad * 0.25;
    var x0 = b.x, x1 = b.x + b.w, y1 = b.y + b.h;
    if (box.y + box.h > y1 - slack) y1 = M.min(H() - 2, box.y + box.h + pad * 0.8);
    if (box.x + box.w > x1 - slack) x1 = M.min(W() - 2, box.x + box.w + pad * 0.8);
    if (box.x < x0 + slack) x0 = M.max(2, box.x - pad * 0.8);
    if (x0 === b.x && x1 === b.x + b.w && y1 === b.y + b.h) return false;
    if (y1 < b.y + b.h) y1 = b.y + b.h;
    if (x1 < b.x + b.w) x1 = b.x + b.w;
    if (x0 > b.x) x0 = b.x;
    if (M.abs(x0 - b.x) < 0.5 && M.abs(x1 - b.x - b.w) < 0.5 && M.abs(y1 - b.y - b.h) < 0.5) return false;
    if (box.y + box.h > H() - 2 || box.x + box.w > W() - 2 || box.x < 2) warn('a card could not grow past the edge of the screen to hold everything drawn on it');
    // The card as painted so far, in its own (unmoved) coordinates, which the painter glides from.
    var from = [p.__box.x, p.__box.y, p.__box.w, p.__box.h];
    // Cards keep their own (unscaled) geometry; xf only moves and scales the whole card.
    var xf = p.xf || [1, 0, 0], k = xf[0] || 1;
    var nx = (x0 - xf[1]) / k, nw = (x1 - x0) / k, nh = (y1 - b.y) / k;
    p.at = [nx, p.at[1]]; p.w = nw; p.h = nh;
    p.__box = { x: nx, y: p.__box.y, w: nw, h: nh };
    p.__grown = true;
    if (p.__released && !p.__erased) editMark('grow', [p], 0.3, { __from: from });
    return true;
  }
  function fitOnCard(m) {
    if (!m.__box || m.do === 'paper' || m.do === 'edit' || m.__noCard || /^figure/.test(m.do) || /3d$/.test(m.do)) return;
    // Words know the card they were written on (from their anchor); strokes the card under them; else the card most
    // of the mark sits on.
    var id = m.__inside || m.on, named = id ? card.byId[id] : null;
    var box = boxOf(m), p = named && named.do === 'paper' && !named.__erased ? named : cardFor(box);
    if (p && p !== m) fitCard(p, box);
  }
  // Where words fit on a card from their anchor: the room to the card's inner edge, in the words' alignment.
  function roomOnCard(inner, x, align) {
    if (align === 'left') return inner.x + inner.w - x;
    if (align === 'right') return x - inner.x;
    return 2 * M.min(x - inner.x, inner.x + inner.w - x);
  }
  // A spot for words near `r` that clashes with nothing: rings of offsets around it, nearest first, vertical moves
  // a little preferred. Returns r itself when it is already clean, the cleanest spot found otherwise.
  // Searching for clean spots is the costly part of layout; a statement that has used most of its time limit (a loop
  // writing dozens of labels) keeps the spots it asked for rather than being stopped.
  function layoutTimeLeft() {
    return !guard.deadline || nowMs() < guard.deadline - guard.limitMs * 0.45;
  }
  function cleanSpot(r, o) {
    o = o || {};
    if (!layoutTimeLeft()) return r;
    var reach = num(o.reach, M.max(pt(120), r.h * 5));
    var obstacles = obstaclesNear(inflate(r, reach + 8), o.except);
    var base = clashScore(r, obstacles, o);
    if (base <= 0) return r;
    var best = r, bestScore = base, stepX = M.max(pt(8), r.w * 0.2), stepY = M.max(pt(6), r.h * 0.5);
    var cands = [];
    for (var ring = 1; ring <= 7; ring++) {
      for (var k = 0; k < 12; k++) {
        var a = k * M.PI / 6;
        var dx = M.round(M.cos(a) * 1000) / 1000 * stepX * ring, dy = M.round(M.sin(a) * 1000) / 1000 * stepY * ring;
        if (M.abs(dx) > reach || M.abs(dy) > reach) continue;
        cands.push([dx, dy]);
      }
    }
    cands.sort(function (p, q) { return (p[0] * p[0] + 1.6 * p[1] * p[1]) - (q[0] * q[0] + 1.6 * q[1] * q[1]); });
    for (var c = 0; c < cands.length; c++) {
      var cand = { x: r.x + cands[c][0], y: r.y + cands[c][1], w: r.w, h: r.h };
      var s = clashScore(cand, obstacles, o);
      if (s <= 0) return cand;
      if (s < bestScore - 0.25) { best = cand; bestScore = s; }
    }
    return best;
  }
  // A later stroke must not cross loose words already placed: they step aside first (gliding if already drawn).
  function dodgeWords(paths, own) {
    if (!paths.length || !layoutTimeLeft()) return;
    var b = boundsOf([].concat.apply([], paths));
    var near = obstaclesNear(inflate(b, pt(4)), own);
    for (var i = 0; i < near.length; i++) {
      var w = near[i];
      if (w.do !== 'text' || !w.__dodge) continue;
      var r = boxOf(w), probe = inflate(r, pt(1));
      var hit = false;
      for (var k = 0; k < paths.length && !hit; k++) if (polylineHits(paths[k], probe, false)) hit = true;
      if (!hit) continue;
      var inside = w.__inside ? cardInnerOf(w.__inside, r) : null;
      var spot = cleanSpot(r, { except: [w], extra: paths, inside: inside, reach: M.max(pt(90), r.h * 4) });
      if (spot === r || (spot.x === r.x && spot.y === r.y)) continue;
      var dx = spot.x - r.x, dy = spot.y - r.y, xf = w.xf || [1, 0, 0];
      if (w.__released) {
        card.history.push({ op: 'move', before: snapshot([w]) });
        w.xf = [xf[0], xf[1] + dx, xf[2] + dy];
        editMark('move', [w], 0.3);
      } else {
        w.xf = [xf[0], xf[1] + dx, xf[2] + dy];
        if (!w.xf[1] && !w.xf[2] && w.xf[0] === 1) delete w.xf;
      }
    }
  }
  // Move one mark by dx, dy: at once if it isn't drawn yet, else it glides there when this line reaches it.
  function nudge(m, dx, dy) {
    if (!m || m.__erased || (!dx && !dy)) return;
    var xf = m.xf || [1, 0, 0];
    if (m.__released) card.history.push({ op: 'move', before: snapshot([m]) });
    m.xf = [xf[0], xf[1] + dx, xf[2] + dy];
    if (m.__released) editMark('move', [m], 0.3);
  }
  // Take marks back: never drawn if they are still waiting, else erased when this line reaches them.
  function retract(marks) {
    var shown = [];
    for (var i = 0; i < marks.length; i++) {
      var m = marks[i];
      if (!m || m.__erased) continue;
      m.__erased = true;
      if (m.__released) shown.push(m);
    }
    if (shown.length) { card.history.push({ op: 'erase', targets: shown }); editMark('erase', shown, 0.25); }
  }

  // The area words on a card must stay in: its writing area widened to most of its padding.
  function cardInnerOf(cardId, r) {
    var p = card.byId[cardId];
    if (!p || p.__erased || p.do !== 'paper') return null;
    var b = boxOf(p), inner = paperInner(p), pad = num(p.pad, 18) * 0.6;
    var area = { x: inner.x - pad, y: inner.y - pad * 0.5, w: inner.w + 2 * pad, h: b.y + b.h - (inner.y - pad * 0.5) - pad * 0.4 };
    // Words that already reach past the bottom grow the card instead (fitCard), so the bottom is open here.
    if (r) area.h = M.max(area.h, r.y + r.h - area.y);
    return area;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Timing: how long each mark naturally takes to draw (`dur`) and how long until the next may start (`adv`)

  function penDuration(lengthUnits) {
    var lengthPoints = lengthUnits * scale();
    return clamp(0.22 + lengthPoints / 1500, 0.25, 1.2);
  }
  function natural(m) {
    if (isNum(m.__dur) && isNum(m.__adv)) return;
    var d = 0.3, a = 0.2, chars = String(m.text || (m.lines ? m.lines.join(' ') : '')).length;
    switch (m.do) {
      case 'line': d = m.dash ? M.min(0.9, 0.2 + polyLength(m.pts) * scale() / 1000) : penDuration(polyLength(m.pts)); a = d + 0.04; break;
      case 'arrow': d = penDuration(polyLength(m.pts)) + 0.14; a = d + 0.05; break;
      case 'box': case 'circle': d = m.pts ? penDuration(polyLength(m.pts, true)) : 0.35; a = d + 0.04; break;
      case 'dot': d = 0.22; a = 0.08; break;
      case 'text': d = m.reveal === 'write' ? clamp(0.25 + 0.045 * chars, 0.3, 2.6) : clamp(0.25 + 0.008 * chars, 0.25, 0.6); a = m.reveal === 'write' ? d * 0.9 : 0.22; break;
      case 'highlight': d = 0.35; a = 0.3; break;
      case 'region': d = 0.5; a = 0.4; break;
      case 'pill': case 'badge': d = 0.32; a = 0.18; break;
      case 'button': d = 0.3; a = 0.1; break;
      case 'paper': d = 0.45; a = 0.35; break;
      case 'graph': d = 0.5; a = 0.15; break;
      case 'figure': case 'stage3d': d = 0.35; a = 0.12; break;
      case 'part3d': d = 0.65; a = 0.12; break;
      case 'label3d': d = 0.4 + 0.015 * chars; a = 0.7 * (0.35 + 0.012 * chars); break;
      case 'edit': d = m.__est || 0.4; a = d; break;
      default:
        if (/3d$/.test(m.do) || /^figure/.test(m.do)) { d = 0; a = 0; }
    }
    if (m.together) a = 0;
    // Odd geometry (a zero-length or unmeasurable path) must not turn the line's timing into NaN: every later mark
    // of the line, and its timed edits, would never come due.
    if (!isNum(m.__dur)) m.__dur = isNum(d) ? d : 0.3;
    if (!isNum(m.__adv)) m.__adv = isNum(a) ? a : 0.2;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Marks

  function nextId(prefix) {
    prefix = String(prefix || 'm');
    var id;
    do { card.ids[prefix] = (card.ids[prefix] || 0) + 1; id = prefix + card.ids[prefix]; } while (card.byId[id]);
    return id;
  }
  function currentPart() {
    if (!prog.stmtPart) {
      card.partCount++;
      var part = { id: 'p' + card.partCount, name: null, step: prog.step, turn: prog.turn, line: prog.line, statement: prog.statement || '', marks: [] };
      card.parts.push(part);
      card.partsById[part.id] = part;
      prog.stmtPart = part;
    }
    return prog.stmtPart;
  }

  // Add a mark (also what plugins call through ctx.push). Returns the same object.
  function push(m) {
    if (!prog) throw new Error('no drawing has begun');
    if (!isObj(m) || typeof m.do !== 'string') throw new Error('a mark needs a "do" kind');
    checkDeadline();
    if (card.markCount >= MAX_MARKS) throw new Error('a card holds at most ' + MAX_MARKS + ' marks; this one is full');
    card.markCount++;
    // A plugin may push a 3D mark again under its id (or the same object again) to change it; any other mark whose
    // id is missing or taken gets a fresh one.
    var isFigure = /^figure/.test(m.do) || /3d$/.test(m.do);
    var previous = m.id ? card.byId[m.id] : null;
    if (previous && (previous === m || isFigure)) return repush(m, previous);
    if (!m.id || previous) m.id = freshId('m', card.markCount);
    var part = currentPart();
    if (isObj(m.__opts) && typeof m.__opts.name === 'string' && m.__opts.name) {
      part.name = m.__opts.name;
      m.name = m.__opts.name;
    }
    m.part = part.id;
    m.step = prog.step;
    if (prog.turn > 1) m.turn = prog.turn;
    m.__seq = card.marks.length;
    natural(m);
    card.marks.push(m);
    card.byId[m.id] = m;
    part.marks.push(m.id);
    if (m.__box) part.box = part.box ? union(part.box, m.__box) : { x: m.__box.x, y: m.__box.y, w: m.__box.w, h: m.__box.h };
    // A card grows to hold what is drawn on it (before this mark in the line, so the room is there when it lands).
    fitOnCard(m);
    enqueue(m);
    return m;
  }
  function repush(m, previous) {
    if (previous !== m) {
      m.part = previous.part;
      m.__seq = previous.__seq;
      card.marks[card.marks.indexOf(previous)] = m;
      card.byId[m.id] = m;
    }
    if (!isNum(m.step)) m.step = prog.step;
    delete m.__dur; delete m.__adv;
    natural(m);
    enqueue(m);
    return m;
  }
  function freshId(prefix, n) {
    var id = prefix + n, k = 1;
    while (card.byId[id]) id = prefix + n + '_' + (k++);
    return id;
  }
  function union(a, b) {
    var x = M.min(a.x, b.x), y = M.min(a.y, b.y);
    return { x: x, y: y, w: M.max(a.x + a.w, b.x + b.w) - x, h: M.max(a.y + a.h, b.y + b.h) - y };
  }

  // A handle the program gets back: the mark's geometry with handy edges and centre.
  function handle(m, box) {
    box = box || m.__box || { x: 0, y: 0, w: 0, h: 0 };
    return {
      id: m.id, part: m.part, x: box.x, y: box.y, w: box.w, h: box.h,
      cx: box.x + box.w / 2, cy: box.y + box.h / 2, left: box.x, right: box.x + box.w, top: box.y, bottom: box.y + box.h,
      center: [box.x + box.w / 2, box.y + box.h / 2]
    };
  }

  // Style shared by every stroked mark, and the readable-ink and glow rules for screen versus paper.
  function strokeStyle(m, o, box, words) {
    var ground = groundUnder(box);
    var onPaper = !!(ground && ground.card);
    var base = o.tone || o.color ? toneHex(o.tone || o.color) : onPaper ? PAPER_INK : ink();
    m.tone = o.contrast === false || o.role === 'key' ? base : readable(base, ground, words);
    if (onPaper) m.on = ground.card.id;
    if (!words) {
      var defaultSize = onPaper ? pt(2.6) : pt(3.5);
      m.size = isNum(o.size) ? o.size : isNum(o.width) ? o.width : defaultSize;
      if (o.glow !== false && !onPaper && o.glow !== 0) m.glow = Array.isArray(o.glow) ? o.glow : [0.6, 8];
      // On paper the pen is a felt tip: it swells from a fine start and tapers off (the screen pen stays even).
      if (onPaper && o.taper !== 0 && o.taper !== false) m.taper = isNum(o.taper) ? clamp(o.taper, 0, 1) : 1;
    }
    if (isNum(o.alpha)) m.alpha = clamp(o.alpha, 0, 1);
    return ground;
  }
  function dashOf(o, size) {
    if (!o.dash) return undefined;
    if (Array.isArray(o.dash)) return [num(o.dash[0], 8), num(o.dash[1], 6)];
    var on = isNum(o.dash) ? o.dash : M.max(pt(8), size * 2.6);
    return [on, isNum(o.gap) ? o.gap : on * 0.7];
  }
  function newMark(kind, o, seedText) {
    var m = { do: kind };
    m.__opts = o;
    m.__rand = seeded(hashString(kind + ':' + (card.markCount + 1) + ':' + (seedText || '')));
    return m;
  }
  function wobbleOf(o, fallback) { return isNum(o.wobble) ? clamp(o.wobble, 0, 3) : fallback; }

  // ---------------------------------------------------------------------------------------------------------------
  // Pacing against the voice
  //
  // Every mark is tied to one spoken line (a lane, numbered like SayLineExtractor). A mark made after a say() goes to
  // that line. A mark made before any say() of its step waits ("floating") and goes to whichever line the step speaks
  // first; if the step never speaks, it goes to the most recent line instead. In "speech" pace a lane is released
  // when the voice reports its line has begun, and its marks are laid out across the line's expected length.

  function laneFor(index) {
    var lanes = prog.lanes;
    if (!lanes[index]) lanes[index] = { index: index, started: false, base: 0, dur: null, finished: false, cursor: 0, queue: [], open: true, rush: false, estimated: true };
    return lanes[index];
  }
  function enqueue(m) {
    if (prog.rush) { m.line = prog.line; laneFor(prog.line >= 0 ? prog.line : -1).queue.push(m); return; }
    if (prog.pace === 'now') { m.line = prog.line; laneFor(-1).queue.push(m); return; }
    if (prog.stepHasSay && prog.line >= 0) { m.line = prog.line; laneFor(prog.line).queue.push(m); }
    else prog.floating.push(m);
  }
  function settleFloating(line) {
    if (!prog.floating.length) return;
    var lane = laneFor(line);
    for (var i = 0; i < prog.floating.length; i++) { prog.floating[i].line = line; lane.queue.push(prog.floating[i]); }
    prog.floating = [];
  }
  function estimateSeconds(text) {
    if (!text) return 2.5;
    var words = String(text).split(/\s+/).filter(function (w) { return w.length; }).length;
    return M.max(0.6, words / 2.6 + 0.3);
  }

  function schedule(lane, t) {
    var items = lane.queue.splice(0);
    if (!items.length) return;
    var rel = M.max(lane.cursor, t - lane.base);
    if (lane.cursor === 0 && rel < 0.08) rel = 0.08;
    var total = 0;
    for (var i = 0; i < items.length; i++) total += i < items.length - 1 ? items[i].__adv : items[i].__dur;
    var pace = 1, gap = 1;
    if (lane.rush || prog.rush) { pace = 0.35; gap = 0.3; }
    else if (lane.dur != null && total > 0) {
      var avail = lane.dur - 0.12 - rel;
      var f = avail / total;
      if (lane.open) f = M.min(f, 1);
      if (lane.finished || f < 0.8) { pace = clamp(f, 0.15, 1); gap = pace; }
      else { pace = M.min(f, 1.35); gap = M.min(f, 1.25); }
    }
    var cursor = rel;
    for (var j = 0; j < items.length; j++) {
      var m = items[j];
      m.start = cursor;
      m.duration = m.__dur * M.max(pace, 0.3);
      cursor += m.__adv * gap;
      release(m, lane.base);
    }
    lane.cursor = M.max(cursor, rel);
  }

  function pump() {
    if (!prog || prog.cancelled || prog.paused) return;
    var t = drawNow();
    if (prog.ended && !prog.finalized && prog.ready.length === 0 && prog.carry < 0 && prog.inputDone) finalize();
    var keys = Object.keys(prog.lanes).map(Number).sort(function (a, b) { return a - b; });
    for (var i = 0; i < keys.length; i++) {
      var lane = prog.lanes[keys[i]];
      if (!lane.queue.length) continue;
      if (prog.pace === 'now' || lane.index < 0) {
        if (!lane.started) { lane.started = true; lane.base = prog.origin; }
        schedule(lane, t);
      } else if (lane.started) schedule(lane, t);
      else if (prog.rush) { lane.started = true; lane.base = t; lane.rush = true; schedule(lane, t); }
    }
    flushTimed(t);
  }

  function finalize() {
    prog.finalized = true;
    if (prog.floating.length) {
      if (prog.line >= 0 && prog.pace !== 'now') settleFloating(prog.line);
      else {
        // A program that never speaks draws at once.
        var lane = laneFor(-1);
        for (var i = 0; i < prog.floating.length; i++) { prog.floating[i].line = -1; lane.queue.push(prog.floating[i]); }
        prog.floating = [];
      }
    }
    for (var k in prog.lanes) prog.lanes[k].open = false;
  }

  function flushTimed(t) {
    if (!prog.timed.length) return;
    var keep = [];
    for (var i = 0; i < prog.timed.length; i++) {
      var item = prog.timed[i];
      if (!isNum(item.at) || item.at <= t + 0.004) emit(item.event); else keep.push(item);
    }
    prog.timed = keep;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Releasing marks to the host

  function roundValue(v, limit) {
    if (typeof v === 'number') return isFinite(v) ? round(limit ? clamp(v, -limit, limit) : v, 2) : 0;
    if (Array.isArray(v)) return v.map(function (x) { return roundValue(x, limit); });
    if (isObj(v)) { var o = {}; for (var k in v) if (own(v, k)) o[k] = roundValue(v[k], limit); return o; }
    return v;
  }
  function clean(m) {
    var o = {};
    // 3D marks belong to their plugin and keep their numbers; 2D geometry is bounded.
    var limit = /^figure/.test(m.do) || /3d$/.test(m.do) ? 0 : MAX_COORD;
    for (var k in m) {
      if (!own(m, k) || (k.charCodeAt(0) === 95 && k.charCodeAt(1) === 95)) continue;
      var v = m[k];
      if (typeof v === 'function' || v === undefined) continue;
      if (k === 'start' || k === 'duration') o[k] = round(v, 3);
      else if (k === 'base') o[k] = round(v, 4);
      else o[k] = roundValue(v, limit);
    }
    return o;
  }
  // `edited` marks (moves, restyles, un-erases of earlier marks) don't announce a step.
  function emitMark(json, edited) {
    if (!edited && prog.lastStep !== json.step) {
      flushMarks();
      prog.lastStep = json.step;
      emit({ type: 'step', step: json.step });
    }
    pendingMarks.push(json);
  }
  function release(m, base) {
    m.base = base;
    m.__released = true;
    var startsAt = base + m.start;
    if (startsAt > prog.lastStart) prog.lastStart = startsAt;
    if (m.do === 'edit') { applyEdit(m, base); sound(m, base); return; }
    if (m.__erased) return;   // erased before it was ever drawn
    if (m.do === 'action') {
      // Invisible: the host acts when the line reaches it (types, copies, opens a page, hands off, plays a sound).
      var ev = { type: 'action', role: m.role, payload: m.payload, mark: m.id, line: m.line, at: m.at };
      prog.timed.push({ at: startsAt, event: ev });
      sound(m, base);
      return;
    }
    m.__shown = clean(m);
    emitMark(m.__shown);
    sound(m, base);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Sound recipes: what a mark sounds like as it is drawn. The host's player turns these into sound (the textures are
  // beds that last as long as the pen moves; events are short accents at an offset into the mark).

  var SFX = { tada: 1, ding: 1, nope: 1, stamp: 1, sparkle: 1, whoosh: 1, boing: 1, 'page-turn': 1 };
  function soundOf(m) {
    var texture = null, events = [], d = num(m.duration, 0.3);
    var onPaper = !!m.on;
    switch (m.do) {
      case 'line': case 'box': case 'circle': case 'region': texture = onPaper ? 'pencil' : 'felt'; break;
      case 'arrow': texture = onPaper ? 'pencil' : 'felt'; events.push({ id: 'pen-flick', at: M.max(0, d - 0.08) }); break;
      case 'text': texture = 'writing'; break;
      case 'pill': events.push({ id: 'gel-pop', at: 0 }); break;
      case 'badge': events.push({ id: 'badge-pop', at: 0 }); break;
      case 'button': events.push({ id: 'button-appear', at: 0 }); break;
      case 'paper': case 'sticky': case 'receipt': events.push({ id: 'paper', at: 0 }); if (m.do === 'sticky') events.push({ id: 'tape', at: 0.12 }); break;
      case 'highlight': events.push({ id: 'highlighter', at: 0 }); break;
      case 'dot': events.push({ id: 'tap', at: 0 }); break;
      case 'spotlight': events.push({ id: 'whoosh', at: 0 }); break;
      case 'action':
        if (m.role === 'type') events.push({ id: 'type-keys', at: 0 });
        else if (m.role === 'copy') events.push({ id: 'copy-tick', at: 0 });
        else if (m.role === 'sfx' && SFX[m.payload]) events.push({ id: m.payload, at: 0 });
        break;
      case 'edit':
        if (m.op === 'erase') texture = 'eraser';
        if (m.__startOver) events.push({ id: 'page-clear', at: 0 });
        else if (m.op === 'move' || m.op === 'scale' || m.op === 'grow') events.push({ id: 'slide', at: 0 });
        else if (m.op === 'highlight') events.push({ id: 'highlighter', at: 0 });
        break;
    }
    if (m.role === 'target' || m.role === 'hover') events.push({ id: 'target-ping', at: 0 });
    if (!texture && !events.length) return null;
    var out = { events: events, dur: round(d, 3) };
    if (texture) out.texture = texture;
    return out;
  }
  function sound(m, base) {
    if (prog.quiet) return;
    var recipe = soundOf(m);
    if (!recipe) return;
    recipe.type = 'sound';
    recipe.at = round(base + num(m.start, 0), 4);
    recipe.mark = m.id;
    // Kept apart and handed over after the marks of the same drain, so marks still arrive in whole batches.
    pendingSounds.push(recipe);
  }
  function remark(m, edit, start, duration, base, extra) {
    if (!m.__released || m.__erased) return;
    var json = clean(m);
    json.start = round(start, 3);
    json.duration = round(duration, 3);
    json.base = round(base, 4);
    json.edit = edit;
    if (extra) for (var k in extra) if (own(extra, k) && extra[k] !== undefined) json[k] = roundValue(extra[k], MAX_COORD);
    m.__shown = json;
    emitMark(json, true);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Host requests (docs/dsl-media.md): a plugin asks the host for data a mark needs (a photo, a place, a quote). The
  // request event goes out as soon as the statement runs, ahead of the mark's beat, so the lookup overlaps the voice;
  // the host answers later with patch(ref, fields).

  var PATCH_FIXED = { id: 1, do: 1, part: 1, step: 1, turn: 1, start: 1, duration: 1, base: 1, line: 1, edit: 1, ref: 1, name: 1 };
  function request(m, payload) {
    if (!prog || !card || !isObj(m) || !m.id || card.byId[m.id] !== m) throw new Error('request() needs a mark that was pushed');
    var ref = 'q' + (++requestSerial);
    m.ref = ref;
    card.requests[ref] = m;
    var ev = { type: 'request', ref: ref, mark: m.id };
    if (isObj(payload)) for (var k in payload) if (own(payload, k) && !own(ev, k) && k !== 'type') ev[k] = payload[k];
    emit(ev);
    return ref;
  }
  // Merge the host's answer into the mark and, if it is already on screen, send it again as a changed mark
  // (`edit: "patch"`): at its original moment if that is still ahead, else at once.
  function patch(ref, fields) {
    if (typeof fields === 'string') { try { fields = JSON.parse(fields); } catch (e) { fields = null; } }
    var m = card && card.requests[ref];
    if (!m || m.__erased || !isObj(fields)) return false;
    for (var k in fields) if (own(fields, k) && k.charCodeAt(0) !== 95 && !own(PATCH_FIXED, k)) m[k] = fields[k];
    for (var i = 0; i < patchHooks.length; i++) {
      try { patchHooks[i](m, fields); } catch (e) { log('patch hook failed: ' + e); }
    }
    if (m.__released && prog) {
      var t = drawNow(), due = num(m.base, t) + num(m.start, 0);
      if (due > t) remark(m, 'patch', m.start, m.duration, m.base);
      else remark(m, 'patch', 0, 0.35, t);
    }
    return true;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Edits: erase, move, moveTo, highlight, recolor, undo, clear
  //
  // An edit only reaches marks made before it, and it happens when its line is heard, like a stroke.

  function resolveTargets(spec, verb) {
    var out = [], seen = {};
    function addMark(m) { if (m && !m.__erased && !seen[m.id] && m.do !== 'edit') { seen[m.id] = true; out.push(m); } }
    function addOne(s) {
      if (s == null) return;
      if (Array.isArray(s)) { s.forEach(addOne); return; }
      if (isObj(s)) { addOne(s.part || s.id); return; }
      if (isNum(s)) { addOne('p' + s); return; }
      String(s).split(',').forEach(function (raw) {
        var key = raw.trim();
        if (!key) return;
        var range = /^m(\d+)\s*-\s*m?(\d+)$/.exec(key);
        if (range) {
          // Walk the marks that exist, not every number in the range ("m1-m99999" is a plausible "all of it").
          var lo = +range[1], hi = +range[2];
          for (var k = 0; k < card.marks.length; k++) {
            var idNumber = /^m(\d+)$/.exec(card.marks[k].id);
            if (idNumber && +idNumber[1] >= lo && +idNumber[1] <= hi) addMark(card.marks[k]);
          }
          return;
        }
        var part = card.partsById[key];
        var named = null;
        for (var i = 0; !part && i < card.parts.length; i++) if (card.parts[i].name === key) named = card.parts[i];
        part = part || named;
        if (part) { part.marks.forEach(function (id) { addMark(card.byId[id]); }); return; }
        if (card.byId[key]) { addMark(card.byId[key]); return; }
        warn(verb + '("' + key + '") found no part or mark with that id');
      });
    }
    addOne(spec);
    return out;
  }
  function editMark(op, targets, est, extra) {
    var m = { do: 'edit', op: op, __targets: targets, __est: est };
    for (var k in extra) m[k] = extra[k];
    // Edits never form parts of their own.
    checkDeadline();
    m.id = 'e' + (++card.markCount);
    m.step = prog.step;
    m.__seq = card.marks.length;
    natural(m);
    card.marks.push(m);
    enqueue(m);
    return m;
  }
  var STYLE_FIELDS = ['tone', 'fill', 'size', 'style', 'dash', 'lines', 'w', 'h', 'lh', 'at', 'glow'];
  function snapshot(targets) {
    return targets.map(function (m) {
      var s = { m: m, xf: m.xf ? m.xf.slice() : null, erased: !!m.__erased, fields: {}, box: m.__box ? Object.assign({}, m.__box) : null };
      for (var i = 0; i < STYLE_FIELDS.length; i++) {
        var k = STYLE_FIELDS[i];
        s.fields[k] = own(m, k) ? (Array.isArray(m[k]) ? m[k].slice() : m[k]) : undefined;
      }
      // Kept for older callers that read these directly.
      s.tone = m.tone; s.fill = m.fill;
      return s;
    });
  }
  function restoreSnapshot(s) {
    for (var k in s.fields) {
      if (!own(s.fields, k)) continue;
      if (s.fields[k] === undefined) delete s.m[k]; else s.m[k] = s.fields[k];
    }
    s.m.xf = s.xf;
    if (!s.m.xf) delete s.m.xf;
    if (s.box) s.m.__box = s.box;
    delete s.m.__paths;
  }
  function boxOfMarks(targets) {
    var b = null;
    for (var i = 0; i < targets.length; i++) if (targets[i].__box) b = b ? union(b, targets[i].__box) : targets[i].__box;
    return b;
  }
  function boxOf(m) { return transformedBox(m) || { x: 0, y: 0, w: 0, h: 0 }; }
  function transformedBox(m) {
    var b = m.__box;
    if (!b) return null;
    var xf = m.xf || [1, 0, 0];
    return { x: b.x * xf[0] + xf[1], y: b.y * xf[0] + xf[2], w: b.w * xf[0], h: b.h * xf[0] };
  }

  function applyEdit(e, base) {
    var at = base + e.start, targets = e.__targets || [];
    switch (e.op) {
      case 'erase': {
        var ids = targets.filter(function (m) { return m.__released; }).map(function (m) { return m.id; });
        if (ids.length) prog.timed.push({ at: at, event: { type: 'remove', ids: ids } });
        break;
      }
      case 'move': case 'recolor': case 'restore':
        for (var i = 0; i < targets.length; i++) remark(targets[i], e.op === 'recolor' ? 'restyle' : e.op === 'restore' ? e.__style || 'move' : 'move', e.start, e.duration, base);
        break;
      case 'grow':
        // A card on the screen takes its new size: the painter glides it from `from` ([x, y, w, h]).
        for (var g = 0; g < targets.length; g++) remark(targets[g], 'grow', e.start, e.duration, base, { from: e.__from });
        break;
      case 'unerase': {
        // The erase being undone may still be waiting for its moment in the line; it no longer applies to these.
        var back = {};
        for (var b = 0; b < targets.length; b++) back[targets[b].id] = true;
        prog.timed = prog.timed.filter(function (item) {
          if (item.event.type !== 'remove') return true;
          item.event.ids = item.event.ids.filter(function (id) { return !back[id]; });
          return item.event.ids.length > 0;
        });
        for (var j = 0; j < targets.length; j++) {
          var m = targets[j];
          if (!m.__released) continue;
          var json = clean(m);
          json.start = round(e.start + j * 0.05, 3); json.duration = round(M.max(0.2, (m.__dur || 0.3) * 0.6), 3); json.base = round(base, 4);
          m.__shown = json;
          emitMark(json, true);
        }
        break;
      }
    }
  }

  function doErase(spec, verb) {
    var targets = resolveTargets(spec, verb || 'erase');
    if (!targets.length) { if (spec != null) warn((verb || 'erase') + '(' + stringify(spec) + ') changed nothing'); return; }
    card.history.push({ op: 'erase', targets: targets });
    for (var i = 0; i < targets.length; i++) targets[i].__erased = true;
    var e = editMark('erase', targets, M.min(1.2, 0.3 + 0.04 * targets.length));
    // Until the erase's moment comes, the marks are still on screen (describe({drawnOnly}) lists them).
    for (var j = 0; j < targets.length; j++) targets[j].__erasedBy = e;
  }
  function doMove(spec, dx, dy, absolute, verb) {
    var targets = resolveTargets(spec, verb);
    if (!targets.length) return;
    var box = null;
    for (var i = 0; i < targets.length; i++) { var tb = transformedBox(targets[i]); if (tb) box = box ? union(box, tb) : tb; }
    if (absolute && box) { dx = dx - (box.x + box.w / 2); dy = dy - (box.y + box.h / 2); }
    if (box) {
      // Keep what moved on the canvas.
      var nx = clamp(box.x + dx, 0, M.max(0, W() - box.w)), ny = clamp(box.y + dy, 0, M.max(0, H() - box.h));
      if (nx !== box.x + dx || ny !== box.y + dy) warn(verb + ' kept the part on the canvas');
      dx = nx - box.x; dy = ny - box.y;
    }
    card.history.push({ op: 'move', before: snapshot(targets) });
    for (var j = 0; j < targets.length; j++) {
      var xf = targets[j].xf || [1, 0, 0];
      targets[j].xf = [xf[0], xf[1] + dx, xf[2] + dy];
    }
    editMark('move', targets, 0.5);
  }
  function doRecolor(spec, color) {
    var targets = resolveTargets(spec, 'recolor');
    if (!targets.length) return;
    var hex = toneHex(color);
    card.history.push({ op: 'recolor', before: snapshot(targets) });
    for (var i = 0; i < targets.length; i++) {
      var m = targets[i];
      if (m.fill && (m.do === 'box' || m.do === 'circle' || m.do === 'dot')) m.fill = hex; else m.tone = hex;
    }
    editMark('recolor', targets, 0.4);
  }
  function doHighlightPart(spec, color) {
    var targets = resolveTargets(spec, 'highlight');
    if (!targets.length) return null;
    var box = null;
    for (var i = 0; i < targets.length; i++) { var tb = transformedBox(targets[i]); if (tb) box = box ? union(box, tb) : tb; }
    if (!box) return null;
    var before = card.marks.length;
    var pad = pt(6);
    var h = drawHighlight(box.x - pad, box.y - pad / 2, box.w + 2 * pad, box.h + pad, { tone: color || 'yellow', place: false });
    card.history.push({ op: 'add', created: card.marks.slice(before) });
    return h;
  }
  function doUndo() {
    var entry = card.history.pop();
    if (!entry) { warn('undo() had nothing to undo'); return; }
    if (entry.op === 'erase') {
      for (var i = 0; i < entry.targets.length; i++) entry.targets[i].__erased = false;
      editMark('unerase', entry.targets, 0.4);
    } else if (entry.op === 'move' || entry.op === 'recolor' || entry.op === 'restyle' || entry.op === 'scale') {
      var targets = [];
      for (var j = 0; j < entry.before.length; j++) {
        restoreSnapshot(entry.before[j]);
        targets.push(entry.before[j].m);
      }
      editMark('restore', targets, 0.45, { __style: entry.op === 'move' || entry.op === 'scale' ? 'move' : 'restyle' });
    } else if (entry.op === 'add') {
      for (var k = 0; k < entry.created.length; k++) entry.created[k].__erased = true;
      editMark('erase', entry.created, 0.3);
    }
  }

  // restyle("p3", {size, style, dash, tone, glow}): words change face or size in place; strokes change width or dash.
  var STYLE_ALIASES = { handwriting: 'hand', handwritten: 'hand', rounded: 'hand', plain: 'ui', sans: 'sans', system: 'ui',
    bold: 'bold', heading: 'title', title: 'title', typewriter: 'mono', code: 'mono', mono: 'mono', hand: 'hand', ui: 'ui', clean: 'sans' };
  function doRestyle(spec, o) {
    if (!isObj(o)) { warn('restyle(id, {size, style, dash, tone}) needs the changes in braces'); return; }
    var targets = resolveTargets(spec, 'restyle');
    if (!targets.length) return;
    card.history.push({ op: 'restyle', before: snapshot(targets) });
    var changed = 0;
    for (var i = 0; i < targets.length; i++) {
      var m = targets[i];
      if (o.tone || o.color) { m.tone = toneHex(o.tone || o.color, m.tone); changed++; }
      if (m.do === 'text') {
        var style = o.style || o.font;
        var next = style != null ? STYLE_ALIASES[String(style).toLowerCase()] : null;
        if (style != null && !next) warn('restyle() knows the styles hand, title, ui, bold, mono and sans');
        var size = isNum(o.size) ? clamp(o.size, 11, 72) : m.size;
        if (next || size !== m.size) {
          var block = textBlock(m.text, size, next || m.style, { wrap: m.lines && m.lines.length > 1 ? m.w * size / m.size : 0 });
          var align = m.align || 'left', b = m.__box;
          var left = align === 'center' ? b.x + b.w / 2 - block.w / 2 : align === 'right' ? b.x + b.w - block.w : b.x;
          m.style = next || m.style; m.size = block.size; m.lines = block.lines; m.lh = block.lh;
          m.at = [left, b.y]; m.w = block.w; m.h = block.h;
          m.__box = { x: left, y: b.y, w: block.w, h: block.h };
          changed++;
        }
      } else {
        if (isNum(o.size) || isNum(o.width)) { m.size = clamp(isNum(o.size) ? o.size : o.width, 1, 14); changed++; }
        if (o.dash != null) { if (o.dash) m.dash = dashOf({ dash: o.dash }, m.size || pt(3)); else delete m.dash; changed++; }
        if (o.glow === false) { delete m.glow; changed++; }
      }
      delete m.__paths;
    }
    if (!changed) { card.history.pop(); warn('restyle(' + stringify(spec) + ') changed nothing'); return; }
    editMark('recolor', targets, 0.4);
  }
  // scale("p3", 1.5): grow or shrink a part about its centre, kept on the canvas.
  function doScale(spec, k) {
    if (!isNum(k) || k <= 0) { warn('scale(id, k) needs a positive number, like 1.5'); return; }
    var kk = clamp(k, 0.25, 4);
    if (kk !== k) warn('scale() takes 0.25 to 4');
    var targets = resolveTargets(spec, 'scale');
    if (!targets.length) return;
    var box = null;
    for (var i = 0; i < targets.length; i++) { var tb = transformedBox(targets[i]); if (tb) box = box ? union(box, tb) : tb; }
    if (!box) return;
    // Never larger than the canvas.
    kk = M.min(kk, (W() - 4) / M.max(1, box.w), (H() - 4) / M.max(1, box.h));
    var cx = box.x + box.w / 2, cy = box.y + box.h / 2;
    var nw = box.w * kk, nh = box.h * kk;
    var ncx = clamp(cx, nw / 2 + 2, W() - nw / 2 - 2), ncy = clamp(cy, nh / 2 + 2, H() - nh / 2 - 2);
    card.history.push({ op: 'scale', before: snapshot(targets) });
    for (var j = 0; j < targets.length; j++) {
      var xf = targets[j].xf || [1, 0, 0];
      // x' = kk * (x * k0 + tx - cx) + ncx
      targets[j].xf = [xf[0] * kk, kk * (xf[1] - cx) + ncx, kk * (xf[2] - cy) + ncy];
      delete targets[j].__paths;
    }
    editMark('move', targets, 0.5);
  }
  // startOver(): everything drawn so far is erased (briskly), and what follows is a fresh drawing.
  function doStartOver() {
    var targets = [];
    for (var i = 0; i < card.marks.length; i++) {
      var m = card.marks[i];
      if (!m.__erased && m.do !== 'edit' && m.do !== 'action') targets.push(m);
    }
    if (!targets.length) { warn('startOver() found nothing to clear'); return; }
    card.history.push({ op: 'erase', targets: targets });
    for (var j = 0; j < targets.length; j++) targets[j].__erased = true;
    editMark('erase', targets, M.min(0.8, 0.2 + 0.01 * targets.length), { __brisk: true });
    var e = card.marks[card.marks.length - 1];
    if (e && e.do === 'edit') e.__startOver = true;
  }

  // __turn(n, keep): a kept card's next turn begins. Marks of earlier turns from index `keep` on were never drawn
  // live (the voice was cut off), so a replay of the whole card drops them too.
  function doTurn(n, keep) {
    if (!isNum(n) || n < 2) return;
    var drop = [];
    if (isNum(keep)) {
      for (var i = 0; i < card.marks.length; i++) {
        var m = card.marks[i];
        if (m.__seq >= keep && (m.turn || 1) < n && !m.__erased && m.do !== 'edit') drop.push(m);
      }
    }
    if (drop.length) retract(drop);
    if (prog.floating.length && prog.line >= 0 && prog.pace !== 'now') settleFloating(prog.line);
    prog.turn = n;
    prog.step = 0;
    prog.stepHasSay = false;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Actions and notes (the host acts on them; they draw nothing)

  var MAX_ACTIONS = 12;
  function pushAction(role, payload, at, o) {
    if (prog.actions >= MAX_ACTIONS) { warn('a drawing takes at most ' + MAX_ACTIONS + ' actions; ' + role + ' was skipped'); return null; }
    prog.actions++;
    var m = newMark('action', isObj(o) ? o : {}, role);
    m.role = role;
    m.payload = payload;
    m.at = at || [0, 0];
    m.__dur = 0.05; m.__adv = 0; m.__noCard = true;
    push(m);
    return m;
  }
  // seen(), noted(), plan() and lessonTitle() draw nothing: the host reads them (what the user is doing, a fact
  // about the user, the picture Clicky means to draw, a lesson's name).
  function note(kind, text) {
    var words = text == null ? '' : String(text).replace(/\s+/g, ' ').trim().slice(0, 400);
    if (!words) { warn(kind + '() needs words'); return; }
    prog.notes.push({ kind: kind, text: words });
    if (kind === 'lesson') card.lessonTitle = words.slice(0, 120);
    if (kind === 'plan') return;
    emit({ type: 'note', kind: kind, text: words });
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Drawing primitives

  // A point given as [x, y] or as an object with numeric x and y (a handle's corner).
  function isPoint(v) { return (Array.isArray(v) && isNum(v[0]) && isNum(v[1])) || (isObj(v) && isNum(v.x) && isNum(v.y)); }
  // line([[x,y],…], o), line([x,y], [x,y], …, o) or line(x1, y1, x2, y2, …, o).
  function lineArgs(args) {
    var a = Array.prototype.slice.call(args);
    var o = a.length && isObj(a[a.length - 1]) && !isPoint(a[a.length - 1]) ? a.pop() : {};
    if (a.length === 1 && Array.isArray(a[0]) && !isNum(a[0][0])) return { pts: toPoints(a[0]), o: o };
    if (a.length >= 4 && a.every(isNum)) {
      var pairs = [];
      for (var i = 0; i + 1 < a.length; i += 2) pairs.push([a[i], a[i + 1]]);
      return { pts: pairs, o: o };
    }
    return { pts: toPoints(a), o: o };
  }

  function drawLine(pts, o, kind) {
    var given = pts.length;
    pts = toPoints(pts);
    if (pts.length < given) warn(kind + '() skipped points that were not numbers');
    if (pts.length < 2) { warn(kind + '() needs at least two points'); return null; }
    var m = newMark(kind, o);
    var smooth = o.smooth === true || kind === 'curve';
    var bend = o.bend && pts.length === 2 ? bendPoints(pts[0], pts[1], o.bend) : null;
    var base = bend || pts;
    var box = boundsOf(base);
    strokeStyle(m, o, box, false);
    var wob = wobbleOf(o, smooth || bend ? 0 : 0.6);
    m.do = kind === 'curve' ? 'line' : kind;
    m.pts = smooth || bend ? base : handPolyline(base, m.__rand, wob, false);
    if (smooth || bend || wob > 0) m.smooth = true;
    var dash = dashOf(o, m.size);
    if (dash) m.dash = dash;
    if (kind === 'arrow') {
      var headSize = num(o.head, M.max(pt(12), m.size * 3.2));
      var angle = num(o.headAngle, 0.5);
      m.head = arrowHead(m.pts, headSize, angle);
      if (o.both) m.tail = arrowHead(m.pts.slice().reverse(), headSize, angle);
    }
    m.__box = boundsOf(m.pts);
    m.__layout = 'stroke';
    // Loose words this stroke would cross step aside first.
    if (o.dodge !== false) {
      var paths = [m.pts];
      if (m.head) paths.push(m.head);
      if (m.tail) paths.push(m.tail);
      dodgeWords(paths, [m]);
    }
    var h = handle(push(m));
    h.start = pts[0]; h.end = pts[pts.length - 1];
    if (o.label != null && String(o.label) !== '') strokeLabel(m, o);
    return h;
  }

  // A point along a polyline at fraction t of its length, with the direction there.
  function alongPolyline(pts, t) {
    var total = polyLength(pts), goal = clamp(t, 0, 1) * total, run = 0;
    for (var i = 1; i < pts.length; i++) {
      var a = pts[i - 1], b = pts[i], d = M.hypot(b[0] - a[0], b[1] - a[1]);
      if (run + d >= goal && d > 0) {
        var u = (goal - run) / d;
        return { p: [a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u], dir: [(b[0] - a[0]) / d, (b[1] - a[1]) / d] };
      }
      run += d;
    }
    var last = pts[pts.length - 1], prev = pts[M.max(0, pts.length - 2)], dl = M.hypot(last[0] - prev[0], last[1] - prev[1]) || 1;
    return { p: last, dir: [(last[0] - prev[0]) / dl, (last[1] - prev[1]) / dl] };
  }

  // An arrow's or line's words go beside it, never on it: above a flat stroke, to one side of a steep one, wherever
  // they cross no other stroke and no other words, and inside the card the stroke is on.
  function strokeLabel(m, o) {
    var size = num(o.labelSize, 18), style = o.labelStyle || 'hand';
    var block = textBlock(String(o.label), size, style, { wrap: num(o.labelWrap, M.max(pt(120), polyLength(m.pts) * 0.9)) });
    var dx = num(o.labelDx, 0), dy = num(o.labelDy, 0);
    var onCard = m.on ? cardInnerOf(m.on) : null;
    var obstacles = obstaclesNear(inflate(boundsOf(m.pts), block.w + block.h + pt(60)), null);
    var gap = pt(7), best = null, bestScore = Infinity;
    var ts = layoutTimeLeft() ? [0.5, 0.42, 0.58, 0.34, 0.66, 0.26, 0.74] : [0.5];
    for (var i = 0; i < ts.length; i++) {
      var at = alongPolyline(m.pts, ts[i]);
      var n = [-at.dir[1], at.dir[0]];
      // Prefer above for flat strokes and the right for steep ones.
      if (M.abs(at.dir[0]) >= M.abs(at.dir[1]) ? n[1] > 0 : n[0] < 0) n = [-n[0], -n[1]];
      for (var side = 0; side < 2; side++) {
        var nn = side ? [-n[0], -n[1]] : n;
        var reach = M.abs(nn[0]) * block.w / 2 + M.abs(nn[1]) * block.h / 2 + gap;
        for (var tier = 0; tier < 2; tier++) {
          var d = reach + tier * pt(10);
          var cx = at.p[0] + nn[0] * d + dx, cy = at.p[1] + nn[1] * d + dy;
          var r = { x: cx - block.w / 2, y: cy - block.h / 2, w: block.w, h: block.h };
          var s = clashScore(r, obstacles, { inside: onCard }) + i * 0.05 + side * 0.12 + tier * 0.08;
          if (s < bestScore) { best = r; bestScore = s; }
        }
      }
      if (bestScore < 0.2) break;
    }
    var t = drawText(best.x + best.w / 2, best.y + best.h / 2, o.label, {
      size: size, style: style, align: 'center', valign: 'middle', wrap: block.lines.length > 1 ? block.w + 1 : undefined, place: false,
      reveal: 'write', tone: o.labelTone != null ? o.labelTone : o.tone || o.color, card: false
    }, 'label');
    var tm = t && card.byId[t.id];
    if (tm) { tm.__dodge = true; if (m.on) tm.__inside = m.on; }
    return t;
  }

  // SVG path data ("M 10 10 L 50 10 C …"), flattened to point lists: [{pts, closed}]. Absolute and relative
  // M L H V C S Q T A Z.
  function parsePath(d) {
    var toks = String(d).match(/[MmLlHhVvCcSsQqTtAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g) || [];
    var subs = [], cur = null, x = 0, y = 0, sx = 0, sy = 0, cmd = null, i = 0, lastC = null, lastQ = null, budget = MAX_POINTS;
    function n() { var v = parseFloat(toks[i++]); return isFinite(v) ? v : 0; }
    function more() { return i < toks.length && !/^[A-Za-z]$/.test(toks[i]); }
    function add(px, py) { if (budget-- > 0) cur.pts.push([px, py]); x = px; y = py; }
    function open() { cur = { pts: [[x, y]], closed: false }; subs.push(cur); }
    function cubic(x1, y1, x2, y2, ex, ey) {
      var x0 = x, y0 = y;
      for (var k = 1; k <= 16; k++) {
        var t = k / 16, u = 1 - t;
        add(u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * ex, u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * ey);
      }
      lastC = [x2, y2];
    }
    function quad(x1, y1, ex, ey) {
      var x0 = x, y0 = y;
      for (var k = 1; k <= 12; k++) { var t = k / 12, u = 1 - t; add(u * u * x0 + 2 * u * t * x1 + t * t * ex, u * u * y0 + 2 * u * t * y1 + t * t * ey); }
      lastQ = [x1, y1];
    }
    function arc(rx, ry, rot, large, sweep, ex, ey) {
      // Endpoint to centre parametrisation (SVG 1.1 implementation notes, F.6.5).
      var x0 = x, y0 = y;
      if (!rx || !ry) { add(ex, ey); return; }
      rx = M.abs(rx); ry = M.abs(ry);
      var phi = rot * M.PI / 180, c = M.cos(phi), sn = M.sin(phi);
      var dx = (x0 - ex) / 2, dy = (y0 - ey) / 2, x1 = c * dx + sn * dy, y1 = -sn * dx + c * dy;
      var l = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry);
      if (l > 1) { rx *= M.sqrt(l); ry *= M.sqrt(l); }
      var num2 = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1, den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
      var co = (large === sweep ? -1 : 1) * M.sqrt(M.max(0, num2 / (den || 1)));
      var cxp = co * rx * y1 / ry, cyp = -co * ry * x1 / rx;
      var cx = c * cxp - sn * cyp + (x0 + ex) / 2, cy = sn * cxp + c * cyp + (y0 + ey) / 2;
      var a1 = M.atan2((y1 - cyp) / ry, (x1 - cxp) / rx), a2 = M.atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx), da = a2 - a1;
      if (!sweep && da > 0) da -= 2 * M.PI; else if (sweep && da < 0) da += 2 * M.PI;
      var steps = M.max(6, M.ceil(M.abs(da) / (M.PI / 12)));
      for (var k = 1; k <= steps; k++) {
        var a = a1 + da * k / steps;
        add(cx + c * rx * M.cos(a) - sn * ry * M.sin(a), cy + sn * rx * M.cos(a) + c * ry * M.sin(a));
      }
    }
    var guardN = 0;
    while (i < toks.length && guardN++ < 20000) {
      if (/^[A-Za-z]$/.test(toks[i])) cmd = toks[i++];
      if (!cmd) { i++; continue; }
      var rel = cmd === cmd.toLowerCase(), C = cmd.toUpperCase(), ox = rel ? x : 0, oy = rel ? y : 0;
      if (C === 'Z') { if (cur) { cur.closed = true; x = sx; y = sy; } cmd = null; continue; }
      if (!more()) { cmd = null; continue; }
      if (C === 'M') { x = n() + ox; y = n() + oy; sx = x; sy = y; open(); cmd = rel ? 'l' : 'L'; lastC = lastQ = null; continue; }
      if (!cur) open();
      if (C === 'L') add(n() + ox, n() + oy);
      else if (C === 'H') add(n() + ox, y);
      else if (C === 'V') add(x, n() + oy);
      else if (C === 'C') { var a1x = n() + ox, a1y = n() + oy, a2x = n() + ox, a2y = n() + oy; cubic(a1x, a1y, a2x, a2y, n() + ox, n() + oy); continue; }
      else if (C === 'S') { var rx1 = lastC ? 2 * x - lastC[0] : x, ry1 = lastC ? 2 * y - lastC[1] : y, s2x = n() + ox, s2y = n() + oy; cubic(rx1, ry1, s2x, s2y, n() + ox, n() + oy); continue; }
      else if (C === 'Q') { var qx = n() + ox, qy = n() + oy; quad(qx, qy, n() + ox, n() + oy); continue; }
      else if (C === 'T') { var tx = lastQ ? 2 * x - lastQ[0] : x, ty = lastQ ? 2 * y - lastQ[1] : y; quad(tx, ty, n() + ox, n() + oy); continue; }
      else if (C === 'A') { var arx = n(), ary = n(), rot = n(), lg = n() ? 1 : 0, sw = n() ? 1 : 0; arc(arx, ary, rot, lg, sw, n() + ox, n() + oy); }
      lastC = lastQ = null;
    }
    return subs.filter(function (sp) { return sp.pts.length >= 2; });
  }
  function drawPath(d, o) {
    o = isObj(o) ? o : {};
    if (typeof d !== 'string' || !d.trim()) { warn('path() needs SVG path data like "M 10 10 L 100 40"'); return null; }
    var subs = parsePath(d);
    if (!subs.length) { warn('path() found no lines in "' + String(d).slice(0, 40) + '"'); return null; }
    var dx = num(o.x, 0), dy = num(o.y, 0), k = num(o.scale, 1);
    var segs = subs.map(function (sp) {
      var pts = sp.pts.map(function (p) { return [p[0] * k + dx, p[1] * k + dy]; });
      if (sp.closed) pts.push(pts[0].slice());
      return pts;
    });
    var all = [].concat.apply([], segs);
    var m = newMark('line', o, d);
    var box = boundsOf(all);
    strokeStyle(m, o, box, false);
    if (segs.length === 1) m.pts = segs[0]; else { m.pts = segs[0]; m.segs = segs; }
    if (o.fill && subs.length === 1 && subs[0].closed) {
      m.fill = toneHex(o.fill === true ? m.tone : o.fill);
      m.fillAlpha = clamp(num(o.fillAlpha, 0.25), 0, 1);
      m.closed = true;
    }
    if (o.outline === false) m.outline = false;
    var dash = dashOf(o, m.size);
    if (dash) m.dash = dash;
    m.__box = box;
    m.__layout = 'stroke';
    return handle(push(m));
  }
  // poly([[x, y], …], o): a closed outline through the points (open with close: false).
  function drawPoly(pts, o) {
    o = isObj(o) ? o : {};
    pts = toPoints(pts);
    if (pts.length < 2) { warn('poly() needs at least two points'); return null; }
    var closed = o.close !== false && pts.length > 2;
    var m = newMark('line', o, 'poly');
    var box = boundsOf(pts);
    strokeStyle(m, o, box, false);
    var wob = wobbleOf(o, o.smooth ? 0 : 0.7);
    var outline = o.smooth ? pts.slice() : handPolyline(pts, m.__rand, wob, closed);
    if (closed) outline.push(outline[0].slice());
    m.pts = outline;
    if (o.smooth || wob > 0) m.smooth = true;
    if (closed && o.fill) {
      m.fill = toneHex(o.fill === true ? m.tone : o.fill);
      m.fillAlpha = clamp(num(o.fillAlpha, o.outline === false ? 1 : 0.25), 0, 1);
      m.closed = true;
      if (m.fillAlpha >= 0.75) m.__ground = m.fill;
    }
    if (o.outline === false) m.outline = false;
    var dash = dashOf(o, m.size);
    if (dash) m.dash = dash;
    m.__box = box;
    m.__layout = o.label != null ? 'container' : 'shape';
    var hd = handle(push(m));
    if (o.label != null && closed) labelInside(box, o.label, o, m);
    return hd;
  }

  function closedShape(kind, box, outline, o, label) {
    var m = newMark(kind, o, label);
    strokeStyle(m, o, box, false);
    m.pts = outline;
    m.smooth = true;
    if (o.fill) {
      m.fill = toneHex(o.fill === true ? m.tone : o.fill);
      m.fillAlpha = clamp(num(o.fillAlpha, o.outline === false ? 1 : 0.25), 0, 1);
      if (m.fillAlpha >= 0.75) m.__ground = m.fill;
    }
    if (o.outline === false) m.outline = false;
    var dash = dashOf(o, m.size);
    if (dash) m.dash = dash;
    m.__box = box;
    m.__layout = label != null ? 'container' : 'shape';
    if (label != null) m.__label = String(label).slice(0, 24);
    return m;
  }

  function drawBox(x, y, w, h, o) {
    o = isObj(o) ? o : {};
    if (![x, y, w, h].every(isNum)) { warn('box() needs x, y, w, h numbers'); return null; }
    var r = rectOf(x, y, w, h);
    if (o.label != null) r = placeContainer(r, o.label, o);
    var radius = isNum(o.r) ? o.r : pt(8);
    var m = closedShape('box', r, null, o, o.label);
    m.pts = handRoundedRect(r, radius, m.__rand, wobbleOf(o, 0.7));
    m.at = [r.x, r.y]; m.w = r.w; m.h = r.h; m.r = radius;
    var hd = handle(push(m));
    if (o.label != null) labelInside(r, o.label, o, m);
    return hd;
  }
  function drawCircle(cx, cy, rx, ry, o) {
    o = isObj(o) ? o : {};
    if (![cx, cy, rx, ry].every(isNum)) { warn('circle() needs a centre and a radius'); return null; }
    rx = M.abs(rx); ry = M.abs(ry);
    var r = { x: cx - rx, y: cy - ry, w: 2 * rx, h: 2 * ry };
    if (o.label != null) { r = placeContainer(r, o.label, o); cx = r.x + rx; cy = r.y + ry; }
    var m = closedShape('circle', r, null, o, o.label);
    m.pts = handEllipse(cx, cy, rx, ry, m.__rand, wobbleOf(o, 1));
    m.at = [cx, cy]; m.rx = rx; m.ry = ry;
    var hd = handle(push(m));
    if (o.label != null) labelInside(r, o.label, o, m);
    return hd;
  }
  function labelInside(r, label, o, shape) {
    var size = num(o.labelSize, M.min(24, M.max(14, r.h * 0.28)));
    // Inside the shape: wrapped to it, and smaller if one word is wider than the shape.
    drawText(r.x + r.w / 2, r.y + r.h / 2, label, {
      size: size, style: o.labelStyle || 'hand', align: 'center', valign: 'middle', wrap: r.w * 0.86, fit: [r.w * 0.88, r.h * 0.9],
      place: false, tone: o.labelTone != null ? o.labelTone : o.tone || o.color, reveal: 'write'
    }, 'label');
    shape.__label = String(label).slice(0, 24);
  }

  function drawDot(x, y, o) {
    o = isObj(o) ? o : {};
    if (!isNum(x) || !isNum(y)) { warn('dot() needs x and y numbers'); return null; }
    var r = num(o.r, pt(5));
    var m = newMark('dot', o);
    var box = { x: x - r, y: y - r, w: 2 * r, h: 2 * r };
    strokeStyle(m, o, box, false);
    delete m.size;
    m.at = [x, y]; m.r = r;
    m.__box = box;
    m.__layout = 'dot';
    return handle(push(m));
  }

  // Words. `reveal: "write"` writes them letter by letter (handwriting); otherwise they fade in.
  function drawText(x, y, text, o, role) {
    o = isObj(o) ? o : {};
    if (text == null || String(text) === '') return null;
    if (!isNum(x) || !isNum(y)) { warn('text() needs x and y numbers'); return null; }
    text = String(text);
    if (text.length > MAX_TEXT) { warn('one text() holds at most ' + MAX_TEXT + ' characters; the rest were left out'); text = text.slice(0, MAX_TEXT); }
    // Links: "[label](https://…)" shows the label, a long bare address shows its site; the first link is kept so the
    // words can be clicked.
    var linked = linkedText(text);
    text = linked.text;
    var style = o.style || (o.reveal === 'write' ? 'hand' : 'ui');
    if (['hand', 'title', 'ui', 'bold', 'mono', 'sans'].indexOf(style) < 0) { warn('text style "' + style + '" is not one of hand, title, ui, bold, mono, sans'); style = 'ui'; }
    var size = num(o.size, style === 'hand' || style === 'title' ? 24 : 18);
    var minSize = 11;
    if (size < minSize) { warn('words are at least ' + minSize + ' units tall'); size = minSize; }
    if (size > MAX_TEXT_SIZE) { warn('words are at most ' + MAX_TEXT_SIZE + ' units tall'); size = MAX_TEXT_SIZE; }
    var align = o.align === 'center' || o.align === 'middle' ? 'center' : o.align === 'right' || o.align === 'end' ? 'right' : 'left';
    var valign = o.valign === 'middle' || o.valign === 'center' ? 'middle' : o.valign === 'bottom' ? 'bottom' : 'top';
    // Words written on a card wrap at its inner edge and shrink only when a single word is wider than the room.
    var onCard = o.card === false || role === 'label' ? null : cardAt(x, y);
    var layout = o;
    // Pieces (graph, timeline) place their own words on the card.
    if (onCard && role !== 'piece') {
      // The writing area plus half the padding: words hung in the padding (an axis's numbers) still count as inside.
      var inner = inflate(paperInner(onCard), 0), half = num(onCard.pad, 18) * 0.5;
      inner = { x: inner.x - half, y: inner.y, w: inner.w + 2 * half, h: inner.h };
      var room = roomOnCard(inner, x, align);
      var natural = textBlock(text, size, style, o).w;
      if (room < M.min(natural, inner.w * 0.45)) {
        // Anchored at the card's edge: step inward so the words have the room they need.
        var want = M.min(natural, inner.w);
        if (align === 'left') x = M.max(inner.x, inner.x + inner.w - want);
        else if (align === 'right') x = M.min(inner.x + inner.w, inner.x + want);
        else x = clamp(x, inner.x + want / 2, inner.x + inner.w - want / 2);
        room = roomOnCard(inner, x, align);
      }
      room = M.max(room, size * 2);
      layout = Object.assign({}, o);
      layout.wrap = isNum(o.wrap) ? M.min(o.wrap, room) : room;
      var fitW = Array.isArray(o.fit) ? M.min(num(o.fit[0], room), room) : isNum(o.fit) ? M.min(o.fit, room) : room;
      var fitH = Array.isArray(o.fit) ? num(o.fit[1], Infinity) : Infinity;
      layout.fit = [fitW, fitH];
    }
    var block = textBlock(text, size, style, layout);
    var left = align === 'center' ? x - block.w / 2 : align === 'right' ? x - block.w : x;
    var top = valign === 'middle' ? y - block.h / 2 : valign === 'bottom' ? y - block.h : y;
    var r = { x: left, y: top, w: block.w, h: block.h };
    if (role !== 'label' && role !== 'piece') r = placeWords(keepOnCanvas(r), o, onCard);
    var m = newMark('text', o, String(text));
    var ground = strokeStyle(m, o, r, true);
    m.at = [r.x, r.y]; m.w = r.w; m.h = r.h;
    m.text = String(text);
    if (linked.link) m.link = linked.link;
    m.lines = block.lines; m.size = block.size; m.lh = block.lh; m.style = style; m.align = align;
    m.reveal = o.reveal === 'write' || (o.reveal == null && (style === 'hand' || style === 'title')) ? 'write' : 'fade';
    // Free words on the screen get a thin halo in the screen's own brightness, so busy content behind them recedes.
    // Without a known screen the halo is the opposite of the words.
    if (o.halo !== false && (!ground || (!ground.card && !ground.fill))) {
      var darkGround = ground ? ground.lum < 0.4 : luminance(parseHex(m.tone) || [0, 0, 0]) > 0.4;
      m.halo = darkGround ? '#14161B' : '#FFFFFF';
    }
    m.__box = r;
    m.__layout = role === 'label' ? 'label' : 'words';
    // Loose words may later step aside for a stroke drawn across them (dodgeWords), staying on their card.
    if (role !== 'label' && role !== 'piece' && o.place !== false) m.__dodge = true;
    if (onCard) m.__inside = onCard.id;
    return handle(push(m));
  }

  function safeURL(u) {
    var s = String(u || '').trim();
    return /^https?:\/\/[^\s"'<>]+$/i.test(s) && s.length <= 2000 ? s : null;
  }
  function linkedText(text) {
    var link = null;
    var out = text.replace(/\[([^\]\n]{1,200})\]\((https?:\/\/[^)\s]{1,2000})\)/g, function (all, label, url) {
      if (!link) link = safeURL(url);
      return label;
    });
    out = out.replace(/https?:\/\/[^\s)\]]+/g, function (url) {
      var clean = url.replace(/[.,;:!?]+$/, ''), tail = url.slice(clean.length);
      if (!link) link = safeURL(clean);
      if (clean.length <= 32) return url;
      var host = clean.replace(/^https?:\/\//i, '').replace(/[\/?#].*$/, '').replace(/^www\./, '');
      return host + '/…' + tail;
    });
    return { text: out, link: link };
  }

  function drawHighlight(x, y, w, h, o) {
    o = isObj(o) ? o : {};
    if (![x, y, w, h].every(isNum)) { warn('highlight() needs x, y, w, h numbers'); return null; }
    var r = rectOf(x, y, w, h);
    var m = newMark('highlight', o);
    m.tone = toneHex(o.tone || o.color || 'yellow');
    // A highlighter multiplies with what is under it (the words stay crisp and dark) on light grounds; on dark ones
    // multiplying would make it vanish, so it is a translucent band there.
    var ground = groundUnder(r);
    var dark = ground && ground.lum < 0.35;
    if (!dark && o.blend !== 'normal') m.blend = 'multiply';
    // (Over another window the overlay can't multiply, so the band stays light enough to read through.)
    m.alpha = clamp(num(o.alpha, m.blend ? 0.5 : 0.4), 0.05, 1);
    m.at = [r.x, r.y]; m.w = r.w; m.h = r.h;
    m.__box = r;
    m.__layout = 'highlight';
    return handle(push(m));
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Narration

  function registerSays(src) {
    var texts = sayLiterals(src);
    for (var i = 0; i < texts.length; i++) {
      var index = prog.sayQueue.length;
      prog.sayQueue.push({ index: index, text: texts[i], used: false });
      var lane = prog.lanes[index];
      if (lane && lane.started && lane.estimated && lane.dur != null && lane.unknownText) {
        lane.dur = estimateSeconds(texts[i]);
        lane.unknownText = false;
      }
    }
  }
  function doSay(text) {
    if (text == null) return;
    var s = String(text).trim();
    if (!s) return;
    var found = -1;
    for (var i = prog.sayNext; i < prog.sayQueue.length; i++) {
      if (!prog.sayQueue[i].used && prog.sayQueue[i].text === s) { found = i; break; }
    }
    // A helper defined earlier whose say() runs only now.
    for (var k = 0; found < 0 && k < prog.sayNext; k++) {
      if (!prog.sayQueue[k].used && prog.sayQueue[k].text === s) found = k;
    }
    if (found < 0) {
      // A say() inside a loop or a helper runs again with words that were already spoken: nothing new to pace.
      for (var j = 0; j < prog.sayQueue.length; j++) if (prog.sayQueue[j].used && prog.sayQueue[j].text === s) return;
      warn('say() is spoken only when its words are a plain string in quotes, like say("Here it is.")');
      return;
    }
    prog.sayQueue[found].used = true;
    prog.sayNext = M.max(prog.sayNext, found + 1);
    if (prog.line >= 0 && prog.lanes[prog.line]) prog.lanes[prog.line].open = false;
    prog.line = found;
    prog.stepHasSay = true;
    settleFloating(found);
    prog.lines[found] = s;
  }
  function doStep(n) {
    var next = isNum(n) ? n : prog.step + 1;
    if (prog.floating.length && prog.line >= 0 && prog.pace !== 'now') settleFloating(prog.line);
    prog.step = next;
    prog.stepHasSay = false;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The program's vocabulary

  var TONE_NAMES = Object.keys(TONES);
  function installApi() {
    // Plain JavaScript the program may use; listing them here keeps a program from replacing the engine's own.
    var builtins = ['Object', 'Array', 'String', 'Number', 'Boolean', 'Date', 'RegExp', 'Error', 'TypeError', 'RangeError',
      'SyntaxError', 'Map', 'Set', 'WeakMap', 'Symbol', 'Promise', 'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'JSON'];
    for (var b = 0; b < builtins.length; b++) if (global[builtins[b]] !== undefined) api[builtins[b]] = global[builtins[b]];
    api.console = { log: function () { log(Array.prototype.join.call(arguments, ' ')); }, warn: function () { log(Array.prototype.join.call(arguments, ' ')); }, error: function () { log(Array.prototype.join.call(arguments, ' ')); } };
    for (var t = 0; t < TONE_NAMES.length; t++) api[TONE_NAMES[t]] = TONE_NAMES[t];
    api.ink = 'ink';

    Object.defineProperty(api, 'W', { get: W, enumerable: true });
    Object.defineProperty(api, 'H', { get: H, enumerable: true });
    Object.defineProperty(api, 'PT', { get: function () { return pt(1); }, enumerable: true });
    Object.defineProperty(api, 'windows', { get: function () { return prog ? prog.windows : []; }, enumerable: true });

    api.step = function (n) { doStep(n); };
    // onScreen(n): draw on screenshot n instead of the one under the pointer. The host reads it from the start of the
    // program and begins the drawing on that display (begin's `screen`), so here it only checks it was honoured.
    api.onScreen = function (n) {
      if (!prog) return null;
      var wanted = M.round(num(n, NaN));
      if (!isFinite(wanted) || wanted < 1) { warn('onScreen(n) needs a screenshot number, like onScreen(2)'); return null; }
      if (prog.screen == null) {
        if (card.marks.length > prog.firstSeq) warn('onScreen() goes first in a program; this drawing stays on the screen it began on');
        else warn('onScreen(' + wanted + ') was ignored: this drawing is on the screen under the pointer');
      } else if (prog.screen !== wanted) {
        warn('there is no screenshot ' + wanted + ' to draw on; this drawing is on screenshot ' + prog.screen);
      }
      return { screen: prog.screen, width: W(), height: H() };
    };
    api.say = function (text) { doSay(text); };

    api.line = function () { var a = lineArgs(arguments); return drawLine(a.pts, a.o, 'line'); };
    api.arrow = function () { var a = lineArgs(arguments); return drawLine(a.pts, a.o, 'arrow'); };
    api.curve = function () { var a = lineArgs(arguments); return drawLine(a.pts, a.o, 'curve'); };
    api.box = function (x, y, w, h, o) { return drawBox(x, y, w, h, o); };
    api.circle = function (cx, cy, r, o) { return drawCircle(cx, cy, r, r, o); };
    api.ellipse = function (cx, cy, rx, ry, o) { return drawCircle(cx, cy, rx, ry, o); };
    api.dot = function (x, y, o) { return drawDot(x, y, isNum(o) ? { r: o } : o); };
    api.text = function (x, y, text, o) { return drawText(x, y, text, o); };
    api.write = function (x, y, text, o) {
      o = isObj(o) ? Object.assign({}, o) : {};
      if (!o.style) o.style = 'hand';
      o.reveal = 'write';
      return drawText(x, y, text, o);
    };
    api.highlight = function (x, y, w, h, o) {
      if (!isNum(x)) return doHighlightPart(x, typeof y === 'string' ? y : isObj(y) ? y.tone : undefined);
      return drawHighlight(x, y, w, h, o);
    };

    api.erase = function (id) { if (id == null) { warn('erase() wants the id of what to remove, for example erase("p3")'); return; } doErase(id); };
    api.move = function (id, dx, dy) { if (!isNum(dx) || !isNum(dy)) { warn('move(id, dx, dy) needs two numbers'); return; } doMove(id, dx, dy, false, 'move'); };
    api.moveTo = function (id, x, y) { if (!isNum(x) || !isNum(y)) { warn('moveTo(id, x, y) needs two numbers'); return; } doMove(id, x, y, true, 'moveTo'); };
    api.recolor = function (id, color) { doRecolor(id, color); };
    api.restyle = function (id, o) { if (id == null) { warn('restyle() needs a part id like "p3"'); return; } doRestyle(id, o); };
    api.scale = function (id, k) { if (id == null) { warn('scale() needs a part id like "p3"'); return; } doScale(id, k); };
    api.startOver = function () { doStartOver(); };
    api.undo = function () { doUndo(); };
    api.path = function (d, o) { return drawPath(d, o); };
    api.poly = function (pts, o) { return drawPoly(pts, o); };
    api.rect = function (x, y, w, h, o) { return drawBox(x, y, w, h, o); };

    // What Clicky notices and plans (drawn nowhere; the app reads them).
    api.seen = function (text) { note('seen', text); };
    api.noted = function (text) { note('noted', text); };
    api.plan = function (text) { note('plan', text); };
    api.lessonTitle = function (text) { note('lesson', text); };

    // Things the app does when the line reaches them.
    api.typeText = function (x, y, text) {
      if (isNum(x) && isNum(y)) { if (text == null || String(text) === '') { warn('typeText(x, y, "words") needs words'); return null; } }
      else { text = x; x = null; y = null; }
      var words = String(text == null ? '' : text);
      if (!words) { warn('typeText() needs words'); return null; }
      if (words.length > 2000) { warn('typeText() types at most 2000 characters'); words = words.slice(0, 2000); }
      var m = pushAction('type', words, isNum(x) ? [x, y] : null);
      return m ? handle(m, { x: num(x, 0), y: num(y, 0), w: 0, h: 0 }) : null;
    };
    api.copyText = function (text) {
      var words = String(text == null ? '' : text);
      if (!words) { warn('copyText() needs words'); return null; }
      if (words.length > 20000) { warn('copyText() copies at most 20000 characters'); words = words.slice(0, 20000); }
      pushAction('copy', words);
      return null;
    };
    api.openPage = function (url) {
      var u = safeURL(url);
      if (!u) { warn('openPage() opens web pages only, like openPage("https://example.com")'); return null; }
      if (prog.opened >= 1) { warn('one openPage() per answer'); return null; }
      prog.opened++;
      pushAction('open', u);
      return null;
    };
    api.handOff = function (o) {
      if (typeof o === 'string') o = { task: o };
      if (!isObj(o) || !o.task) { warn('handOff({task: "…"}) needs the task to hand to an agent'); return null; }
      var payload = { task: String(o.task).slice(0, 4000) };
      if (o.label) payload.label = String(o.label).slice(0, 80);
      if (o.clicky) payload.clicky = String(o.clicky).slice(0, 80);
      if (o.newClicky) payload.newClicky = true;
      pushAction('handoff', payload);
      return null;
    };
    api.sfx = function (name) {
      var key = String(name || '').toLowerCase().replace(/[\s_]+/g, '-');
      if (!SFX[key]) { warn('sfx() plays one of ' + Object.keys(SFX).join(', ')); return null; }
      pushAction('sfx', key);
      return null;
    };
    // Inserted by the host when a kept card continues (never written by the brain): turn n begins, and marks of
    // earlier turns from index `keep` on that were never drawn are dropped, as they were live.
    api.__turn = function (n, keep) { doTurn(n, keep); };
    api.clear = function () {
      var ids = [];
      for (var i = 0; i < card.marks.length; i++) if (!card.marks[i].__erased && card.marks[i].do !== 'edit') ids.push(card.marks[i].id);
      if (ids.length) doErase(ids.join(','), 'clear');
    };

    api.range = function (a, b, s) {
      if (b === undefined) { b = a; a = 0; }
      s = s || 1;
      var out = [];
      for (var v = a; s > 0 ? v < b : v > b; v += s) { out.push(v); if (out.length > 10000) break; }
      return out;
    };
    api.lerp = function (a, b, t) { return a + (b - a) * t; };
    api.clamp = clamp;
    api.polar = function (cx, cy, r, degrees) { var a = degrees * M.PI / 180; return [cx + r * M.cos(a), cy + r * M.sin(a)]; };
    api.mid = function (a, b) { return [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]; };
    api.dist = function (a, b) { return M.hypot(b[0] - a[0], b[1] - a[1]); };
    api.measure = function (text, size, style) { return textWidth(text, num(size, 18), style || 'ui'); };
  }

  function seededMath() {
    var copy = {};
    Object.getOwnPropertyNames(Math).forEach(function (k) { copy[k] = Math[k]; });
    var r = seeded(20261030);
    copy.random = r;
    return { math: copy, random: r };
  }

  // What plugins (draw-pieces.js, figure-api.js, …) get: the contract's ctx plus helpers the 2D pieces share.
  var ctx = {
    push: function (mark) { return push(mark); },
    warn: function (message) { warn(message); },
    nextId: function (prefix) { return nextId(prefix); },
    currentStep: function () { return prog ? prog.step : 0; },
    get canvas() { return prog ? { width: prog.canvas.width, height: prog.canvas.height, scale: prog.canvas.scale } : { width: 1280, height: 832, scale: 1 }; },
    get ink() { return ink(); },
    onBegin: function (fn) { if (typeof fn === 'function') beginHooks.push(fn); },
    // Program code a plugin runs between statements (a figure's per-frame tick, docs/dsl-3d.md) gets the runaway-loop
    // guard armed for `ms` milliseconds, as if it were a statement of its own. Without this the guard, disarmed
    // between statements, stops such code after a few hundred calls. Returns fn's value; its errors propagate.
    guarded: function (fn, ms) {
      if (typeof fn !== 'function') return undefined;
      var outer = { deadline: guard.deadline, count: guard.count, tripped: guard.tripped };
      var deadline = nowMs() + clamp(isNum(ms) ? ms : 50, 1, guard.limitMs);
      guard.deadline = outer.deadline ? M.min(outer.deadline, deadline) : deadline;
      guard.count = 0;
      guard.tripped = false;
      try {
        return fn();
      } finally {
        guard.deadline = outer.deadline;
        guard.count = outer.count;
        guard.tripped = outer.tripped || !!(outer.deadline && nowMs() > outer.deadline);
      }
    },
    /** Ask the host for data mark `mark` needs; returns the request's ref. The host answers with patch(ref, fields). */
    request: function (mark, payload) { return request(mark, payload); },
    /** fn(mark, fields) runs after the host's fields are merged into a requested mark (to update its words, size…). */
    onPatch: function (fn) { if (typeof fn === 'function') patchHooks.push(fn); },
    /** An invisible action the host performs when the line reaches it (`type`, `copy`, `open`, `handoff`, `sfx`). */
    action: function (role, payload, at) { return pushAction(String(role), payload, at); },
    /** A note for the host (`seen`, `noted`, `plan`, `lesson`). */
    note: function (kind, text) { note(String(kind), text); },
    /** Tell the host a 3D part's recipe as soon as it is known, so its mesh is built before the part's line is heard. */
    prewarmShape: function (kind, recipe) {
      var f = hostFn('shape3d');
      if (!f || typeof kind !== 'string' || typeof recipe !== 'string') return;
      try { f(kind, recipe); } catch (e) { /* only a head start: the stage builds the mesh anyway */ }
    },
    util: {
      pt: pt, clamp: clamp, isNum: isNum, num: num, isObj: isObj, toneHex: toneHex, readable: readable, luminance: luminance,
      parseHex: parseHex, toHex: toHex, mix: mix, contrast: contrast, textWidth: textWidth, textBlock: textBlock, screenLum: screenLum, screenBusy: screenBusy,
      groundUnder: groundUnder, placeContainer: placeContainer, placeWords: placeWords, keepOnCanvas: keepOnCanvas,
      freeSpot: freeSpot, liveBoxes: liveBoxes, overlapArea: overlapArea, union: union, boundsOf: boundsOf, handle: handle,
      newMark: newMark, strokeStyle: strokeStyle, handEllipse: handEllipse, handPolyline: handPolyline, roundedRectPoints: roundedRectPoints,
      arrowHead: arrowHead, bendPoints: bendPoints, toPoints: toPoints, seeded: seeded, hashString: hashString,
      drawLine: drawLine, drawText: drawText, drawBox: drawBox, drawCircle: drawCircle, drawDot: drawDot, drawHighlight: drawHighlight,
      marks: function () { return card ? card.marks : []; }, PAPER_INK: PAPER_INK, TONES: TONES,
      // Layout on cards and around strokes.
      boxOf: boxOf, inflate: inflate, segmentHits: segmentHits, polylineHits: polylineHits, strokePaths: strokePaths,
      obstaclesNear: obstaclesNear, clashScore: clashScore, cleanSpot: cleanSpot, cardAt: cardAt, cardFor: cardFor,
      paperInner: paperInner, cardInnerOf: cardInnerOf, fitCard: fitCard, alongPolyline: alongPolyline, dodgeWords: dodgeWords,
      nudge: nudge, retract: retract, layoutTimeLeft: layoutTimeLeft,
      byId: function (id) { return card ? card.byId[id] : null; }
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Running statements

  function execute(tx, raw) {
    prog.statement = raw;
    prog.stmtPart = null;
    guard.deadline = nowMs() + guard.limitMs;
    guard.count = 0;
    guard.tripped = false;
    prog.running = raw;
    var ok = true;
    try {
      indirectEval('with (__drawScope) {\n' + tx + '\n}');
    } catch (e) {
      ok = false;
      reportError(e, raw);
    } finally {
      prog.running = null;
      guard.deadline = 0;
      prog.statement = null;
      prog.stmtPart = null;
    }
    return ok;
  }

  // The longest runnable prefix: a statement that fails (it can't parse, throws or runs past the time limit) ends the
  // program there. What that statement drew before failing is taken back, the statements after it only have their
  // spoken lines counted (so the voice's numbering stays right), and continueTurn() keeps only the prefix, so
  // replaying a kept card draws exactly what is on screen. Begin with {afterError: "skip"} to report and skip instead.
  function cutProgram(start, fromSeq) {
    if (prog.afterError !== 'cut' || prog.cutAt >= 0) return false;
    prog.cutAt = start;
    var taken = [];
    for (var i = fromSeq; i < card.marks.length; i++) {
      var m = card.marks[i];
      if (m.__released || m.__erased) continue;
      m.__dropped = true;
      taken.push(m);
    }
    retract(taken);
    warn('the drawing stopped at the statement that failed; nothing after it was drawn');
    return true;
  }

  // A statement that fails to parse is only waiting for more code if some continuation would make it parse
  // (`if (a)` then the body on the next line, `function f()` then its braces, …).
  function couldContinue(tx) {
    var probes = ['\n__probe__()', '\n{}'];
    for (var i = 0; i < probes.length; i++) {
      try { FunctionCtor(tx + probes[i]); return true; } catch (e) { /* try the next */ }
    }
    return false;
  }

  // Run the next complete statement. Returns true if there may be more to run.
  function runNext() {
    if (!prog || prog.cancelled) return false;
    if (!prog.ready.length) {
      if (prog.inputDone && prog.carry >= 0) prog.ready.push({ s: prog.carry, e: prog.splitter.text.length });
      else { pump(); return false; }
    }
    var r = prog.ready.shift();
    var s = prog.carry >= 0 ? prog.carry : r.s;
    var raw = prog.splitter.slice(s, r.e);
    var last = prog.inputDone && prog.ready.length === 0;
    if (!/[^\s;]/.test(raw)) { prog.carry = -1; pump(); return prog.ready.length > 0; }
    if (prog.cutAt >= 0) {
      // After the cut: only the spoken lines are counted.
      prog.carry = -1;
      registerSays(raw);
      pump();
      return prog.ready.length > 0;
    }
    var tx = transform(raw);
    try {
      FunctionCtor(tx);
    } catch (e) {
      if (e instanceof SyntaxError && !last && couldContinue(tx)) {
        prog.carry = s;
        return prog.ready.length > 0;
      }
      prog.carry = -1;
      registerSays(raw);
      reportError(e, raw);
      cutProgram(s, card.marks.length);
      pump();
      return prog.ready.length > 0;
    }
    prog.carry = -1;
    registerSays(raw);
    var before = card.marks.length;
    prog.runningStart = s;
    prog.runningSeq = before;
    if (!execute(tx, raw)) cutProgram(s, before);
    // Only a statement the host's watchdog stops leaves these set, for recover().
    prog.runningStart = null;
    prog.runningSeq = null;
    pump();
    return prog.ready.length > 0;
  }

  function feed() {
    var stmts = prog.splitter.take();
    for (var i = 0; i < stmts.length; i++) prog.ready.push(stmts[i]);
    if (!engine.stepwise) while (runNext()) { /* run every ready statement */ }
  }

  // A statement in a few words, for the debug beat chips: what it calls and its first quoted words.
  function shortStatement(src) {
    var t = String(src || '').trim();
    if (/^for\b|^while\b/.test(t)) return 'loop';
    var call = /([A-Za-z_$][\w$]*)\s*\(/.exec(t.replace(/^(?:var|let|const)\s+[\w$]+\s*=\s*/, ''));
    var quoted = /["'`]([^"'`]{1,40})["'`]/.exec(t);
    var label = (call ? call[1] : t.slice(0, 12)) + (quoted ? ' "' + quoted[1] + '"' : '');
    return label.length > 33 ? label.slice(0, 32) + '…' : label;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The end-of-drawing report: what ran off the canvas and which words sit on top of each other. Each problem is a
  // warning event when the drawing is done, and the card keeps the list so a follow-up turn is shown it (describe()).

  var MAX_REPORT = 14;
  function shortWords(m) {
    var t = String(m.text || m.label || m.do).replace(/\s+/g, ' ').trim();
    return t.length > 28 ? t.slice(0, 27) + '…' : t;
  }
  function finishReport() {
    if (!prog || prog.reported || !card) return;
    prog.reported = true;
    var c = prog.canvas, slack = 2, words = [], problems = [];
    for (var i = 0; i < card.marks.length; i++) {
      var m = card.marks[i];
      if (!m.__released || m.__erased || m.do === 'edit' || m.do === 'action' || /3d$/.test(m.do) || m.do === 'figure') continue;
      var b = transformedBox(m);
      if (!b || !(b.w > 0 || b.h > 0)) continue;
      var off = [];
      if (b.x < -slack) off.push('left');
      if (b.y < -slack) off.push('top');
      if (b.x + b.w > c.width + slack) off.push('right');
      if (b.y + b.h > c.height + slack) off.push('bottom');
      if (off.length) problems.push(m.do + ' "' + shortWords(m) + '" (' + m.id + ', ' + m.part + ') runs off the ' + off.join(' and ') + ' of the canvas');
      if (m.do === 'text') words.push({ m: m, b: b });
    }
    for (var a = 0; a < words.length; a++) {
      for (var k = a + 1; k < words.length; k++) {
        var p = words[a].b, q = words[k].b;
        var w = M.min(p.x + p.w, q.x + q.w) - M.max(p.x, q.x), h = M.min(p.y + p.h, q.y + q.h) - M.max(p.y, q.y);
        if (w > 3 && h > 4) {
          problems.push('words "' + shortWords(words[a].m) + '" (' + words[a].m.id + ') and "' + shortWords(words[k].m) + '" (' + words[k].m.id + ') overlap');
        }
      }
    }
    var seen = {};
    card.report = problems.filter(function (t) { if (seen[t]) return false; seen[t] = true; return true; }).slice(0, MAX_REPORT);
    for (var r = 0; r < card.report.length; r++) warn(card.report[r]);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Describing the card for follow-up turns

  // Drawn and not taken away yet (an erase waiting for its moment hasn't taken it away).
  function onScreen(m) {
    if (!m.__released || m.do === 'edit') return false;
    if (!m.__erased) return true;
    return !m.__dropped && !!m.__erasedBy && !m.__erasedBy.__released;
  }

  // Program variables holding a part's handle (`const server = box(…)` → p4: "server"). A continued drawing keeps them,
  // so a follow-up can still write `server.cx`.
  function partVariables() {
    var out = {};
    if (!card) return out;
    var names = Object.getOwnPropertyNames(global);
    for (var i = 0; i < names.length; i++) {
      var key = names[i];
      if ((baselineGlobals && own(baselineGlobals, key)) || key.charAt(0) === '_' || key.length > 40) continue;
      var v;
      try { v = global[key]; } catch (e) { continue; }
      if (!isObj(v)) continue;
      // A 2D handle names its part; a figure's handle (`const f = figure(…)`) names the figure mark.
      var part = typeof v.part === 'string' ? v.part
        : v.kind === 'figure' && typeof v.id === 'string' && card.byId[v.id] ? card.byId[v.id].part : null;
      if (part && card.partsById[part] && !out[part]) out[part] = key;
    }
    return out;
  }

  // `options` (an object or its JSON) for the host's follow-up turns: `drawnOnly` lists only marks already on screen
  // (an answer cut off mid-way never showed the rest, and returns '' when nothing is drawn); `maxChars` caps the text,
  // folding the oldest parts into one line.
  function describe(options) {
    if (typeof options === 'string') { try { options = JSON.parse(options); } catch (e) { options = null; } }
    options = isObj(options) ? options : {};
    if (!card) return '';
    var drawnOnly = !!options.drawnOnly;
    var c = prog ? prog.canvas : { width: 1280, height: 832 };
    var vars = drawnOnly ? partVariables() : {};
    var header = 'Canvas ' + c.width + 'x' + c.height + ' units, x to the right, y down. Parts on the card' +
      (Object.keys(vars).length ? ' (in brackets: your program\'s variable for the part, still usable):' : ':');
    var listed = [];
    var lastStep = null, lastTurn = null;
    for (var i = 0; i < card.parts.length; i++) {
      var p = card.parts[i];
      // A figure's parts, labels and motions are listed by the figure's own description (figure-api's describe).
      var live = p.marks.filter(function (id) {
        var m = card.byId[id];
        return m && (drawnOnly ? onScreen(m) && !/3d$/.test(m.do) : !m.__erased);
      });
      if (!live.length) continue;
      var lines = [];
      if (p.step !== lastStep || p.turn !== lastTurn) {
        lines.push('Step ' + p.step + (p.turn > 1 ? ' (turn ' + p.turn + ')' : '') + ':');
        lastStep = p.step;
        lastTurn = p.turn;
      }
      var kinds = {};
      live.forEach(function (id) { var k = card.byId[id].do; kinds[k] = (kinds[k] || 0) + 1; });
      var summary = Object.keys(kinds).map(function (k) { return (kinds[k] > 1 ? kinds[k] + 'x ' : '') + k; }).join(', ');
      var words = live.map(function (id) { return card.byId[id].text; }).filter(function (t) { return t; }).join(' / ');
      var b = null;
      live.forEach(function (id) { var tb = transformedBox(card.byId[id]); if (tb) b = b ? union(b, tb) : tb; });
      var where = b ? ' [' + [b.x, b.y, b.w, b.h].map(function (v) { return M.round(v); }).join(',') + ']' : '';
      lines.push('  ' + p.id + (p.name ? ' "' + p.name + '"' : '') + (vars[p.id] ? ' (' + vars[p.id] + ')' : '') + ': ' + summary + (words ? ' "' + words.slice(0, 60) + '"' : '') + where +
        ' (' + live[0] + (live.length > 1 ? '–' + live[live.length - 1] : '') + ')');
      listed.push({ id: p.id, lines: lines });
    }
    if (drawnOnly && !listed.length) return '';
    var max = isNum(options.maxChars) && options.maxChars > 0 ? options.maxChars : Infinity;
    function text(from) {
      var out = [header];
      if (from > 0) out.push('(left out to fit: ' + listed[0].id + (from > 1 ? '–' + listed[from - 1].id : '') + ', the ' + (from > 1 ? from + ' oldest parts' : 'oldest part') + ')');
      for (var k = from; k < listed.length; k++) out.push(listed[k].lines.join('\n'));
      return out.join('\n');
    }
    var report = card.report && card.report.length ? '\nProblems in this drawing (fix them when you edit it):\n' +
      card.report.map(function (t) { return '  - ' + t; }).join('\n') : '';
    var from = 0, result = text(0) + report;
    while (result.length > max && from < listed.length - 1) result = text(++from) + report;
    return result.length > max ? result.slice(0, M.max(0, max - 1)) + '…' : result;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Cards the user can drag and close, and what is kept when the screen changes under the drawing
  //
  // A card is a paper, a photo or another media card, or a 3D figure. Other marks ride on the smallest card under
  // them (their centre on it, with some slack, or most of them on it); a card mostly inside a bigger one rides on that
  // one. Marks riding on no card mark the screen itself (rings, callouts, regions, highlights) and lose their meaning
  // when the screen changes. Boxes are canvas units.

  function isCardMark(m) { return m.do === 'figure' || (m.__layout === 'container' && m.do !== 'region'); }
  function cardLayout(includePending) {
    var marks = [], cards = [], i, j;
    if (!card) return { cards: cards, loose: marks };
    for (i = 0; i < card.marks.length; i++) {
      var m = card.marks[i];
      if (m.__erased || m.do === 'edit' || /3d$/.test(m.do)) continue;
      if (!m.__released && !includePending) continue;
      marks.push(m);
    }
    var found = [];
    for (i = 0; i < marks.length; i++) {
      if (!isCardMark(marks[i])) continue;
      var box = transformedBox(marks[i]);
      if (box && box.w > 1 && box.h > 1) found.push({ mark: marks[i], box: box, marks: [marks[i].id], has3D: marks[i].do === 'figure' });
    }
    // Biggest first: a card mostly inside a bigger one rides on the smallest such card.
    found.sort(function (a, b) { return b.box.w * b.box.h - a.box.w * a.box.h; });
    for (i = 0; i < found.length; i++) {
      var under = null;
      for (j = 0; j < cards.length; j++) {
        if (overlapArea(found[i].box, cards[j].box) >= 0.6 * found[i].box.w * found[i].box.h) under = cards[j];
      }
      if (under) {
        under.marks.push(found[i].mark.id);
        if (found[i].has3D) under.has3D = true;
      } else cards.push(found[i]);
    }
    var loose = [];
    for (i = 0; i < marks.length; i++) {
      var d = marks[i];
      if (isCardMark(d)) continue;
      var b = transformedBox(d), best = null;
      if (b) {
        var cx = b.x + b.w / 2, cy = b.y + b.h / 2, area = M.max(1, b.w * b.h);
        for (j = 0; j < cards.length; j++) {
          var s = cards[j].box, slack = 12;
          var centred = cx >= s.x - slack && cx <= s.x + s.w + slack && cy >= s.y - slack && cy <= s.y + s.h + slack;
          if ((centred || overlapArea(b, s) >= 0.4 * area) && (!best || s.w * s.h < best.box.w * best.box.h)) best = cards[j];
        }
      }
      if (best) best.marks.push(d.id); else loose.push(d);
    }
    return { cards: cards, loose: loose };
  }
  function cardsNow() {
    return cardLayout(false).cards.map(function (c) {
      var m = c.mark;
      return {
        id: m.id, kind: m.do, box: [c.box.x, c.box.y, c.box.w, c.box.h].map(function (v) { return round(v, 2); }),
        marks: c.marks.filter(function (id) { var x = card.byId[id]; return x && x.__released && !x.__erased; }),
        title: typeof m.title === 'string' && m.title ? m.title : (typeof m.__label === 'string' ? m.__label : ''), has3D: !!c.has3D
      };
    });
  }
  function idList(value) {
    if (typeof value === 'string') { try { value = JSON.parse(value); } catch (e) { value = null; } }
    if (isObj(value)) value = value.marks;
    return Array.isArray(value) ? value.map(String) : [];
  }
  // The user dragged a card: its marks move at once by dx, dy (kept on the canvas). Returns the move made, [dx, dy].
  function moveCardNow(ids, dx, dy) {
    if (!prog || !card || !isNum(dx) || !isNum(dy)) return null;
    var targets = idList(ids).map(function (id) { return card.byId[id]; }).filter(function (m) {
      return m && m.__released && !m.__erased && m.do !== 'edit' && m.do !== 'figure' && !/3d$/.test(m.do);
    });
    if (!targets.length) return null;
    var box = null;
    for (var i = 0; i < targets.length; i++) { var tb = transformedBox(targets[i]); if (tb) box = box ? union(box, tb) : tb; }
    if (box) {
      dx = clamp(box.x + dx, 0, M.max(0, W() - box.w)) - box.x;
      dy = clamp(box.y + dy, 0, M.max(0, H() - box.h)) - box.y;
    }
    var t = clock();
    for (var j = 0; j < targets.length; j++) {
      var xf = targets[j].xf || [1, 0, 0];
      targets[j].xf = [xf[0], xf[1] + dx, xf[2] + dy];
      remark(targets[j], 'move', 0, 0, t);
    }
    flushMarks();
    return [round(dx, 2), round(dy, 2)];
  }
  // Remove marks from the screen at once (a card the user closed, marks the screen no longer matches). Returns how many.
  function dropNow(list) {
    var gone = [];
    for (var i = 0; i < list.length; i++) {
      var m = list[i];
      if (!m || m.__erased || m.do === 'edit') continue;
      m.__erased = true;
      m.__dropped = true;
      if (m.__released) gone.push(m.id);
      // A figure takes its parts, labels and motions with it (removing the figure removes them from the stage).
      if (m.do === 'figure') {
        for (var j = 0; j < card.marks.length; j++) {
          var part = card.marks[j];
          if (part.figure === m.id && !part.__erased) { part.__erased = true; part.__dropped = true; }
        }
      }
    }
    if (gone.length) emit({ type: 'remove', ids: gone });
    return gone.length;
  }
  // What lies under the drawing changed: marks that point at the screen go (also those still waiting for their line);
  // cards and what is on them stay. Returns {kept: cards left, dropped: marks removed}.
  function dropScreenMarksNow() {
    var layout = cardLayout(true);
    var dropped = dropNow(layout.loose);
    return { kept: layout.cards.length, dropped: dropped };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Locking the language's own objects
  //
  // Every program shares this context with the engine and with later turns. Without this, `Object.prototype.x = 1`
  // or `Array.prototype.map = null` in one program would break the engine's own loops for the rest of the session,
  // and `globalThis.JSON = null` would break the next program's drawing calls.

  function freezeDeep(roots) {
    var stack = roots.slice(), seen = new WeakSet();
    while (stack.length) {
      var o = stack.pop();
      if (o === null || (typeof o !== 'object' && typeof o !== 'function') || o === global || seen.has(o)) continue;
      seen.add(o);
      try { Object.freeze(o); } catch (e) { /* an exotic object that can't be frozen */ }
      var proto = Object.getPrototypeOf(o);
      if (proto) stack.push(proto);
      var keys = Reflect.ownKeys(o);
      for (var i = 0; i < keys.length; i++) {
        var d = Object.getOwnPropertyDescriptor(o, keys[i]);
        if (!d) continue;
        if ('value' in d) stack.push(d.value);
        else { if (d.get) stack.push(d.get); if (d.set) stack.push(d.set); }
      }
    }
  }
  function lockIntrinsics() {
    var roots = [];
    for (var i = 0; i < INTRINSIC_NAMES.length; i++) {
      var name = INTRINSIC_NAMES[i], d = Object.getOwnPropertyDescriptor(global, name);
      if (!d) continue;
      if ('value' in d) roots.push(d.value);
      // The binding itself stays put: `globalThis.Object = null` changes nothing.
      if (d.configurable) {
        try {
          Object.defineProperty(global, name, 'value' in d ? { writable: false, configurable: false } : { configurable: false });
        } catch (e) { /* leave it */ }
      }
    }
    // Prototypes only reachable through instances: iterators, generators and async functions.
    var hidden = [
      function () { return [][Symbol.iterator](); }, function () { return ''[Symbol.iterator](); },
      function () { return new Map().entries(); }, function () { return new Set().values(); },
      function () { return /a/[Symbol.matchAll]('a'); }, function () { return function* () {}; },
      function () { return async function () {}; }, function () { return async function* () {}; }
    ];
    for (var h = 0; h < hidden.length; h++) {
      try { roots.push(Object.getPrototypeOf(hidden[h]())); } catch (e) { /* not in this JavaScriptCore */ }
    }
    freezeDeep(roots);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The host's entry points (docs/drawing-contract.md)

  var engine = {
    version: VERSION,
    /** When true, append()/end() only scan; the host calls runNext() once per statement (one time limit each). */
    stepwise: false,

    begin: function (options) {
      if (typeof options === 'string') { try { options = JSON.parse(options); } catch (e) { options = null; } }
      options = isObj(options) ? options : {};
      var keep = !!options.keep && card;
      if (!keep) {
        if (card) {
          var ids = [];
          for (var i = 0; i < card.marks.length; i++) {
            var m = card.marks[i];
            if (m.__released && !m.__erased && m.do !== 'edit') ids.push(m.id);
          }
          if (ids.length) emit({ type: 'remove', ids: ids });
        }
        cleanGlobals();
        newCard();
        var sm = seededMath();
        api.Math = sm.math;
        api.random = sm.random;
      } else {
        // Continuing the card: what the last answer never got to draw (it was cut off) is dropped for good, and its
        // erases that never happened leave their marks on screen.
        for (var k = 0; k < card.marks.length; k++) {
          var left = card.marks[k];
          if (left.__released) continue;
          if (left.do === 'edit' && left.op === 'erase') {
            (left.__targets || []).forEach(function (t) { if (t.__released && !t.__dropped) t.__erased = false; });
          }
          if (left.do !== 'edit') { left.__erased = true; left.__dropped = true; }
          left.__released = true;
        }
      }
      var canvas = isObj(options.canvas) ? options.canvas : {};
      var hex = parseHex(options.ink);
      prog = {
        canvas: { width: num(canvas.width, 1280), height: num(canvas.height, 832), scale: num(canvas.scale, 1) > 0 ? num(canvas.scale, 1) : 1 },
        ink: hex ? toHex(hex) : DEFAULT_INK,
        windows: Array.isArray(options.windows) ? options.windows : [],
        screenshotSize: options.screenshotSize || null,
        pace: options.pace === 'now' ? 'now' : 'speech',
        splitter: new Splitter(),
        ready: [], carry: -1, inputDone: false, ended: false, finalized: false, cancelled: false,
        sayQueue: [], sayNext: 0, lines: {}, lanes: {}, floating: [],
        step: 0, line: -1, stepHasSay: false, rush: false, turn: keep ? (prog ? prog.turn + 1 : 2) : 1,
        origin: clock() - (keep && prog ? prog.pausedTotal : 0), lastStart: 0, lastStep: null, doneSent: false, timed: [], statement: null, stmtPart: null, running: null,
        paused: false, pausedAt: 0, pausedTotal: keep && prog ? prog.pausedTotal : 0, actions: 0, notes: [], spokenWords: 0,
        spokenRate: [], opened: 0, afterError: options.afterError === 'skip' ? 'skip' : 'cut', cutAt: -1, reported: false,
        screen: isNum(options.screen) && options.screen >= 1 ? M.round(options.screen) : null, firstSeq: keep ? card.marks.length : 0
      };
      prog.lastStart = prog.origin;
      guard.limitMs = M.max(20, M.round(num(options.timeLimit, 0.4) * 1000));
      for (var h = 0; h < beginHooks.length; h++) {
        try { beginHooks[h](prog.canvas, keep); } catch (e) { log('module begin hook failed: ' + e); }
      }
      return true;
    },

    append: function (text) {
      if (!prog || prog.cancelled || prog.ended) return false;
      prog.splitter.push(String(text));
      feed();
      return true;
    },

    end: function () {
      if (!prog || prog.cancelled || prog.ended) return false;
      prog.ended = true;
      prog.splitter.finish();
      prog.inputDone = true;
      feed();
      pump();
      return true;
    },

    runNext: function () { return runNext(); },

    /** After the host's hard time limit killed a statement: report it and carry on with the next one. */
    recover: function () {
      if (!prog) return false;
      var stmt = prog.running;
      prog.running = null;
      prog.statement = null;
      prog.stmtPart = null;
      guard.deadline = 0;
      emit({ type: 'error', message: 'this statement ran past the time limit and was stopped', statement: stmt ? String(stmt).trim().slice(0, 240) : null });
      if (isNum(prog.runningStart)) cutProgram(prog.runningStart, num(prog.runningSeq, card.marks.length));
      prog.runningStart = null;
      prog.runningSeq = null;
      pump();
      return true;
    },

    lineStarted: function (index, seconds) {
      if (!prog || !isNum(index) || index < 0) return false;
      var lane = laneFor(index);
      if (lane.started) return false;
      for (var k in prog.lanes) {
        var other = prog.lanes[k];
        if (other.index >= 0 && other.index < index && other.started && !other.finished) other.finished = true;
      }
      lane.started = true;
      lane.base = drawNow();
      var known = prog.sayQueue[index];
      lane.estimated = !(isNum(seconds) && seconds > 0);
      lane.unknownText = !known;
      lane.dur = lane.estimated ? estimateSeconds(known && known.text) : seconds;
      pump();
      return true;
    },

    lineFinished: function (index) {
      if (!prog || !isNum(index)) return false;
      var lane = laneFor(index);
      lane.finished = true;
      if (lane.started) lane.dur = M.max(0.2, M.min(lane.dur == null ? Infinity : lane.dur, drawNow() - lane.base));
      pump();
      return true;
    },

    finishNow: function () {
      if (!prog) return false;
      prog.rush = true;
      if (prog.floating.length) {
        if (prog.line >= 0) settleFloating(prog.line);
        else {
          var lane = laneFor(-1);
          for (var i = 0; i < prog.floating.length; i++) lane.queue.push(prog.floating[i]);
          prog.floating = [];
        }
      }
      var t = drawNow();
      for (var k in prog.lanes) {
        var l = prog.lanes[k];
        if (!l.queue.length) continue;
        if (!l.started) { l.started = true; l.base = t; }
        l.rush = true;
      }
      pump();
      return true;
    },

    cancel: function () {
      if (!prog) return false;
      prog.cancelled = true;
      prog.ready = [];
      prog.floating = [];
      for (var k in prog.lanes) prog.lanes[k].queue = [];
      flushMarks();
      pendingSounds = [];
      if (!prog.doneSent) { prog.doneSent = true; emit({ type: 'done' }); }
      return true;
    },

    drain: function () {
      if (prog && !prog.cancelled) {
        pump();
        flushMarks();
        if (!prog.doneSent && prog.finalized && !prog.floating.length && !prog.timed.length) {
          var waiting = false;
          for (var k in prog.lanes) if (prog.lanes[k].queue.length) { waiting = true; break; }
          if (!waiting && !prog.paused && drawNow() + 0.004 >= prog.lastStart) {
            finishReport();
            prog.doneSent = true;
            emit({ type: 'done' });
          }
        }
      }
      flushMarks();
      if (pendingSounds.length) { events = events.concat(pendingSounds); pendingSounds = []; }
      var out = events;
      events = [];
      return out;
    },

    drainJSON: function () { return stringify(engine.drain()); },

    /** The host's answer to a plugin's request event (`ref`): merge `fields` (an object or JSON) into that mark. */
    patch: function (ref, fields) { return patch(String(ref), fields); },

    /** The user clicked a drawn button: its question becomes a typed follow-up turn. */
    click: function (id) {
      var m = card && card.byId[id];
      if (!m || m.__erased) return false;
      if (m.do === 'text' && m.link) { emit({ type: 'action', role: 'open', payload: m.link, mark: m.id, click: true }); return true; }
      if (m.do !== 'button') return false;
      var kind = m.action || 'ask';
      if (kind === 'ask' || kind === 'card') {
        var ev = { type: 'ask', text: String(m.ask || m.text || '') };
        if (kind === 'card') ev.card = true;
        emit(ev);
        return true;
      }
      emit({ type: 'action', role: kind, payload: m.value, mark: m.id, click: true });
      return true;
    },

    /** Hold the pen after the strokes already under way; program text keeps arriving. resume() carries on, with the
     * same pacing as if no time had passed. The painter pauses with it (DrawingPainter.pause). */
    pause: function () {
      if (!prog || prog.paused || prog.cancelled) return false;
      prog.paused = true;
      prog.pausedAt = clock();
      return true;
    },
    resume: function () {
      if (!prog || !prog.paused) return false;
      prog.pausedTotal += M.max(0, clock() - prog.pausedAt);
      prog.paused = false;
      pump();
      return true;
    },
    /** Seconds of drawing time spent paused so far (the painter subtracts the same). */
    pausedTotal: function () { return prog ? prog.pausedTotal + (prog.paused ? clock() - prog.pausedAt : 0) : 0; },

    /** For a voice that reports progress as a running count of words spoken (continuous narration) rather than line
     * by line: lines start and finish as the count passes them; their lengths come from the measured speaking rate. */
    spoken: function (count) {
      if (!prog || !isNum(count)) return false;
      var n = M.max(prog.spokenWords, M.floor(count)), now = clock();
      prog.spokenWords = n;
      prog.spokenRate.push([now, n]);
      if (prog.spokenRate.length > 12) prog.spokenRate.shift();
      var first = prog.spokenRate[0], rate = 2.6;
      if (now - first[0] > 0.6 && n - first[1] >= 2) rate = clamp((n - first[1]) / (now - first[0]), 1, 6);
      var start = 0;
      for (var k = 0; k < prog.sayQueue.length; k++) {
        var words = String(prog.sayQueue[k].text).split(/\s+/).filter(function (w) { return w.length; }).length;
        var end = start + words, lane = prog.lanes[k];
        if (n > start && !(lane && lane.started)) engine.lineStarted(k, M.max(0.4, words / rate));
        lane = prog.lanes[k];
        if (n >= end && lane && lane.started && !lane.finished) engine.lineFinished(k);
        start = end;
      }
      return true;
    },

    /** Keep this card for a follow-up turn: what was never drawn is dropped for good, and the card's code so far
     * (with a __turn marker) is returned, so replaying it whole draws the same card. Then begin({keep: true}). */
    continueTurn: function () {
      if (!prog || !card) return null;
      var dropped = [];
      for (var k in prog.lanes) { dropped = dropped.concat(prog.lanes[k].queue); prog.lanes[k].queue = []; }
      dropped = dropped.concat(prog.floating);
      prog.floating = [];
      var keep = card.marks.length;
      for (var i = 0; i < dropped.length; i++) {
        var m = dropped[i];
        if (m.__released) continue;
        m.__erased = true;
        m.__dropped = true;
        if (isNum(m.__seq) && m.__seq < keep) keep = m.__seq;
      }
      var turn = prog.turn + 1;
      var text = prog.splitter.slice(0, prog.cutAt >= 0 ? prog.cutAt : prog.splitter.text.length).replace(/\s+$/, '');
      card.code = (card.code ? card.code + '\n' : '') + text + '\n__turn(' + turn + ', ' + keep + ');';
      prog.inputDone = true; prog.ended = true; prog.finalized = true;
      return stringify({ turn: turn, keep: keep, firstLine: prog.sayQueue.length, marks: card.marks.length, dropped: dropped.length, code: card.code });
    },

    /** What the program noted for the host: a lesson's title, what it saw and noted about the user, its plan. */
    summary: function () {
      return stringify({ lessonTitle: card && card.lessonTitle || null, notes: prog ? prog.notes : [], actions: prog ? prog.actions : 0 });
    },

    /** The beat being heard, for the debug captions: which statements of the line are waiting, drawing or done. */
    beats: function () {
      if (!prog) return 'null';
      var t = drawNow(), current = null;
      for (var k in prog.lanes) {
        var l = prog.lanes[k];
        if (l.index >= 0 && l.started && (!current || l.index > current.index)) current = l;
      }
      if (!current) return 'null';
      var chips = [];
      for (var i = 0; i < card.parts.length; i++) {
        var p = card.parts[i];
        if (p.line !== current.index || p.turn !== prog.turn) continue;
        var state = 'waiting', late = false, end = 0, any = false;
        for (var j = 0; j < p.marks.length; j++) {
          var m = card.byId[p.marks[j]];
          if (!m || !m.__released) continue;
          any = true;
          end = M.max(end, num(m.base, 0) + num(m.start, 0) + num(m.duration, 0));
          if (current.dur != null && num(m.start, 0) + num(m.duration, 0) > current.dur + 0.15) late = true;
        }
        if (any) state = t < end ? 'drawing' : 'done';
        chips.push({ label: shortStatement(p.statement), state: state, late: late });
      }
      var known = prog.sayQueue[current.index];
      return stringify({
        line: current.index, of: prog.sayQueue.length, text: known ? known.text : '',
        elapsed: round(M.max(0, t - current.base), 2), length: current.dur != null ? round(current.dur, 2) : null, chips: chips
      });
    },

    /** The card as text, so a follow-up turn can edit parts by id. Optional {drawnOnly, maxChars}. */
    describe: describe,

    /** Cards on screen the user can drag or close, as JSON [{id, kind, box:[x,y,w,h], marks, title, has3D}]. */
    cardsJSON: function () { return stringify(cardsNow()); },

    /** The user dragged a card by dx, dy canvas units: its marks move at once. Returns JSON [dx, dy] as moved, or null. */
    moveCard: function (ids, dx, dy) { return stringify(moveCardNow(ids, +dx, +dy)); },

    /** The user closed a card: its marks (and a figure's parts) leave the screen at once. Returns how many marks went. */
    closeCard: function (ids) {
      if (!card) return 0;
      return dropNow(idList(ids).map(function (id) { return card.byId[id]; }));
    },

    /** What lies under the drawing has changed: marks on no card go, cards stay. Returns JSON {kept, dropped}. */
    dropScreenMarks: function () { return stringify(dropScreenMarksNow()); },

    /** The end-of-drawing report as JSON (off-canvas marks and overlapping words); [] before the drawing is done. */
    reportJSON: function () { return stringify(card && card.report ? card.report : []); },

    /** Spoken lines found so far, in SayLineExtractor's numbering. */
    lines: function () { return prog ? prog.sayQueue.map(function (s) { return s.text; }) : []; },

    registerModule: function (fn) {
      if (typeof fn !== 'function') throw new Error('registerModule needs a function(api, ctx)');
      modules.push(fn);
      fn(api, ctx);
      return true;
    },

    /** Call once the host has loaded every module: later program globals are cleaned up between drawings. */
    sealGlobals: function () {
      if (baselineGlobals) return true;
      // Program code runs with the global object in reach (`globalThis`, `this`, `Function('return this')()`), so
      // the host's functions and the engine's entry points leave it: otherwise a program could click its own
      // buttons (an `ask` becomes a typed turn), cancel itself, or feed the host made-up measurements.
      hostObject = global.__host || null;
      delete global.__host;
      delete global.__engine;
      lockIntrinsics();
      baselineGlobals = Object.create(null);
      var names = Object.getOwnPropertyNames(global);
      for (var i = 0; i < names.length; i++) baselineGlobals[names[i]] = true;
      return true;
    },

    // For tests and tools.
    _internals: { lex: lex, transform: transform, sayLiterals: sayLiterals, Splitter: Splitter, readable: readable, luminance: luminance, parseHex: parseHex }
  };

  installApi();
  newCard();
  // Configurable so sealGlobals() can take it off the global object once every plugin has registered.
  Object.defineProperty(global, '__engine', { value: engine, writable: false, enumerable: false, configurable: true });
})(this);
