/*
 * OpenClicky media pieces: real photos, place cards, stock cards and site icons inside a drawing (docs/dsl-media.md).
 *
 * Each piece pushes one card mark in a "loading" state and asks the host for its data with ctx.request(). The request
 * leaves the engine as soon as the statement runs, so the host looks the thing up while the voice is still talking;
 * when the answer arrives the host calls __engine.patch(ref, fields) and the card is repainted in place.
 *
 * The host does every lookup (image search with its public-host and people guards, MapKit, market data). Nothing
 * here touches the network; a program only names what it wants to show.
 */
__engine.registerModule(function (api, ctx) {
  'use strict';

  var U = ctx.util;
  var M = Math;
  var isNum = U.isNum, num = U.num, isObj = U.isObj, pt = U.pt;
  var MAX_REQUESTS = 12;
  var RANGES = { '1d': 1, '5d': 1, '1m': 1, '3m': 1, '1y': 1 };
  var requests = 0;
  // Pages and image addresses this drawing has already shown: each is used once (a second photo from the same article
  // would only repeat its preview picture).
  var pages = {};

  ctx.onBegin(function (canvas, keep) { if (!keep) { requests = 0; pages = {}; } });
  function pageKey(url) { return String(url).replace(/#.*$/, '').replace(/\/+$/, '').toLowerCase(); }

  function opts(o) { return isObj(o) ? o : {}; }
  function words(v, max) { return v == null ? '' : String(v).replace(/\s+/g, ' ').trim().slice(0, max || 200); }
  function numbers(name, values) {
    for (var i = 0; i < values.length; i++) if (!isNum(values[i])) { ctx.warn(name + '() needs numbers for its position and size'); return false; }
    return true;
  }
  // Each media piece costs a lookup; a card that asks for dozens would only slow the answer down.
  function budget(name) {
    if (requests >= MAX_REQUESTS) { ctx.warn('a drawing shows at most ' + MAX_REQUESTS + ' photos and cards; ' + name + '() was skipped'); return false; }
    requests++;
    return true;
  }
  // A card box: sized within the canvas, moved off other labelled cards, kept on screen.
  function cardBox(x, y, w, h, label, o, minW, minH) {
    var c = ctx.canvas;
    w = U.clamp(M.abs(w), minW, M.max(minW, c.width - 8));
    h = U.clamp(M.abs(h), minH, M.max(minH, c.height - 8));
    var r = U.placeContainer({ x: x, y: y, w: w, h: h }, label, o);
    return U.keepOnCanvas(r);
  }
  function finish(m, r, label, dur) {
    m.at = [r.x, r.y]; m.w = r.w; m.h = r.h;
    m.state = 'loading';
    m.__box = r; m.__layout = 'container'; m.__label = String(label || m.do).slice(0, 24);
    m.__dur = dur; m.__adv = dur * 0.7;
    return m;
  }
  function out(m) {
    var h = U.handle(m);
    h.box = [m.at[0], m.at[1], m.w, m.h];
    return h;
  }
  // "https://www.example.com/a?b" → "example.com"; refuses anything that isn't a plain host name.
  function hostOf(text) {
    var s = words(text, 300).toLowerCase().replace(/^[a-z][a-z0-9+.-]*:\/\//, '').replace(/[\/?#].*$/, '').replace(/:\d+$/, '').replace(/^www\./, '');
    return /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(s) ? s : '';
  }
  function looksLikeURL(s) { return /^https?:\/\//i.test(s); }

  // ---------------------------------------------------------------------------------------------------------------
  // photo(x, y, w, h, "Golden Gate Bridge", "caption", {tilt, web, page, people, subtitle})

  api.photo = function (x, y, w, h, query, caption, o) {
    if (isObj(query)) { o = query; query = o.query; caption = o.caption; }
    else if (isObj(caption)) { o = caption; caption = o.caption; }
    o = opts(o);
    if (!numbers('photo', [x, y, w, h])) return null;
    var q = words(query, 160), page = words(o.page, 600);
    if (looksLikeURL(q) && !page) { page = q; q = words(caption, 160); }
    if (!q && !page) { ctx.warn('photo() needs what to show, like photo(x, y, 260, 200, "Golden Gate Bridge")'); return null; }
    if (page && pages[pageKey(page)]) {
      // Same page once: a second print from it searches by name instead, or is skipped when there is no name.
      ctx.warn('each page is shown once per drawing; this photo() ' + (q ? 'looks "' + q + '" up instead' : 'was skipped'));
      if (!q) return null;
      page = '';
    }
    if (!budget('photo')) return null;
    if (page) pages[pageKey(page)] = true;
    // The host's photo query grammar (docs/lookups.md): [nopeople:] name | web: words | page: url :: name.
    var grammar = page ? 'page: ' + page + ' :: ' + q : o.web ? 'web: ' + q : q;
    if (o.people === false || o.noPeople === true) grammar = 'nopeople: ' + grammar;
    var r = cardBox(x, y, w, h, caption || q, o, pt(60), pt(60));
    var m = U.newMark('photo', o, grammar);
    finish(m, r, caption || q, 0.5);
    m.query = grammar;
    m.caption = words(caption, 80);
    if (o.subtitle) m.subtitle = words(o.subtitle, 100);
    m.tilt = U.clamp(num(o.tilt, -2), -12, 12);
    m.text = m.caption || q;
    ctx.push(m);
    ctx.request(m, { kind: 'photo', query: grammar });
    return out(m);
  };

  // ---------------------------------------------------------------------------------------------------------------
  // image(x, y, w, h, "https://…/picture.jpg", {radius, alt}): a picture from a direct address, shown as it is (no
  // print, no caption). The host downloads it with the same guards as photos: public https hosts only, capped size.

  api.image = function (x, y, w, h, url, o) {
    if (isObj(url)) { o = url; url = o.url || o.src; }
    o = opts(o);
    if (!numbers('image', [x, y, w, h])) return null;
    var address = words(url, 1000);
    if (!/^https:\/\/[^\s\/]+\.[^\s]+/i.test(address)) {
      ctx.warn('image() needs a direct https address of a picture; use photo() to find one by name');
      return null;
    }
    if (pages[pageKey(address)]) { ctx.warn('each picture is shown once per drawing; this image() was skipped'); return null; }
    if (!budget('image')) return null;
    pages[pageKey(address)] = true;
    var alt = words(o.alt, 80);
    var r = cardBox(x, y, w, h, alt || 'image', o, pt(24), pt(24));
    var m = U.newMark('image', o, address);
    finish(m, r, alt || 'image', 0.45);
    m.url = address;
    m.radius = U.clamp(num(o.radius, pt(8)), 0, M.min(r.w, r.h) / 2);
    m.text = alt || hostOf(address) || 'image';
    ctx.push(m);
    ctx.request(m, { kind: 'image', url: address });
    return out(m);
  };

  // ---------------------------------------------------------------------------------------------------------------
  // place(x, y, w, "Blue Bottle Coffee, Oakland", {near: [lat, lon], h})

  api.place = function (x, y, w, query, o) {
    if (isObj(query)) { o = query; query = o.query; }
    o = opts(o);
    if (!numbers('place', [x, y, w])) return null;
    var q = words(query, 160);
    if (!q) { ctx.warn('place() needs a place to look up, like place(x, y, 300, "Ferry Building, San Francisco")'); return null; }
    if (!budget('place')) return null;
    var h = isNum(o.h) ? o.h : M.abs(w) * 0.68;
    var r = cardBox(x, y, w, h, q, o, pt(160), pt(120));
    var m = U.newMark('place', o, q);
    finish(m, r, q, 0.5);
    m.query = q;
    m.text = q;
    m.__ground = '#FFFFFF';
    var payload = { kind: 'place', query: q };
    var near = o.near;
    if (Array.isArray(near) && near.length >= 2 && isNum(near[0]) && isNum(near[1]) && M.abs(near[0]) <= 90 && M.abs(near[1]) <= 180) {
      payload.near = [near[0], near[1]];
    }
    ctx.push(m);
    ctx.request(m, payload);
    return out(m);
  };

  // ---------------------------------------------------------------------------------------------------------------
  // stock(x, y, w, "AAPL", {range: "1d" | "5d" | "1m" | "3m" | "1y", h})

  api.stock = function (x, y, w, symbol, o) {
    if (isObj(symbol)) { o = symbol; symbol = o.symbol; }
    o = opts(o);
    if (!numbers('stock', [x, y, w])) return null;
    var s = words(symbol, 20).toUpperCase().replace(/^\$/, '');
    if (!/^[A-Z0-9][A-Z0-9.:=^\/-]{0,14}$/.test(s)) { ctx.warn('stock() needs a ticker symbol like "AAPL"'); return null; }
    if (!budget('stock')) return null;
    var range = typeof o.range === 'string' && RANGES[o.range.toLowerCase()] ? o.range.toLowerCase() : '1d';
    var h = isNum(o.h) ? o.h : M.abs(w) * 0.56;
    var r = cardBox(x, y, w, h, s, o, pt(170), pt(96));
    var m = U.newMark('stock', o, s);
    finish(m, r, s, 0.45);
    m.symbol = s;
    m.range = range;
    m.text = s;
    m.__ground = '#FFFFFF';
    ctx.push(m);
    ctx.request(m, { kind: 'stock', symbol: s, range: range });
    return out(m);
  };

  // ---------------------------------------------------------------------------------------------------------------
  // favicon(x, y, "wikipedia.org", {size}) and source(x, y, "wikipedia.org", "Wikipedia", {size})

  function icon(name, x, y, host, o) {
    var site = hostOf(host);
    if (!site) { ctx.warn(name + '() needs a site like "wikipedia.org"'); return null; }
    if (!budget(name)) return null;
    var size = U.clamp(num(o.size, pt(18)), pt(10), pt(64));
    var r = { x: x, y: y, w: size, h: size };
    var m = U.newMark('favicon', o, site);
    m.at = [r.x, r.y]; m.w = size; m.h = size;
    m.state = 'loading';
    m.host = site;
    m.text = site;
    m.__box = r; m.__layout = 'shape';
    m.__dur = 0.25; m.__adv = 0.12;
    ctx.push(m);
    ctx.request(m, { kind: 'favicon', host: site });
    return m;
  }

  api.favicon = function (x, y, host, o) {
    o = opts(o);
    if (!numbers('favicon', [x, y])) return null;
    var m = icon('favicon', x, y, host, o);
    return m ? out(m) : null;
  };

  api.source = function (x, y, host, name, o) {
    if (isObj(name)) { o = name; name = null; }
    o = opts(o);
    if (!numbers('source', [x, y])) return null;
    var m = icon('source', x, y, host, o);
    if (!m) return null;
    var label = words(name, 80) || m.host;
    var size = num(o.textSize, M.max(pt(12), m.h * 0.8));
    var t = U.drawText(x + m.w + pt(6), y + m.h / 2, label, { size: size, style: 'ui', tone: o.tone || 'grey', valign: 'middle', place: false }, 'piece');
    var h = out(m);
    if (t) { h.w = t.right - x; h.right = t.right; h.cx = x + h.w / 2; }
    return h;
  };

  // ---------------------------------------------------------------------------------------------------------------
  // When the host's answer arrives, keep the words the brain reads on follow-up turns (the card's state text) true.

  function money(v, currency) {
    if (!isNum(v)) return '';
    var digits = M.abs(v) >= 1000 ? 0 : 2;
    var s = v.toFixed(digits);
    return currency === 'USD' || !currency ? '$' + s : s + ' ' + currency;
  }

  ctx.onPatch(function (m, f) {
    if (m.state === 'failed') { m.text = (m.caption || m.query || m.symbol || m.host || m.do) + ' (not found)'; return; }
    if (m.state !== 'ready') return;
    switch (m.do) {
      case 'photo':
        m.text = m.caption || words(m.title, 80) || m.text;
        break;
      case 'image':
        break;
      case 'place':
        m.text = [words(m.title, 80), words(m.address, 120)].filter(function (s) { return s; }).join(', ') || m.text;
        break;
      case 'stock':
        var pct = isNum(m.changePercent) ? ' (' + (m.changePercent >= 0 ? '+' : '') + m.changePercent.toFixed(2) + '%)' : '';
        m.text = m.symbol + ' ' + money(m.price, m.currency) + pct;
        break;
    }
  });
});
