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
let openRel = null;
let fileSort = {key: 'name', dir: 1};
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

function shortTime(iso) {
  if (typeof iso !== 'string' || !iso) return '';
  return iso.slice(0, 16).replace('T', ' ');
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

function modifiedCell(iso) {
  const el = td(shortTime(iso), 'num modified');
  if (typeof iso === 'string' && iso) el.title = iso;
  return el;
}

function renderRoots() {
  const ul = $('root-list');
  ul.replaceChildren();
  roots.forEach((p, i) => {
    const li = document.createElement('li');
    li.className = 'dir';
    const span = document.createElement('span');
    span.className = 'dir-path';
    span.textContent = p;
    span.title = p;
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
  const projects = data.projects || [];
  const found = projects.filter(p => p.found);
  if (!(selectedRoot && found.some(p => p.root === selectedRoot))) {
    openRel = null;
    fileSort = {key: 'name', dir: 1};
    selectedRoot = found.length === 1 ? found[0].root : null;
  }
  lastProjects = projects;
  lastDef = data.defaultLifetimeSeconds;
  renderProjects(projects, lastDef);
}

function renderProjects(projects, def) {
  const box = $('projects');
  box.replaceChildren();
  const table = document.createElement('table');
  table.className = 'projects';
  const head = document.createElement('thead');
  const hr = document.createElement('tr');
  hr.append(th('Project'), th('Files', 'num'), th('Size', 'num size'), th('Modified', 'num modified'), th('Expiry'));
  head.append(hr);
  const body = document.createElement('tbody');
  projects.forEach(p => body.append(projectRow(p)));
  table.append(head, body);
  box.append(table);
  const selected = projects.find(p => p.found && p.root === selectedRoot) || null;
  renderWorkspace(selected, def);
}

function projectRow(p) {
  const tr = document.createElement('tr');
  if (!p.found) {
    const cell = td((p.error || 'not found'), 'err');
    tr.append(cell, td(''), td(''), td(''), td(''));
    return tr;
  }
  tr.append(
    td(p.root),
    td(String(p.fileCount), 'num'),
    td(human(p.totalBytes), 'num size'),
    modifiedCell(p.modified),
    td(expiryText(p), (typeof p.lifetimeError === 'string' && p.lifetimeError) ? 'err' : '')
  );
  if (p.root === selectedRoot) tr.classList.add('selected');
  tr.classList.add('pick');
  tr.addEventListener('click', () => {
    if (selectedRoot !== p.root) {
      openRel = null;
      fileSort = {key: 'name', dir: 1};
    }
    selectedRoot = p.root;
    renderProjects(lastProjects, lastDef);
  });
  return tr;
}

function renderWorkspace(p, def) {
  const box = $('workspace');
  box.replaceChildren();
  if (!p) {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'Select a project.';
    box.append(empty);
    return;
  }
  if (openRel && !(p.files || []).some(f => f.rel === openRel)) openRel = null;
  box.append(workspaceBar(p, def), fileSplit(p), claimPane(p));
}

function workspaceBar(p, def) {
  const wrap = document.createElement('div');
  wrap.className = 'ws-bar';
  const path = document.createElement('span');
  path.className = 'livedocs';
  path.textContent = p.liveDocs || '';
  path.title = p.liveDocs || '';
  const editor = document.createElement('div');
  editor.className = 'expiry-wrap';
  const row = document.createElement('div');
  row.className = 'row';
  const label = document.createElement('label');
  label.textContent = 'Expiry';
  label.htmlFor = 'expiry-amount';
  const num = document.createElement('input');
  num.type = 'number';
  num.min = '1';
  num.id = 'expiry-amount';
  num.value = p.lifetimeSet ? String(p.lifetimeSeconds) : String(def);
  const sel = document.createElement('select');
  ['seconds', 'days'].forEach(u => {
    const o = document.createElement('option');
    o.value = u;
    o.textContent = u;
    sel.append(o);
  });
  const err = document.createElement('div');
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
  row.append(label, num, sel, saveBtn);
  editor.append(row, err);
  wrap.append(path, editor);
  return wrap;
}

function sortFiles(files) {
  const dir = fileSort.dir;
  const key = fileSort.key;
  return files.slice().sort((a, b) => {
    let c = 0;
    if (key === 'size') c = (Number(a.bytes) || 0) - (Number(b.bytes) || 0);
    else if (key === 'modified') c = String(a.modified || '').localeCompare(String(b.modified || ''));
    else c = String(a.rel || '').localeCompare(String(b.rel || ''));
    return c * dir;
  });
}

function fileSplit(p) {
  const split = document.createElement('div');
  split.className = 'split';
  const scroll = document.createElement('div');
  scroll.className = 'file-scroll';
  const table = document.createElement('table');
  table.className = 'files';
  const head = document.createElement('thead');
  const hr = document.createElement('tr');
  const nameTh = th('Name');
  const sizeTh = th('Size', 'num size');
  const modTh = th('Modified', 'num modified');
  const bindSort = (el, key) => {
    el.addEventListener('click', () => {
      if (fileSort.key === key) fileSort.dir = -fileSort.dir;
      else fileSort = {key, dir: 1};
      renderWorkspace(p, lastDef);
    });
  };
  bindSort(nameTh, 'name');
  bindSort(sizeTh, 'size');
  bindSort(modTh, 'modified');
  hr.append(nameTh, sizeTh, modTh);
  head.append(hr);
  const body = document.createElement('tbody');
  const viewer = document.createElement('div');
  viewer.className = 'viewer';
  sortFiles(p.files || []).forEach(f => {
    const tr = document.createElement('tr');
    tr.append(td(f.rel), td(human(f.bytes), 'num size'), modifiedCell(f.modified));
    if (f.rel === openRel) tr.classList.add('open');
    tr.addEventListener('click', () => openFile(p, f, viewer, tr));
    body.append(tr);
  });
  table.append(head, body);
  scroll.append(table);
  if (!openRel) {
    const empty = document.createElement('p');
    empty.className = 'meta';
    empty.textContent = 'Select a file.';
    viewer.append(empty);
  }
  split.append(scroll, viewer);
  if (openRel) {
    const f = (p.files || []).find(x => x.rel === openRel);
    const row = body.querySelector('tr.open');
    if (f && row) openFile(p, f, viewer, row);
  }
  return split;
}

async function openFile(p, f, view, row) {
  openRel = f.rel;
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

function claimPane(p) {
  const pane = document.createElement('div');
  pane.className = 'claims';
  const table = document.createElement('table');
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
  pane.append(table, pre);
  return pane;
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
