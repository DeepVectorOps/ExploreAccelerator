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
let selectedRoot = null;
let lastProjects = [];
let lastDef = null;
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

function expiryText(p) {
  if (typeof p.lifetimeError === 'string' && p.lifetimeError) return p.lifetimeError;
  if (!p.lifetimeSet) return 'Not set';
  return p.lifetimeSeconds + ' seconds (' + daysLabel(p.lifetimeSeconds) + ' days)';
}

function th(text, className) {
  const el = document.createElement('th');
  el.textContent = text;
  if (className) el.className = className;
  return el;
}

function td(text, className) {
  const el = document.createElement('td');
  if (text != null) el.textContent = text;
  if (className) el.className = className;
  return el;
}

function projectsEls() {
  let table = $('projects');
  let detail = $('project-detail');
  if (!table || table.tagName !== 'TABLE') {
    const next = document.createElement('table');
    next.id = 'projects';
    next.className = 'projects';
    detail = document.createElement('div');
    detail.id = 'project-detail';
    detail.className = 'detail';
    if (table) table.replaceWith(next, detail);
    else document.body.append(next, detail);
    table = next;
  } else if (!detail) {
    detail = document.createElement('div');
    detail.id = 'project-detail';
    detail.className = 'detail';
    table.after(detail);
  }
  if (!table.classList.contains('projects')) table.classList.add('projects');
  return {table, detail};
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
  const {table, detail} = projectsEls();
  table.replaceChildren();
  const cap = document.createElement('caption');
  cap.textContent = 'Scanning…';
  table.append(cap);
  const res = await fetch('/api/scan', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({roots})
  });
  const data = await res.json();
  const projects = data.projects || [];
  const found = projects.filter(p => p.found);
  if (selectedRoot && found.some(p => p.root === selectedRoot)) {
    /* keep */
  } else if (found.length === 1) {
    selectedRoot = found[0].root;
  } else {
    selectedRoot = null;
  }
  lastProjects = projects;
  lastDef = data.defaultLifetimeSeconds;
  renderProjects(table, detail, projects, lastDef);
}

function renderProjects(table, detail, projects, def) {
  table.replaceChildren();
  const head = document.createElement('thead');
  const hr = document.createElement('tr');
  hr.append(th('Project'), th('Files', 'num'), th('Size', 'num size'), th('Expiry'));
  head.append(hr);
  const body = document.createElement('tbody');
  projects.forEach(p => body.append(projectRow(p)));
  table.append(head, body);
  detail.replaceChildren();
  const selected = projects.find(p => p.found && p.root === selectedRoot);
  if (selected) detail.append(detailPanel(selected, def));
}

function projectRow(p) {
  const tr = document.createElement('tr');
  if (!p.found) {
    const cell = td((p.root || '(root)') + ': ' + (p.error || 'not found'));
    cell.colSpan = 1;
    cell.className = 'err';
    tr.append(cell, td(''), td(''), td(''));
    return tr;
  }
  tr.append(
    td(p.root),
    td(String(p.fileCount), 'num'),
    td(human(p.totalBytes), 'num size'),
    td(expiryText(p), (typeof p.lifetimeError === 'string' && p.lifetimeError) ? 'err' : '')
  );
  if (p.root === selectedRoot) tr.classList.add('selected');
  tr.classList.add('pick');
  tr.addEventListener('click', () => {
    selectedRoot = p.root;
    const {table, detail} = projectsEls();
    renderProjects(table, detail, lastProjects, lastDef);
  });
  return tr;
}

function detailPanel(p, def) {
  const wrap = document.createElement('div');
  wrap.append(expiryEditor(p, def), fileSplit(p), claimTable(p));
  return wrap;
}

