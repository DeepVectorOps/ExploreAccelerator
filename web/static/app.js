const KEY = 'live-docs-explorer-roots';
const load = () => {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) || '[]');
    return Array.isArray(v) ? v.filter(x => typeof x === 'string' && x) : [];
  } catch (e) {
    return [];
  }
};
const save = xs => localStorage.setItem(KEY, JSON.stringify(xs));
let roots = load();
const $ = id => document.getElementById(id);

function human(n) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, x = Number(n) || 0;
  while (x >= 1024 && i < u.length - 1) {
    x /= 1024;
    i++;
  }
  return (i === 0 ? String(Math.round(x)) : x.toFixed(1)) + ' ' + u[i];
}

function daysLabel(sec) {
  const d = sec / 86400;
  return Number.isInteger(d) ? String(d) : d.toFixed(2);
}

function renderRoots() {
  const ul = $('root-list');
  ul.replaceChildren();
  roots.forEach((p, i) => {
    const li = document.createElement('li');
    li.className = 'row';
    const span = document.createElement('span');
    span.textContent = p;
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = 'Remove';
    b.addEventListener('click', () => {
      roots = roots.filter((_, j) => j !== i);
      save(roots);
      renderRoots();
      scan();
    });
    li.append(span, b);
    ul.append(li);
  });
}

async function scan() {
  const box = $('projects');
  box.textContent = 'Scanning…';
  const res = await fetch('/api/scan', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({roots})
  });
  const data = await res.json();
  box.replaceChildren();
  const def = data.defaultLifetimeSeconds;
  (data.projects || []).forEach(p => box.append(card(p, def)));
}

function card(p, def) {
  const el = document.createElement('article');
  el.className = 'card';
  if (!p.found) {
    const h = document.createElement('h2');
    h.textContent = p.root || '(root)';
    const e = document.createElement('p');
    e.className = 'err';
    e.textContent = p.error || 'not found';
    el.append(h, e);
    return el;
  }
  const h = document.createElement('h2');
  h.textContent = p.root;
  const path = document.createElement('p');
  path.className = 'meta';
  path.textContent = p.liveDocs;
  const counts = document.createElement('p');
  counts.className = 'meta';
  counts.textContent = p.fileCount + ' files, ' + human(p.totalBytes);
  el.append(h, path, counts, lifetimeControl(p, def), fileList(p), claimList(p));
  const view = document.createElement('div');
  const result = document.createElement('pre');
  result.hidden = true;
  el.append(view, result);
  el._view = view;
  el._result = result;
  return el;
}

function lifetimeControl(p, def) {
  const wrap = document.createElement('div');
  wrap.className = 'row';
  const label = document.createElement('span');
  label.className = 'meta';
  if (typeof p.lifetimeError === 'string' && p.lifetimeError) {
    label.textContent = p.lifetimeError;
    label.className = 'err';
  } else if (!p.lifetimeSet) {
    label.textContent = 'Not set. Script default ' + def + ' seconds (' + daysLabel(def) + ' days).';
  } else {
    label.textContent = p.lifetimeSeconds + ' seconds (' + daysLabel(p.lifetimeSeconds) + ' days).';
  }
  const num = document.createElement('input');
  num.type = 'number';
  num.min = '1';
  num.value = p.lifetimeSet ? String(p.lifetimeSeconds) : String(def);
  const sel = document.createElement('select');
  ['seconds', 'days'].forEach(u => {
    const o = document.createElement('option');
    o.value = u;
    o.textContent = u;
    sel.append(o);
  });
  const clearUnitError = () => {
    if (label.textContent === 'Not a whole number of days.' || label.textContent === 'Enter a positive whole number.') {
      label.textContent = '';
    }
  };
  sel.addEventListener('change', () => {
    const raw = num.value.trim();
    const n = Number(raw);
    const whole = raw !== '' && Number.isFinite(n) && Number.isInteger(n) && n > 0;
    if (sel.value === 'days') {
      if (whole && n % 86400 === 0) {
        num.value = String(n / 86400);
        label.className = 'meta';
        clearUnitError();
      } else {
        num.value = '';
        label.textContent = 'Not a whole number of days.';
        label.className = 'err';
      }
    } else if (whole) {
      num.value = String(n * 86400);
      label.className = 'meta';
      clearUnitError();
    } else {
      num.value = '';
    }
  });
  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.textContent = 'Save';
  saveBtn.addEventListener('click', async () => {
    const raw = num.value.trim();
    const amount = Number(raw);
    if (raw === '' || !Number.isFinite(amount) || !Number.isInteger(amount) || amount <= 0) {
      label.textContent = 'Enter a positive whole number.';
      label.className = 'err';
      return;
    }
    const res = await fetch('/api/lifetime', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({root: p.root, amount, unit: sel.value})
    });
    const data = await res.json();
    if (!res.ok) {
      label.textContent = data.error || 'save failed';
      label.className = 'err';
      return;
    }
    scan();
  });
  wrap.append(label, num, sel, saveBtn);
  return wrap;
}

function fileList(p) {
  const ul = document.createElement('ul');
  ul.className = 'files';
  (p.files || []).forEach(f => {
    const li = document.createElement('li');
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = f.rel + ' (' + human(f.bytes) + ')';
    b.addEventListener('click', () => openFile(p, f, b.closest('article')));
    li.append(b);
    ul.append(li);
  });
  return ul;
}

async function openFile(p, f, card) {
  const view = card._view;
  view.replaceChildren();
  const res = await fetch('/api/file?root=' + encodeURIComponent(p.root) + '&rel=' + encodeURIComponent(f.rel));
  if (!res.ok) {
    const data = await res.json();
    const e = document.createElement('p');
    e.className = 'err';
    e.textContent = data.error || 'read failed';
    view.append(e);
    return;
  }
  const text = await res.text();
  if (f.markdown && window.marked && typeof marked.parse === 'function') {
    const d = document.createElement('div');
    d.className = 'md';
    d.innerHTML = marked.parse(text);
    view.append(d);
  } else {
    const pre = document.createElement('pre');
    pre.textContent = text;
    view.append(pre);
  }
}

function claimList(p) {
  const ul = document.createElement('ul');
  ul.className = 'claims';
  (p.claims || []).forEach(c => {
    const li = document.createElement('li');
    const run = document.createElement('button');
    run.type = 'button';
    run.textContent = 'Run';
    run.addEventListener('click', () => runCheck(p, c.name, run.closest('article')));
    const name = document.createElement('strong');
    name.textContent = ' ' + c.name;
    li.append(run, name);
    const sub = document.createElement('ul');
    (c.claims || []).forEach(cl => {
      const sli = document.createElement('li');
      const rb = document.createElement('button');
      rb.type = 'button';
      rb.textContent = 'Run';
      rb.addEventListener('click', () => runCheck(p, c.name + '#' + cl.id, rb.closest('article')));
      const t = document.createElement('span');
      t.textContent = ' ' + cl.id + ' ' + (cl.text || '');
      sli.append(rb, t);
      sub.append(sli);
    });
    li.append(sub);
    ul.append(li);
  });
  return ul;
}

async function runCheck(p, name, card) {
  const pre = card._result;
  pre.hidden = false;
  pre.textContent = 'Running…';
  const res = await fetch('/api/check', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({root: p.root, name})
  });
  const data = await res.json();
  pre.textContent = data.text || data.error || '';
}

$('add-root').addEventListener('click', () => {
  const v = $('root-input').value.trim();
  if (!v || roots.includes(v)) return;
  roots.push(v);
  save(roots);
  $('root-input').value = '';
  renderRoots();
  scan();
});
renderRoots();
scan();
