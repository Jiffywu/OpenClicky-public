// OpenClicky page agent. Injected into a tab's top frame (extension isolated world) on first use; it stays until the
// document unloads, so element refs (e1, e2, …) remain stable for the life of the page. The service worker calls
// globalThis.__openclickyAgent.run(operation, args), which returns {result} or {error}.

(() => {
  if (globalThis.__openclickyAgent) return;

  const refs = new Map(); // ref -> WeakRef(Element)
  const refOf = new WeakMap(); // Element -> ref
  let nextRef = 1;
  // What the agent last saw: ref -> one-line summary. Actions answer with the difference from this.
  let lastSeen = null;
  const MAX_CHANGES = 30;
  const MAX_TABLES = 10;
  const MAX_ROWS = 60;

  const MAX_ELEMENTS = 250;
  const MAX_NAME = 100;
  const MAX_TYPE = 20000;

  const CANDIDATES = [
    "a[href]",
    "button",
    "input:not([type=hidden])",
    "select",
    "textarea",
    "summary",
    "[contenteditable='']",
    "[contenteditable='true']",
    "[onclick]",
    "[tabindex]:not([tabindex='-1'])",
    ...[
      "button", "link", "checkbox", "radio", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio",
      "option", "combobox", "textbox", "searchbox", "slider", "spinbutton", "treeitem", "listbox",
    ].map((role) => `[role='${role}']`),
  ].join(",");

  // ---- Helpers --------------------------------------------------------------------------------------------

  const clean = (text, limit = MAX_NAME) => {
    const flat = String(text ?? "").replace(/\s+/g, " ").trim();
    return flat.length > limit ? flat.slice(0, limit - 1) + "…" : flat;
  };

  function refFor(element) {
    let ref = refOf.get(element);
    if (!ref) {
      ref = `e${nextRef++}`;
      refOf.set(element, ref);
      refs.set(ref, new WeakRef(element));
    }
    return ref;
  }

  function lookup(ref) {
    const key = String(ref ?? "").replace(/^\[|\]$/g, "").trim();
    const element = refs.get(key)?.deref();
    if (!element || !element.isConnected) {
      throw new Error(`Ref ${key || "(none)"} is unknown or no longer on the page; read the page again for fresh refs.`);
    }
    return element;
  }

  /** Every element in the document, including inside open shadow roots, in document order. */
  function* allElements(root = document) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    let node = walker.nextNode();
    while (node) {
      yield node;
      if (node.shadowRoot) yield* allElements(node.shadowRoot);
      node = walker.nextNode();
    }
  }

  function isVisible(element) {
    if (typeof element.checkVisibility === "function" && !element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) {
      return false;
    }
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function inViewport(element) {
    const rect = element.getBoundingClientRect();
    return rect.bottom > 0 && rect.right > 0 && rect.top < innerHeight && rect.left < innerWidth;
  }

  function roleOf(element) {
    const explicit = element.getAttribute("role");
    if (explicit) return explicit.split(" ")[0];
    const tag = element.tagName.toLowerCase();
    if (tag === "a") return "link";
    if (tag === "button" || tag === "summary") return "button";
    if (tag === "select") return element.multiple ? "listbox" : "combobox";
    if (tag === "textarea") return "textbox";
    if (tag === "input") {
      const type = (element.getAttribute("type") || "text").toLowerCase();
      return (
        {
          button: "button", submit: "button", reset: "button", image: "button", checkbox: "checkbox", radio: "radio",
          range: "slider", number: "spinbutton", search: "searchbox", file: "file-input", color: "color-input",
        }[type] ?? "textbox"
      );
    }
    if (element.isContentEditable) return "textbox";
    return "clickable";
  }

  function textOfIds(ids) {
    return ids
      .split(/\s+/)
      .map((id) => document.getElementById(id)?.innerText ?? "")
      .join(" ");
  }

  /** A label's own words, without the text of controls nested inside it (a select's options, a button). */
  function labelText(label) {
    let text = "";
    const walk = (node) => {
      for (const child of node.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) text += child.textContent;
        else if (child.nodeType === Node.ELEMENT_NODE && !child.matches("input, select, textarea, button, [role=listbox], [role=combobox]")) {
          walk(child);
        }
      }
    };
    walk(label);
    return text;
  }

  function nameOf(element) {
    const labelledBy = element.getAttribute("aria-labelledby");
    if (labelledBy) {
      const text = clean(textOfIds(labelledBy));
      if (text) return text;
    }
    const aria = clean(element.getAttribute("aria-label"));
    if (aria) return aria;
    const tag = element.tagName.toLowerCase();
    if (["input", "select", "textarea"].includes(tag)) {
      const type = (element.getAttribute("type") || "").toLowerCase();
      if (["button", "submit", "reset"].includes(type) && element.value) return clean(element.value);
      const label = element.labels?.[0];
      if (label) {
        const text = clean(labelText(label));
        if (text) return text;
      }
      const hint = clean(element.getAttribute("placeholder") || element.getAttribute("title") || element.getAttribute("alt"));
      if (hint) return hint;
      return clean(element.getAttribute("name") || "");
    }
    const text = clean(element.innerText);
    if (text) return text;
    const image = element.querySelector?.("img[alt], svg[aria-label]");
    const alt = clean(image?.getAttribute("alt") || image?.getAttribute("aria-label"));
    if (alt) return alt;
    return clean(element.getAttribute("title") || "");
  }

  /** Password, one-time-code and payment fields are the user's to fill. */
  function isSensitive(element) {
    const type = (element.getAttribute?.("type") || "").toLowerCase();
    if (type === "password") return true;
    const autocomplete = (element.getAttribute?.("autocomplete") || "").toLowerCase();
    if (/one-time-code|cc-|current-password|new-password/.test(autocomplete)) return true;
    const hints = `${element.name || ""} ${element.id || ""} ${element.getAttribute?.("aria-label") || ""}`.toLowerCase();
    return /\b(cvv|cvc|otp|card.?number|security.?code|passcode)\b/.test(hints);
  }

  function describe(element) {
    return `[${refFor(element)}] ${roleOf(element)}${nameOf(element) ? ` "${nameOf(element)}"` : ""}`;
  }

  function entry(element) {
    const role = roleOf(element);
    const item = { ref: refFor(element), role, name: nameOf(element) };
    const tag = element.tagName.toLowerCase();
    if (tag === "a" && element.href) item.href = clean(element.href, 200);
    if (tag === "select") {
      if (isSensitive(element)) item.sensitive = true;
      item.value = clean(element.selectedOptions?.[0]?.text ?? "");
      item.options = Array.from(element.options)
        .slice(0, 25)
        .map((option) => clean(option.text, 60));
    } else if ((tag === "input" || tag === "textarea") && !["checkbox", "radio", "button", "submit", "reset"].includes(element.type)) {
      if (!isSensitive(element) && element.value) item.value = clean(element.value, 200);
      if (isSensitive(element)) item.sensitive = true;
    } else if (element.isContentEditable && tag !== "body") {
      item.value = clean(element.innerText, 200);
    }
    if (element.type === "checkbox" || element.type === "radio") item.checked = element.checked;
    else if (element.getAttribute("aria-checked")) item.checked = element.getAttribute("aria-checked") === "true";
    if (element.disabled || element.getAttribute("aria-disabled") === "true") item.disabled = true;
    if (!inViewport(element)) item.offscreen = true;
    return item;
  }

  function readableText(maxChars) {
    const main = document.querySelector("main, [role=main], article");
    let text = main && main.innerText.trim().length > 200 ? main.innerText : document.body?.innerText ?? "";
    text = text
      .split("\n")
      .map((line) => line.replace(/[ \t]+/g, " ").trim())
      .join("\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
    return text.length > maxChars ? { text: text.slice(0, maxChars), truncated: true } : { text, truncated: false };
  }

  function settle(quietMs = 300, maxMs = 3000) {
    return new Promise((resolve) => {
      let timer;
      const done = () => {
        observer.disconnect();
        clearTimeout(timer);
        clearTimeout(cap);
        resolve({});
      };
      const observer = new MutationObserver(() => {
        clearTimeout(timer);
        timer = setTimeout(done, quietMs);
      });
      observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
      timer = setTimeout(done, quietMs);
      const cap = setTimeout(done, maxMs);
    });
  }

  function ensureUsable(element) {
    if (element.disabled || element.getAttribute("aria-disabled") === "true") {
      throw new Error(`${describe(element)} is disabled.`);
    }
    element.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    if (!isVisible(element)) throw new Error(`${describe(element)} isn't visible; scroll or open the section that holds it.`);
  }

  function checkNotCovered(element) {
    const rect = element.getBoundingClientRect();
    const x = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;
    let hit = document.elementFromPoint(x, y);
    while (hit?.shadowRoot) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    if (!hit || hit === element || element.contains(hit) || hit.contains(element)) return;
    if (hit.closest?.("label") && element.labels && Array.from(element.labels).includes(hit.closest("label"))) return;
    const cover = hit.closest?.("[role=dialog], dialog, [aria-modal=true]") ?? hit;
    throw new Error(`${describe(element)} is covered by ${roleOf(cover)} "${clean(cover.innerText, 60)}". Close or dismiss it first.`);
  }

  function pointerSequence(element) {
    const rect = element.getBoundingClientRect();
    const init = { bubbles: true, cancelable: true, composed: true, clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2, button: 0, view: window };
    element.dispatchEvent(new PointerEvent("pointerover", init));
    element.dispatchEvent(new MouseEvent("mouseover", init));
    element.dispatchEvent(new PointerEvent("pointerdown", { ...init, isPrimary: true, pointerType: "mouse" }));
    element.dispatchEvent(new MouseEvent("mousedown", init));
    if (typeof element.focus === "function") element.focus({ preventScroll: true });
    element.dispatchEvent(new PointerEvent("pointerup", { ...init, isPrimary: true, pointerType: "mouse" }));
    element.dispatchEvent(new MouseEvent("mouseup", init));
  }

  const KEYS = {
    Enter: { code: "Enter", keyCode: 13 },
    Tab: { code: "Tab", keyCode: 9 },
    Escape: { code: "Escape", keyCode: 27 },
    Backspace: { code: "Backspace", keyCode: 8 },
    Delete: { code: "Delete", keyCode: 46 },
    ArrowUp: { code: "ArrowUp", keyCode: 38 },
    ArrowDown: { code: "ArrowDown", keyCode: 40 },
    ArrowLeft: { code: "ArrowLeft", keyCode: 37 },
    ArrowRight: { code: "ArrowRight", keyCode: 39 },
    PageUp: { code: "PageUp", keyCode: 33 },
    PageDown: { code: "PageDown", keyCode: 34 },
    Home: { code: "Home", keyCode: 36 },
    End: { code: "End", keyCode: 35 },
    Space: { code: "Space", keyCode: 32, key: " " },
  };

  function focusables() {
    return Array.from(allElements()).filter(
      (element) => element.matches?.("a[href], button, input:not([type=hidden]), select, textarea, [tabindex]:not([tabindex='-1']), [contenteditable='true']") &&
        !element.disabled && isVisible(element),
    );
  }

  /** Synthetic key events, plus the default action browsers would take for the keys pages rely on most. */
  function pressKey(target, key) {
    const info = KEYS[key];
    if (!info) throw new Error(`Unsupported key ${key}.`);
    const init = { key: info.key ?? key, code: info.code, keyCode: info.keyCode, which: info.keyCode, bubbles: true, cancelable: true, composed: true };
    const proceed = target.dispatchEvent(new KeyboardEvent("keydown", init));
    if (key === "Enter") target.dispatchEvent(new KeyboardEvent("keypress", { ...init, charCode: 13 }));
    target.dispatchEvent(new KeyboardEvent("keyup", init));
    if (!proceed) return "the page handled it";
    const tag = target.tagName?.toLowerCase();
    if (key === "Enter") {
      if (tag === "input" && target.form) {
        target.form.requestSubmit ? target.form.requestSubmit() : target.form.submit();
        return "submitted the form";
      }
      if (tag === "a" || tag === "button" || target.getAttribute?.("role") === "button") {
        target.click();
        return "activated it";
      }
    }
    if (key === "Space" && (tag === "button" || target.type === "checkbox")) {
      target.click();
      return "activated it";
    }
    if (key === "Tab") {
      const list = focusables();
      const next = list[(list.indexOf(target) + 1) % Math.max(list.length, 1)];
      next?.focus();
      return next ? `focus moved to ${describe(next)}` : "nothing else to focus";
    }
    const scrollKeys = { PageDown: innerHeight * 0.85, PageUp: -innerHeight * 0.85, ArrowDown: 60, ArrowUp: -60 };
    if (key in scrollKeys && (target === document.body || target === document.documentElement)) {
      scrollContainer().scrollBy({ top: scrollKeys[key], behavior: "instant" });
      return "scrolled";
    }
    if (key === "Home" || key === "End") {
      if (target === document.body || target === document.documentElement) {
        const box = scrollContainer();
        box.scrollTo({ top: key === "Home" ? 0 : box.scrollHeight, behavior: "instant" });
        return "scrolled";
      }
    }
    return "sent";
  }

  /** The element that scrolls the page: the document, or the largest scrollable box when the document can't. */
  function scrollContainer() {
    const root = document.scrollingElement ?? document.documentElement;
    if (root.scrollHeight > root.clientHeight + 4) return root;
    let best = root;
    let bestArea = 0;
    for (const element of document.querySelectorAll("body *")) {
      if (element.scrollHeight <= element.clientHeight + 4) continue;
      const overflow = getComputedStyle(element).overflowY;
      if (overflow !== "auto" && overflow !== "scroll") continue;
      const rect = element.getBoundingClientRect();
      const area = rect.width * rect.height;
      if (area > bestArea) {
        best = element;
        bestArea = area;
      }
    }
    return best;
  }

  function setFieldValue(element, value) {
    element.value = value;
    element.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: value }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  }

  /** The interactive elements a snapshot lists, as entries, in document order. */
  function visibleEntries() {
    const found = [];
    for (const element of allElements()) {
      if (!element.matches?.(CANDIDATES)) continue;
      if (element.closest?.("[aria-hidden=true], [inert]")) continue;
      if (!isVisible(element)) continue;
      found.push(element);
    }
    return found.map(entry);
  }

  const summaryOf = (item) => `${item.role}|${item.name}|${item.value ?? ""}|${item.checked ?? ""}|${item.disabled ?? ""}`;

  function remember(items) {
    lastSeen = new Map(items.map((item) => [item.ref, summaryOf(item)]));
  }

  /**
   * Elements added, removed and changed since the agent last looked. A ref that is still on the page but whose label,
   * value or state differs is "changed" (listed once, as it is now), not a removal plus an addition.
   */
  function changesSinceLastLook() {
    const items = visibleEntries();
    if (!lastSeen) {
      remember(items);
      return null;
    }
    const current = new Map(items.map((item) => [item.ref, item]));
    const added = items.filter((item) => !lastSeen.has(item.ref));
    const changed = items.filter((item) => lastSeen.has(item.ref) && lastSeen.get(item.ref) !== summaryOf(item));
    const removed = [];
    for (const [ref, summary] of lastSeen) {
      if (!current.has(ref)) {
        const [role, name] = summary.split("|");
        removed.push({ ref, role, name });
      }
    }
    remember(items);
    const omitted = [added, removed, changed].reduce((sum, list) => sum + Math.max(0, list.length - MAX_CHANGES), 0);
    return {
      added: added.slice(0, MAX_CHANGES),
      removed: removed.slice(0, MAX_CHANGES),
      changed: changed.slice(0, MAX_CHANGES),
      omitted,
    };
  }

  /** Sets a field's value through the element's own setter, so pages built on React and similar frameworks notice. */
  function setNativeValue(element, value) {
    const proto = element.tagName.toLowerCase() === "textarea" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
    if (setter) setter.call(element, value);
    else element.value = value;
    element.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: value }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  }

  const normalize = (text) => String(text ?? "").replace(/\s+/g, " ").trim();

  /** Fills a rich editor (contenteditable): insertText, then a synthetic paste, then plain text; checks it landed. */
  function fillEditable(element, value) {
    element.focus({ preventScroll: true });
    const landed = () => normalize(element.innerText).includes(normalize(value).slice(0, 200));
    const selectAll = () => {
      const range = document.createRange();
      range.selectNodeContents(element);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    };
    selectAll();
    if (document.execCommand("insertText", false, value) && landed()) return "typed";
    selectAll();
    try {
      const data = new DataTransfer();
      data.setData("text/plain", value);
      element.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true, composed: true }));
    } catch {}
    if (landed()) return "pasted";
    element.textContent = value;
    element.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: value }));
    if (landed()) return "set";
    throw new Error(`The editor ${describe(element)} didn't take the text; click it, then try type.`);
  }

  function pickOption(element, wanted) {
    const lower = wanted.toLowerCase();
    const options = Array.from(element.options);
    const option =
      options.find((o) => o.text.trim().toLowerCase() === lower) ??
      options.find((o) => o.value === wanted) ??
      options.find((o) => o.text.trim().toLowerCase().includes(lower));
    if (!option) {
      throw new Error(`No option matches "${wanted}". Options: ${options.slice(0, 25).map((o) => clean(o.text, 40)).join(" | ")}`);
    }
    if (option.disabled) throw new Error(`The option "${clean(option.text)}" is disabled.`);
    element.focus({ preventScroll: true });
    element.value = option.value;
    option.selected = true;
    element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
    return option;
  }

  function tablesOnPage() {
    const tables = [];
    for (const table of document.querySelectorAll("table")) {
      if (tables.length >= MAX_TABLES) break;
      if (!isVisible(table) || table.closest("[aria-hidden=true]")) continue;
      const rows = Array.from(table.rows);
      if (rows.length < 2) continue;
      tables.push({
        caption: clean(table.caption?.innerText ?? table.getAttribute("aria-label") ?? "", 120),
        rows: rows.slice(0, MAX_ROWS).map((row) => Array.from(row.cells).slice(0, 20).map((cell) => clean(cell.innerText, 120))),
        rowsOmitted: Math.max(0, rows.length - MAX_ROWS),
      });
    }
    return tables;
  }

  // ---- Operations -----------------------------------------------------------------------------------------

  const operations = {
    read({ query, maxChars, withText = true }) {
      const limit = Math.min(Math.max(Number(maxChars) || 6000, 500), 50000);
      const { text, truncated } = withText ? readableText(limit) : { text: "", truncated: false };
      const needle = String(query ?? "").trim().toLowerCase();
      const all = visibleEntries();
      // A filtered look doesn't replace what the agent saw of the whole page.
      if (!needle) remember(all);
      let items = all;
      if (needle) {
        items = items.filter((item) => `${item.name} ${item.value ?? ""} ${item.href ?? ""} ${item.role}`.toLowerCase().includes(needle));
      }
      // On-screen elements first, then the rest in document order.
      items.sort((a, b) => Number(Boolean(a.offscreen)) - Number(Boolean(b.offscreen)));
      const omitted = Math.max(0, items.length - MAX_ELEMENTS);
      const root = document.scrollingElement ?? document.documentElement;
      return {
        title: document.title,
        url: location.href,
        text: needle ? "" : text,
        textTruncated: needle ? false : truncated,
        elements: items.slice(0, MAX_ELEMENTS),
        elementsOmitted: omitted,
        scroll: { y: Math.round(root.scrollTop), height: root.scrollHeight, viewport: innerHeight },
      };
    },

    snapshot({ query }) {
      return operations.read({ query, withText: false });
    },

    extract({ maxChars }) {
      const limit = Math.min(Math.max(Number(maxChars) || 6000, 500), 50000);
      const { text, truncated } = readableText(limit);
      return { title: document.title, url: location.href, text, textTruncated: truncated, tables: tablesOnPage() };
    },

    changes() {
      return { changes: changesSinceLastLook() };
    },

    fill({ ref, text, submit = false }) {
      const element = lookup(ref);
      const value = String(text ?? "");
      if (value.length > MAX_TYPE) throw new Error(`Text is longer than ${MAX_TYPE} characters.`);
      if (isSensitive(element)) {
        throw new Error("OpenClicky doesn't fill password, one-time-code or payment fields. Ask the user to fill that in.");
      }
      ensureUsable(element);
      const tag = element.tagName.toLowerCase();
      const label = describe(element);
      if (tag === "select") {
        const option = pickOption(element, value.trim());
        return { note: `Chose "${clean(option.text)}" in ${label}.`, value: option.value };
      }
      let note;
      let final;
      if (element.isContentEditable) {
        const how = fillEditable(element, value);
        final = element.innerText;
        note = `Filled ${label} (rich editor, ${how}).`;
      } else if (tag === "input" || tag === "textarea") {
        if (["checkbox", "radio", "button", "submit", "reset", "file"].includes(element.type)) {
          throw new Error(`${describe(element)} isn't a text field; click it instead.`);
        }
        element.focus({ preventScroll: true });
        setNativeValue(element, value);
        final = element.value;
        note = `Filled ${label}.`;
        if (final !== value) note += " The field changed the text (it may format or limit input).";
      } else {
        throw new Error(`${describe(element)} isn't a text field, editor or list.`);
      }
      if (submit) note += ` Enter: ${pressKey(element, "Enter")}.`;
      return { note, value: clean(final, 200) };
    },

    click({ ref }) {
      const element = lookup(ref);
      ensureUsable(element);
      checkNotCovered(element);
      const label = describe(element);
      pointerSequence(element);
      element.click();
      return { note: `Clicked ${label}.` };
    },

    type({ ref, text, clear = true, submit = false }) {
      const element = lookup(ref);
      const value = String(text ?? "");
      if (value.length > MAX_TYPE) throw new Error(`Text is longer than ${MAX_TYPE} characters.`);
      if (isSensitive(element)) {
        throw new Error("OpenClicky doesn't type into password, one-time-code or payment fields. Ask the user to fill that in.");
      }
      ensureUsable(element);
      const tag = element.tagName.toLowerCase();
      if (tag === "select") throw new Error(`${describe(element)} is a list; use select.`);
      const editable = element.isContentEditable;
      if (!(tag === "input" || tag === "textarea" || editable)) throw new Error(`${describe(element)} isn't a text field.`);
      element.focus({ preventScroll: true });
      let final;
      if (editable) {
        if (clear) document.execCommand("selectAll", false);
        if (!document.execCommand("insertText", false, value)) {
          if (clear) element.textContent = value;
          else element.textContent += value;
          element.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: value }));
        }
        final = element.innerText;
      } else {
        setFieldValue(element, clear ? value : element.value + value);
        final = element.value;
      }
      const label = describe(element);
      let note = `Typed into ${label}.`;
      if (!editable && final !== (clear ? value : final)) note += " The field changed the text (it may format or limit input).";
      if (submit) note += ` Enter: ${pressKey(element, "Enter")}.`;
      return { note, value: clean(final, 200) };
    },

    select({ ref, value }) {
      const element = lookup(ref);
      if (isSensitive(element)) {
        throw new Error("OpenClicky doesn't choose payment details such as card expiry dates. Ask the user to fill that in.");
      }
      ensureUsable(element);
      if (element.tagName.toLowerCase() !== "select") {
        throw new Error(`${describe(element)} isn't a native list. Click it, read again, then click the option.`);
      }
      const wanted = String(value ?? "").trim();
      const lower = wanted.toLowerCase();
      const options = Array.from(element.options);
      const option =
        options.find((o) => o.value === wanted) ??
        options.find((o) => o.text.trim().toLowerCase() === lower) ??
        options.find((o) => o.text.trim().toLowerCase().includes(lower));
      if (!option) {
        throw new Error(`No option matches "${wanted}". Options: ${options.slice(0, 25).map((o) => clean(o.text, 40)).join(" | ")}`);
      }
      if (option.disabled) throw new Error(`The option "${clean(option.text)}" is disabled.`);
      element.focus({ preventScroll: true });
      element.value = option.value;
      option.selected = true;
      element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
      return { note: `Selected "${clean(option.text)}" in ${describe(element)}.`, value: option.value };
    },

    scroll({ ref, direction }) {
      if (ref) {
        const element = lookup(ref);
        element.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
        return { note: `Scrolled ${describe(element)} into view.` };
      }
      const box = scrollContainer();
      const step = Math.round((box === document.scrollingElement ? innerHeight : box.clientHeight) * 0.85);
      switch (direction) {
        case "up": box.scrollBy({ top: -step, behavior: "instant" }); break;
        case "down": box.scrollBy({ top: step, behavior: "instant" }); break;
        case "top": box.scrollTo({ top: 0, behavior: "instant" }); break;
        case "bottom": box.scrollTo({ top: box.scrollHeight, behavior: "instant" }); break;
        default: throw new Error("direction must be up, down, top or bottom.");
      }
      const atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 4;
      return {
        note: `Scrolled ${direction}${atEnd && direction !== "up" && direction !== "top" ? " (at the bottom)" : ""}.`,
        scrollY: Math.round(box.scrollTop),
        scrollHeight: box.scrollHeight,
      };
    },

    press({ key, ref }) {
      const target = ref ? lookup(ref) : document.activeElement ?? document.body;
      if (ref) {
        ensureUsable(target);
        target.focus({ preventScroll: true });
      }
      const outcome = pressKey(target, key);
      return { note: `Pressed ${key} on ${target === document.body ? "the page" : describe(target)}: ${outcome}.` };
    },

    settle() {
      return settle();
    },

    historyBack() {
      // Deferred so the result gets back to the extension before the page unloads.
      setTimeout(() => history.back(), 0);
      return {};
    },

    hasText({ text }) {
      const needle = String(text ?? "").toLowerCase();
      return { found: Boolean(needle) && (document.body?.innerText ?? "").toLowerCase().includes(needle) };
    },
  };

  globalThis.__openclickyAgent = {
    async run(operation, args) {
      try {
        const handler = operations[operation];
        if (!handler) return { error: `Unknown page operation ${operation}.` };
        return { result: await handler(args ?? {}) };
      } catch (error) {
        return { error: String(error?.message ?? error) };
      }
    },
  };
})();