function expiryEditor(p, def) {
  const wrap = document.createElement('div');
  wrap.className = 'row expiry';
  const label = document.createElement('label');
  label.textContent = 'Set expiry';
  const num = document.createElement('input');
  num.type = 'number';
  num.min = '1';
  num.value = p.lifetimeSet ? String(p.lifetimeSeconds) : String(def);
  label.htmlFor = 'expiry-amount';
  num.id = 'expiry-amount';
  const sel = document.createElement('select');
  ['seconds', 'days'].forEach(u => {
    const o = document.createElement('option');
    o.value = u;
    o.textContent = u;
    sel.append(o);
  });
  const err = document.createElement('span');
  err.className = 'err';
  const clearUnitError = () => {
    if (err.textContent === 'Not a whole number of days.' || err.textContent === 'Enter a positive whole number.') {
      err.textContent = '';
    }
  };
  sel.addEventListener('change', () => {
    const raw = num.value.trim();
    const n = Number(raw);
    const whole = raw !== '' && Number.isFinite(n) && Number.isInteger(n) && n > 0;
    if (sel.value === 'days') {
      if (whole && n % 86400 === 0) {
        num.value = String(n / 86400);
        clearUnitError();
      } else {
        num.value = '';
        err.textContent = 'Not a whole number of days.';
      }
    } else if (whole) {
      num.value = String(n * 86400);
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
      err.textContent = 'Enter a positive whole number.';
      return;
    }
    const res = await fetch('/api/lifetime', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({root: p.root, amount, unit: sel.value})
    });
    const data = await res.json();
    if (!res.ok) {
      err.textContent = data.error || 'save failed';
      return;
    }
    scan();
  });
  wrap.append(label, num, sel, saveBtn, err);
  return wrap;
}

function fileSplit(p) {
  const split = document.createElement('div');
  split.className = 'split';
  const table = document.createElement('table');
  table.className = 'files';
  const head = document.createElement('thead');
  const hr = document.createElement('tr');
  hr.append(th('File'), th('Size', 'num size'));
  head.append(hr);
  const body = document.createElement('tbody');
  const viewer = document.createElement('div');
  viewer.className = 'viewer';
  const empty = document.createElement('p');
  empty.className = 'meta';
  empty.textContent = 'Select a file.';
  viewer.append(empty);
  (p.files || []).forEach(f => {
    const tr = document.createElement('tr');
    tr.append(td(f.rel), td(human(f.bytes), 'num size'));
    tr.addEventListener('click', () => openFile(p, f, viewer, tr));
    body.append(tr);
  });
  table.append(head, body);
  split.append(table, viewer);
  return split;
}

async function openFile(p, f, view, row) {
  row.parentElement.querySelectorAll('tr').forEach(tr => tr.classList.remove('open'));
  row.classList.add('open');
  view.replaceChildren();
  const path = document.createElement('p');
  path.className = 'path';
  path.textContent = f.rel;
  view.append(path);
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

function claimTable(p) {
  const wrap = document.createElement('div');
  const table = document.createElement('table');
  table.className = 'claims';
  const head = document.createElement('thead');
  const hr = document.createElement('tr');
  hr.append(th('Run'), th('Claim'), th('Text'));
  head.append(hr);
  const body = document.createElement('tbody');
  const pre = document.createElement('pre');
  pre.className = 'check';
  (p.claims || []).forEach(c => {
    body.append(claimRow(p, c.name, c.name, '', pre));
    (c.claims || []).forEach(cl => {
      body.append(claimRow(p, c.name + '#' + cl.id, cl.id, cl.text || '', pre));
    });
  });
  table.append(head, body);
  wrap.append(table, pre);
  return wrap;
}

function claimRow(p, name, claim, text, pre) {
  const tr = document.createElement('tr');
  const runCell = document.createElement('td');
  const run = document.createElement('button');
  run.type = 'button';
  run.textContent = 'Run';
  run.addEventListener('click', () => runCheck(p, name, pre));
  runCell.append(run);
  tr.append(runCell, td(claim), td(text));
  return tr;
}

async function runCheck(p, name, pre) {
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
