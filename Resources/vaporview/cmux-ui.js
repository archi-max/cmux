// UI pieces VS Code draws around VaporView's webview, rebuilt in the host page
// for cmux: context menus (with VS Code's `when` clause rules), the input box,
// the quick pick, confirmation messages and toasts.
//
// Menu contents follow VaporView's package.json `contributes.menus`
// (https://github.com/Lramseyer/vaporview, GPL-3.0, @59107c6); see
// cmux-commands.js.
//
// window.cmuxUI:
//   evalWhen(expression, context)            VS Code context-key expression
//   buildMenu(entries, context, resolve)     -> visible items, grouped
//   showMenu(items, clientX, clientY)        items: [{label, run} | {label, items} | {separator}]
//   prompt({ title, value, placeholder })    -> Promise<string | undefined>
//   quickPick({ title, items: [{label, value}] }) -> Promise<value | undefined>
//   confirm({ message, detail, buttons: [{label, value}] }) -> Promise<value | undefined>
//   toast(message, kind)                     kind: 'info' | 'warning' | 'error'
//   modal((box, finish) => {...})            -> Promise of the value passed to finish
//   hasOpenOverlay()

(function () {
  // ---- when clauses ----
  // Supports the subset VaporView's package.json uses: identifiers, 'strings',
  // numbers, true/false, == != > >= < <=, !, &&, || and parentheses. Equality is
  // loose and ordering compares numbers, as in VS Code's context keys.
  function tokenize(source) {
    const tokens = [];
    let i = 0;
    while (i < source.length) {
      const c = source[i];
      if (/\s/.test(c)) { i++; continue; }
      const two = source.slice(i, i + 2);
      if (['==', '!=', '>=', '<=', '&&', '||'].includes(two)) { tokens.push({ op: two }); i += 2; continue; }
      if ('!()<>'.includes(c)) { tokens.push({ op: c }); i++; continue; }
      if (c === "'" || c === '"') {
        const end = source.indexOf(c, i + 1);
        tokens.push({ value: source.slice(i + 1, end < 0 ? source.length : end) });
        i = end < 0 ? source.length : end + 1;
        continue;
      }
      const m = /^[^\s!()<>=&|'"]+/.exec(source.slice(i));
      if (!m) { i++; continue; }
      const word = m[0];
      if (word === 'true' || word === 'false') { tokens.push({ value: word === 'true' }); }
      else if (/^-?\d+(\.\d+)?$/.test(word)) { tokens.push({ value: Number(word) }); }
      else { tokens.push({ key: word }); }
      i += word.length;
    }
    return tokens;
  }

  function evalWhen(expression, context) {
    if (!expression) { return true; }
    const tokens = tokenize(expression);
    let pos = 0;
    const peek = () => tokens[pos];
    const next = () => tokens[pos++];
    const operand = (t) => (t && 'key' in t ? context[t.key] : t ? t.value : undefined);

    function primary() {
      const t = next();
      if (!t) { return undefined; }
      if (t.op === '(') { const v = or(); if (peek() && peek().op === ')') { next(); } return v; }
      if (t.op === '!') { return !primary(); }
      return operand(t);
    }
    function comparison() {
      const left = primary();
      const t = peek();
      if (!t || !['==', '!=', '>', '>=', '<', '<='].includes(t.op)) { return left; }
      next();
      const right = primary();
      switch (t.op) {
        // eslint-disable-next-line eqeqeq
        case '==': return left == right;
        // eslint-disable-next-line eqeqeq
        case '!=': return left != right;
        case '>': return Number(left) > Number(right);
        case '>=': return Number(left) >= Number(right);
        case '<': return Number(left) < Number(right);
        case '<=': return Number(left) <= Number(right);
      }
      return false;
    }
    function and() {
      let v = comparison();
      while (peek() && peek().op === '&&') { next(); const r = comparison(); v = !!v && !!r; }
      return v;
    }
    function or() {
      let v = and();
      while (peek() && peek().op === '||') { next(); const r = and(); v = !!v || !!r; }
      return v;
    }
    return !!or();
  }

  // entries: [{ command | submenu, group, when }] as in package.json.
  // resolve(entry) -> { label, run } for a command or { label, entries } for a
  // submenu, or null to skip. Groups sort by name and `@order`; a separator
  // goes between groups, and an empty submenu is dropped, as in VS Code.
  function buildMenu(entries, context, resolve) {
    const groups = new Map();
    for (const entry of entries) {
      if (!evalWhen(entry.when, context)) { continue; }
      const resolved = resolve(entry);
      if (!resolved) { continue; }
      let item = resolved;
      if (resolved.entries) {
        const items = buildMenu(resolved.entries, context, resolve);
        if (!items.length) { continue; }
        item = { label: resolved.label, items };
      }
      const [groupName, order] = String(entry.group || '').split('@');
      if (!groups.has(groupName)) { groups.set(groupName, []); }
      groups.get(groupName).push({ item, order: Number(order) || 0 });
    }
    const names = [...groups.keys()].sort((a, b) => {
      // VS Code puts the 'navigation' group first and ungrouped items last.
      if (a === b) { return 0; }
      if (a === 'navigation') { return -1; }
      if (b === 'navigation') { return 1; }
      if (!a) { return 1; }
      if (!b) { return -1; }
      return a < b ? -1 : 1;
    });
    const out = [];
    for (const name of names) {
      const list = groups.get(name);
      list.sort((a, b) => a.order - b.order);
      if (out.length) { out.push({ separator: true }); }
      list.forEach((x) => out.push(x.item));
    }
    return out;
  }

  // ---- overlay plumbing ----
  let openMenus = [];
  let overlay = null;

  function layer() {
    if (!overlay) {
      overlay = document.createElement('div');
      overlay.id = 'cmux-overlay';
      document.body.appendChild(overlay);
    }
    return overlay;
  }

  // Tells cmux-commands.js that a menu or dialog opened or closed.
  function overlayChanged() { document.dispatchEvent(new Event('cmux-overlay-change')); }

  function closeMenus() {
    const hadMenus = openMenus.length > 0;
    openMenus.forEach((m) => m.remove());
    openMenus = [];
    if (hadMenus) { overlayChanged(); }
    document.removeEventListener('mousedown', onOutsideMouseDown, true);
    document.removeEventListener('keydown', onMenuKey, true);
  }

  function onOutsideMouseDown(e) {
    if (!openMenus.some((m) => m.contains(e.target))) { closeMenus(); }
  }

  function focusedMenu() {
    return openMenus[openMenus.length - 1];
  }

  function onMenuKey(e) {
    const menu = focusedMenu();
    if (!menu) { return; }
    const rows = [...menu.querySelectorAll('.cmux-menu-item')];
    const active = menu.querySelector('.cmux-menu-item.active');
    let index = rows.indexOf(active);
    if (e.key === 'Escape') {
      e.preventDefault(); e.stopPropagation();
      if (openMenus.length > 1) { openMenus.pop().remove(); } else { closeMenus(); }
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault(); e.stopPropagation();
      index = e.key === 'ArrowDown' ? (index + 1) % rows.length : (index - 1 + rows.length) % rows.length;
      rows.forEach((r) => r.classList.remove('active'));
      if (rows[index]) { rows[index].classList.add('active'); }
    } else if ((e.key === 'Enter' || e.key === 'ArrowRight' || e.key === ' ') && active) {
      e.preventDefault(); e.stopPropagation();
      active.dispatchEvent(new MouseEvent('click'));
    } else if (e.key === 'ArrowLeft' && openMenus.length > 1) {
      e.preventDefault(); e.stopPropagation();
      openMenus.pop().remove();
    }
  }

  function placeMenu(menu, x, y, avoidRect) {
    const vw = window.innerWidth, vh = window.innerHeight;
    const r = menu.getBoundingClientRect();
    let left = x, top = y;
    if (left + r.width > vw - 4) { left = avoidRect ? avoidRect.left - r.width : vw - r.width - 4; }
    if (top + r.height > vh - 4) { top = Math.max(4, vh - r.height - 4); }
    menu.style.left = Math.max(4, left) + 'px';
    menu.style.top = Math.max(4, top) + 'px';
  }

  function renderMenu(items, x, y, depth, avoidRect) {
    while (openMenus.length > depth) { openMenus.pop().remove(); }
    const menu = document.createElement('div');
    menu.className = 'cmux-menu';
    menu.setAttribute('role', 'menu');
    for (const item of items) {
      if (item.separator) {
        const sep = document.createElement('div');
        sep.className = 'cmux-menu-separator';
        menu.appendChild(sep);
        continue;
      }
      const row = document.createElement('div');
      row.className = 'cmux-menu-item' + (item.items ? ' has-submenu' : '') + (item.checked ? ' checked' : '');
      row.setAttribute('role', 'menuitem');
      const label = document.createElement('span');
      label.className = 'label';
      label.textContent = item.label;
      row.appendChild(label);
      if (item.keybinding) {
        const key = document.createElement('span');
        key.className = 'keybinding';
        key.textContent = item.keybinding;
        row.appendChild(key);
      }
      const openSubmenu = () => {
        const rect = row.getBoundingClientRect();
        renderMenu(item.items, rect.right - 2, rect.top - 4, depth + 1, rect);
      };
      row.addEventListener('mouseenter', () => {
        menu.querySelectorAll('.cmux-menu-item.active').forEach((r) => r.classList.remove('active'));
        row.classList.add('active');
        if (item.items) { openSubmenu(); } else { while (openMenus.length > depth + 1) { openMenus.pop().remove(); } }
      });
      row.addEventListener('click', (e) => {
        e.stopPropagation();
        if (item.items) { openSubmenu(); return; }
        closeMenus();
        try { item.run(); } catch (error) { toast(String((error && error.message) || error), 'error'); }
      });
      menu.appendChild(row);
    }
    layer().appendChild(menu);
    openMenus.push(menu);
    placeMenu(menu, x, y, avoidRect);
    return menu;
  }

  function showMenu(items, x, y) {
    closeMenus();
    if (!items.length) { return; }
    renderMenu(items, x, y, 0, null);
    overlayChanged();
    document.addEventListener('mousedown', onOutsideMouseDown, true);
    document.addEventListener('keydown', onMenuKey, true);
  }

  // ---- modal dialogs (input box, quick pick, message with buttons) ----
  let dialogCount = 0;

  function modal(build) {
    return new Promise((resolve) => {
      closeMenus();
      dialogCount++;
      overlayChanged();
      const backdrop = document.createElement('div');
      backdrop.className = 'cmux-dialog-backdrop';
      const box = document.createElement('div');
      box.className = 'cmux-dialog';
      backdrop.appendChild(box);
      let done = false;
      const finish = (value) => {
        if (done) { return; }
        done = true;
        dialogCount--;
        backdrop.remove();
        overlayChanged();
        resolve(value);
      };
      backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) { finish(undefined); } });
      backdrop.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(undefined); }
        // Keep typing in the dialog from reaching the viewer's key handlers.
        e.stopPropagation();
      });
      build(box, finish);
      layer().appendChild(backdrop);
      const focusTarget = box.querySelector('input, select, button');
      if (focusTarget) { focusTarget.focus(); if (focusTarget.select) { focusTarget.select(); } }
    });
  }

  function strings() { return (window.cmuxWaveform && window.cmuxWaveform.strings) || {}; }

  function prompt({ title, value, placeholder }) {
    return modal((box, finish) => {
      const label = document.createElement('div');
      label.className = 'cmux-dialog-title';
      label.textContent = title || '';
      const input = document.createElement('input');
      input.type = 'text';
      input.spellcheck = false;
      input.value = value || '';
      input.placeholder = placeholder || '';
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); finish(input.value); } });
      const buttons = document.createElement('div');
      buttons.className = 'cmux-dialog-buttons';
      buttons.append(button(strings().dialogCancel, () => finish(undefined)), button(strings().dialogOk, () => finish(input.value), true));
      box.append(label, input, buttons);
    });
  }

  function quickPick({ title, items }) {
    return modal((box, finish) => {
      const label = document.createElement('div');
      label.className = 'cmux-dialog-title';
      label.textContent = title || '';
      const list = document.createElement('div');
      list.className = 'cmux-quickpick';
      items.forEach((item, i) => {
        const row = document.createElement('button');
        row.className = 'cmux-quickpick-item';
        row.textContent = item.label;
        row.addEventListener('click', () => finish(item.value));
        row.addEventListener('keydown', (e) => {
          const rows = [...list.children];
          if (e.key === 'ArrowDown' && rows[i + 1]) { e.preventDefault(); rows[i + 1].focus(); }
          if (e.key === 'ArrowUp' && rows[i - 1]) { e.preventDefault(); rows[i - 1].focus(); }
        });
        list.appendChild(row);
      });
      box.append(label, list);
    });
  }

  function confirm({ message, detail, buttons }) {
    return modal((box, finish) => {
      const label = document.createElement('div');
      label.className = 'cmux-dialog-title';
      label.textContent = message || '';
      box.appendChild(label);
      if (detail) {
        const d = document.createElement('div');
        d.className = 'cmux-dialog-detail';
        d.textContent = detail;
        box.appendChild(d);
      }
      const row = document.createElement('div');
      row.className = 'cmux-dialog-buttons';
      buttons.forEach((b, i) => row.appendChild(button(b.label, () => finish(b.value), i === buttons.length - 1)));
      box.appendChild(row);
    });
  }

  function button(label, onClick, primary) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'cmux-button' + (primary ? ' primary' : '');
    b.textContent = label || '';
    b.addEventListener('click', onClick);
    return b;
  }

  function toast(message, kind) {
    const el = document.createElement('div');
    el.className = 'cmux-toast ' + (kind || 'info');
    el.textContent = message;
    el.setAttribute('role', 'status');
    layer().appendChild(el);
    setTimeout(() => el.classList.add('leaving'), 4000);
    setTimeout(() => el.remove(), 4400);
    el.addEventListener('click', () => el.remove());
  }

  window.cmuxUI = {
    evalWhen, buildMenu, showMenu, closeMenus, modal, prompt, quickPick, confirm, toast, button,
    hasOpenOverlay: () => openMenus.length > 0 || dialogCount > 0,
  };
})();
