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
let openSlug = null;
let openKind = null;
let noteSort = {key: 'note', dir: 1};
let claimScoresRoot = null;
let claimScores = new Map();
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

function noteSlug(rel) {
  if (typeof rel !== 'string' || !rel.startsWith('explore/')) return null;
  const name = rel.slice('explore/'.length);
  if (!name || name.includes('/') || !name.endsWith('.md') || name === '.md') return null;
  return name.slice(0, -'.md'.length);
}

function claimsByName(p) {
  const m = new Map();
  (p.claims || []).forEach(c => {
    if (c && typeof c.name === 'string') m.set(c.name, c);
  });
  return m;
}

function noteRows(p) {
  const byName = claimsByName(p);
  return (p.files || []).flatMap(f => {
    const slug = noteSlug(f.rel);
    if (!slug) return [];
    return [{slug, rel: f.rel, bytes: f.bytes, modified: f.modified, claims: byName.get(slug) || null}];
  });
}

function orphanClaims(p, notes) {
  const slugs = new Set(notes.map(n => n.slug));
  return (p.claims || []).filter(c => c && typeof c.name === 'string' && !slugs.has(c.name));
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
    openSlug = null;
    openKind = null;
    noteSort = {key: 'note', dir: 1};
    claimScoresRoot = null;
    claimScores = new Map();
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
      openSlug = null;
      openKind = null;
      noteSort = {key: 'note', dir: 1};
      claimScoresRoot = null;
      claimScores = new Map();
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
  const notes = sortNotes(noteRows(p));
  const orphans = orphanClaims(p, notes);
  const stillNote = openKind === 'note' && notes.some(n => n.slug === openSlug);
  const stillOrphan = openKind === 'orphan' && orphans.some(c => c.name === openSlug);
  if (!stillNote && !stillOrphan) {
    if (notes.length) {
      openSlug = notes[0].slug;
      openKind = 'note';
    } else {
      openSlug = null;
      openKind = null;
    }
  }
  box.append(workspaceBar(p, def), workspaceSplit(p, notes, orphans));
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

function sortNotes(notes) {
  const dir = noteSort.dir;
  const key = noteSort.key;
  return notes.slice().sort((a, b) => {
    let c = 0;
    if (key === 'size') c = (Number(a.bytes) || 0) - (Number(b.bytes) || 0);
    else if (key === 'modified') c = String(a.modified || '').localeCompare(String(b.modified || ''));
    else if (key === 'claims') c = String(a.claims ? a.slug + '.claims.jsonl' : '').localeCompare(String(b.claims ? b.slug + '.claims.jsonl' : ''));
    else c = String(a.slug || '').localeCompare(String(b.slug || ''));
    if (c === 0) c = String(a.slug || '').localeCompare(String(b.slug || ''));
    return c * dir;
  });
}

function workspaceSplit(p, notes, orphans) {
  const split = document.createElement('div');
  split.className = 'split';
  split.append(notesPane(p, notes, orphans), detailPane(p, notes, orphans));
  return split;
}

function pctText(score) {
  if (!score) return null;
  if (score.total === 0 || score.pct == null) return {text: '—', className: ''};
  let className = 'pct-bad';
  if (score.pct > 75) className = 'pct-good';
  else if (score.pct >= 50) className = 'pct-mid';
  return {text: score.pct + '%', className};
}

function scoreFor(p, name) {
  if (!p || p.root !== claimScoresRoot || typeof name !== 'string') return null;
  return claimScores.get(name) || null;
}

function notesPane(p, notes, orphans) {
  const pane = document.createElement('div');
  pane.className = 'notes';
  const bar = document.createElement('div');
  bar.className = 'run-all';
  const runAllBtn = document.createElement('button');
  runAllBtn.type = 'button';
  runAllBtn.textContent = 'Run all';
  const runAllErr = document.createElement('span');
  runAllErr.className = 'err';
  runAllBtn.addEventListener('click', () => runAll(p, runAllBtn, runAllErr));
  bar.append(runAllBtn, runAllErr);
  const scroll = document.createElement('div');
  scroll.className = 'note-scroll';
  const table = document.createElement('table');
  table.className = 'notes-table';
  const head = document.createElement('thead');
  const hr = document.createElement('tr');
  const cols = [
    ['Note', 'note', ''],
    ['Size', 'size', 'num size'],
    ['Modified', 'modified', 'num modified'],
    ['Claims file', 'claims', ''],
    ['%', null, 'num']
  ];
  cols.forEach(([label, key, className]) => {
    const el = th(label, className);
    if (key) {
      el.addEventListener('click', () => {
        if (noteSort.key === key) noteSort.dir = -noteSort.dir;
        else noteSort = {key, dir: 1};
        renderWorkspace(p, lastDef);
      });
    }
    hr.append(el);
  });
  head.append(hr);
  const body = document.createElement('tbody');
  notes.forEach(n => {
    const tr = document.createElement('tr');
    const noteCell = td(n.slug);
    noteCell.title = n.rel;
    const claimsCell = td(n.claims ? n.slug + '.claims.jsonl' : '');
    const shown = n.claims ? pctText(scoreFor(p, n.slug)) : null;
    tr.append(noteCell, td(human(n.bytes), 'num size'), modifiedCell(n.modified), claimsCell, td(shown ? shown.text : '', shown ? shown.className : ''));
    if (openKind === 'note' && openSlug === n.slug) tr.classList.add('open');
    tr.addEventListener('click', () => {
      openSlug = n.slug;
      openKind = 'note';
      renderWorkspace(p, lastDef);
    });
    body.append(tr);
  });
  table.append(head, body);
  scroll.append(table);
  pane.append(bar, scroll);
  if (orphans.length) {
    const sec = document.createElement('section');
    sec.className = 'orphans';
    const h = document.createElement('p');
    h.className = 'label';
    h.textContent = 'Claims with no note';
    sec.append(h);
    orphans.forEach(c => {
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'orphan';
      if (openKind === 'orphan' && openSlug === c.name) row.classList.add('open');
      row.append(document.createTextNode(c.name + '.claims.jsonl'));
      const shown = pctText(scoreFor(p, c.name));
      if (shown) {
        const mark = document.createElement('span');
        mark.textContent = ' ' + shown.text;
        if (shown.className) mark.className = shown.className;
        row.append(mark);
      }
      row.addEventListener('click', () => {
        openSlug = c.name;
    sec.append(h);
    orphans.forEach(c => {
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'orphan';
      if (openKind === 'orphan' && openSlug === c.name) row.classList.add('open');
      row.textContent = c.name + '.claims.jsonl';
      row.addEventListener('click', () => {
        openSlug = c.name;
        openKind = 'orphan';
        renderWorkspace(p, lastDef);
      });
      sec.append(row);
    });
    pane.append(sec);
  }
  return pane;
}

function detailPane(p, notes, orphans) {
  const detail = document.createElement('div');
  detail.className = 'detail';
  const viewer = document.createElement('div');
  viewer.className = 'viewer';
  const claims = document.createElement('div');
  claims.className = 'note-claims';
  detail.append(viewer, claims);
  if (openKind === 'note') {
    const note = notes.find(n => n.slug === openSlug);
    if (note) fillNote(p, note, viewer, claims);
    else viewer.append(viewerMsg('Select a note.'));
  } else if (openKind === 'orphan') {
    const claim = orphans.find(c => c.name === openSlug);
    viewer.append(viewerMsg('No note for this claims file.'));
    if (claim) fillClaims(p, claim, claims);
  } else {
    viewer.append(viewerMsg('Select a note.'));
  }
  return detail;
}

function viewerMsg(text) {
  const empty = document.createElement('p');
  empty.className = 'meta';
  empty.textContent = text;
  return empty;
}

function fillNote(p, note, viewer, claims) {
  const title = document.createElement('p');
  title.className = 'path';
  title.textContent = note.slug;
  viewer.append(title);
  const body = document.createElement('div');
  body.className = 'md';
  viewer.append(body);
  fetch('/api/file?root=' + encodeURIComponent(p.root) + '&rel=' + encodeURIComponent(note.rel))
    .then(async res => {
      if (!res.ok) {
        const data = await res.json();
        body.replaceWith(errLine(data.error || 'read failed'));
        return;
      }
      const text = await res.text();
      body.innerHTML = marked.parse(text);
    })
    .catch(() => {
      body.replaceWith(errLine('read failed'));
    });
  if (note.claims) fillClaims(p, note.claims, claims);
  else claims.append(viewerMsg('No claims file for this note.'));
}

function errLine(text) {
  const e = document.createElement('p');
  e.className = 'err';
  e.textContent = text;
  return e;
}

function fillClaims(p, claimFile, pane) {
  const heading = document.createElement('p');
  heading.className = 'path';
  heading.textContent = 'explore/claims/' + claimFile.name + '.claims.jsonl';
  const table = document.createElement('table');
  const head = document.createElement('thead');
  const hr = document.createElement('tr');
  hr.append(th('Run'), th('Id'), th('Text'));
  head.append(hr);
  const body = document.createElement('tbody');
  const pre = document.createElement('pre');
  pre.className = 'check';
  body.append(claimRow(p, claimFile.name, claimFile.name, '', pre));
  (claimFile.claims || []).forEach(cl => {
    body.append(claimRow(p, claimFile.name + '#' + cl.id, cl.id, cl.text || '', pre));
  });
  table.append(head, body);
  pane.append(heading, table, pre);
}

function claimRow(p, name, id, text, pre) {
  const tr = document.createElement('tr');
  const runCell = document.createElement('td');
  const run = document.createElement('button');
  run.type = 'button';
  run.textContent = 'Run';
  run.addEventListener('click', () => runCheck(p, name, pre));
  runCell.append(run);
  tr.append(runCell, td(id), td(text));
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

async function runAll(p, btn, err) {
  btn.disabled = true;
  btn.textContent = 'Running…';
  err.textContent = '';
  try {
    const res = await fetch('/api/check-all', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({root: p.root})
    });
    const data = await res.json();
    if (!res.ok) {
      err.textContent = data.error || 'check failed';
      btn.disabled = false;
      btn.textContent = 'Run all';
      return;
    }
    claimScores = new Map();
    (data.files || []).forEach(f => {
      if (f && typeof f.name === 'string') claimScores.set(f.name, f);
    });
    claimScoresRoot = p.root;
    renderWorkspace(p, lastDef);
  } catch (e) {
    err.textContent = 'check failed';
    btn.disabled = false;
    btn.textContent = 'Run all';
  }
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
