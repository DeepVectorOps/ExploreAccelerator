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
  const toggle = $('dir-toggle');
  toggle.textContent = roots.length ? 'Directories (' + roots.length + ')' : 'Add directory';
}

function setDirPanel(open) {
  const panel = document.querySelector('.dir-panel');
  const toggle = $('dir-toggle');
  panel.hidden = !open;
  toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
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
  const key = noteSort.key === 'claims' ? 'note' : noteSort.key;
  return notes.slice().sort((a, b) => {
    let c = 0;
    if (key === 'size') c = (Number(a.bytes) || 0) - (Number(b.bytes) || 0);
    else if (key === 'modified') c = String(a.modified || '').localeCompare(String(b.modified || ''));
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
  const sortKey = noteSort.key === 'claims' ? 'note' : noteSort.key;
  const sortSel = document.createElement('select');
  sortSel.setAttribute('aria-label', 'Sort notes');
  [['note', 'Note'], ['size', 'Size'], ['modified', 'Modified']].forEach(([value, label]) => {
    const opt = document.createElement('option');
    opt.value = value;
    opt.textContent = label;
    if (value === sortKey) opt.selected = true;
    sortSel.append(opt);
  });
  sortSel.addEventListener('change', () => {
    noteSort = {key: sortSel.value, dir: noteSort.dir};
    renderWorkspace(p, lastDef);
  });
  const dirBtn = document.createElement('button');
  dirBtn.type = 'button';
  dirBtn.textContent = sortKey === 'note'
    ? (noteSort.dir < 0 ? 'Z-A' : 'A-Z')
    : (noteSort.dir < 0 ? '↓' : '↑');
  dirBtn.addEventListener('click', () => {
    noteSort = {key: sortKey, dir: -noteSort.dir};
    renderWorkspace(p, lastDef);
  });
  bar.append(runAllBtn, sortSel, dirBtn, runAllErr);
  const scroll = document.createElement('div');
  scroll.className = 'note-scroll';
  notes.forEach(n => {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'note-row';
    if (openKind === 'note' && openSlug === n.slug) row.classList.add('open');
    const slug = document.createElement('span');
    slug.className = 'note-slug';
    slug.textContent = n.slug;
    slug.title = n.rel;
    const meta = document.createElement('span');
    meta.className = 'note-meta';
    meta.append(document.createTextNode(human(n.bytes) + ' · ' + shortTime(n.modified)));
    if (n.modified) meta.title = n.modified;
    const shown = n.claims ? pctText(scoreFor(p, n.slug)) : null;
    if (shown) {
      meta.append(document.createTextNode(' · '));
      const mark = document.createElement('span');
      mark.textContent = shown.text;
      if (shown.className) mark.className = shown.className;
      meta.append(mark);
    }
    row.append(slug, meta);
    row.addEventListener('click', () => {
      openSlug = n.slug;
      openKind = 'note';
      renderWorkspace(p, lastDef);
    });
    scroll.append(row);
  });
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
      const name = document.createElement('span');
      name.className = 'orphan-name';
      name.textContent = c.name + '.claims.jsonl';
      name.title = c.name + '.claims.jsonl';
      row.append(name);
      const shown = pctText(scoreFor(p, c.name));
      if (shown) {
        const mark = document.createElement('span');
        mark.textContent = shown.text;
        if (shown.className) mark.className = shown.className;
        row.append(mark);
      }
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
  body.append(claimRow(p, claimFile.name, claimFile.name, ''));
  (claimFile.claims || []).forEach(cl => {
    body.append(claimRow(p, claimFile.name + '#' + cl.id, cl.id, cl.text || ''));
  });
  table.append(head, body);
  pane.append(heading, table);
}

function claimRow(p, name, id, text) {
  const tr = document.createElement('tr');
  const runCell = document.createElement('td');
  const run = document.createElement('button');
  run.type = 'button';
  run.textContent = 'Run';
  run.addEventListener('click', () => runCheck(p, name));
  runCell.append(run);
  tr.append(runCell, td(id), td(text));
  return tr;
}

let checkDialog = null;

function openCheckDialog(name) {
  if (!checkDialog) {
    checkDialog = document.createElement('dialog');
    checkDialog.className = 'check-dialog';
    const header = document.createElement('div');
    header.className = 'check-head';
    const title = document.createElement('h2');
    const close = document.createElement('button');
    close.type = 'button';
    close.textContent = 'Close';
    close.addEventListener('click', () => checkDialog.close());
    header.append(title, close);
    const pre = document.createElement('pre');
    checkDialog.append(header, pre);
    // A click on the backdrop lands on the dialog element itself.
    checkDialog.addEventListener('click', ev => {
      if (ev.target === checkDialog) checkDialog.close();
    });
    document.body.append(checkDialog);
  }
  checkDialog.querySelector('h2').textContent = name;
  const pre = checkDialog.querySelector('pre');
  pre.textContent = 'Running…';
  if (!checkDialog.open) checkDialog.showModal();
  return pre;
}

let checkSeq = 0;

async function runCheck(p, name) {
  const pre = openCheckDialog(name);
  const seq = ++checkSeq;
  try {
    const res = await fetch('/api/check', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({root: p.root, name})
    });
    const data = await res.json();
    if (seq === checkSeq) pre.textContent = data.text || data.error || '';
  } catch (e) {
    if (seq === checkSeq) pre.textContent = 'check failed';
  }
}

let runAllDialog = null;

// Columns of the Run all table: header, sort key and cell text.
const runAllColumns = [
  {label: 'File', key: r => r.name},
  {label: 'Score %', key: r => (r.data && r.data.pct != null ? r.data.pct : Infinity)},
  {label: 'True', key: r => (r.data ? r.data.true : -1)},
  {label: 'False', key: r => (r.data ? r.data.false : -1)},
  {label: 'Drifted', key: r => (r.data ? r.data.drifted : -1)},
  {label: 'Total', key: r => (r.data ? r.data.total : -1)}
];
let runAllRows = [];
let runAllSort = null;

function sortRunAllRows() {
  const tbody = runAllDialog.querySelector('tbody');
  const rows = runAllRows.slice();
  if (runAllSort) {
    const key = runAllColumns[runAllSort.col].key;
    rows.sort((x, y) => {
      const a = key(x), b = key(y);
      const c = a < b ? -1 : a > b ? 1 : x.index - y.index;
      return runAllSort.asc ? c : -c;
    });
  }
  runAllDialog.querySelectorAll('thead th').forEach((th, i) => {
    th.setAttribute('aria-sort', runAllSort && runAllSort.col === i ? (runAllSort.asc ? 'ascending' : 'descending') : 'none');
  });
  tbody.replaceChildren(...rows.map(r => r.tr));
}

function openRunAllDialog(names) {
  if (!runAllDialog) {
    runAllDialog = document.createElement('dialog');
    runAllDialog.className = 'check-dialog run-all-dialog';
    const header = document.createElement('div');
    header.className = 'check-head';
    const title = document.createElement('h2');
    title.textContent = 'Run all';
    const close = document.createElement('button');
    close.type = 'button';
    close.textContent = 'Close';
    close.addEventListener('click', () => runAllDialog.close());
    header.append(title, close);
    const summary = document.createElement('div');
    summary.className = 'run-all-summary';
    const wrap = document.createElement('div');
    wrap.className = 'run-all-table';
    const table = document.createElement('table');
    const head = document.createElement('tr');
    runAllColumns.forEach((c, i) => {
      const th = document.createElement('th');
      th.textContent = c.label;
      th.title = 'Sort by ' + c.label;
      th.addEventListener('click', () => {
        runAllSort = {col: i, asc: runAllSort && runAllSort.col === i ? !runAllSort.asc : true};
        sortRunAllRows();
      });
      head.append(th);
    });
    const thead = document.createElement('thead');
    thead.append(head);
    table.append(thead, document.createElement('tbody'));
    wrap.append(table);
    runAllDialog.append(header, summary, wrap);
    runAllDialog.addEventListener('click', ev => {
      if (ev.target === runAllDialog) runAllDialog.close();
    });
    document.body.append(runAllDialog);
  }
  runAllSort = null;
  const rows = new Map();
  runAllRows = names.map((name, index) => {
    const tr = document.createElement('tr');
    const cells = runAllColumns.map(() => document.createElement('td'));
    cells[0].textContent = name;
    const spinner = document.createElement('span');
    spinner.className = 'spinner';
    spinner.setAttribute('aria-label', 'Running');
    cells[1].append(spinner);
    tr.append(...cells);
    const row = {name, index, tr, cells, data: null};
    rows.set(name, row);
    return row;
  });
  sortRunAllRows();
  if (!runAllDialog.open) runAllDialog.showModal();
  return rows;
}

function renderRunAllSummary(tally, total) {
  const box = runAllDialog.querySelector('.run-all-summary');
  box.replaceChildren();
  const num = n => n.toLocaleString('en-US');
  const share = n => (tally.claims ? ' (' + Math.round(100 * n / tally.claims) + '%)' : '');
  const line = (label, parts) => {
    const p = document.createElement('p');
    const head = document.createElement('strong');
    head.textContent = label + ':';
    p.append(head);
    parts.forEach((part, i) => {
      p.append(document.createTextNode(i ? ' · ' : ' '));
      const span = document.createElement('span');
      span.textContent = part[0];
      if (part[1]) span.className = part[1];
      p.append(span);
    });
    return p;
  };
  const done = tally.good + tally.mid + tally.bad + tally.none + tally.failed;
  const claims = [
    [num(tally.claims) + ' total'],
    [num(tally.true) + ' true' + share(tally.true), 'pct-good'],
    [num(tally.false) + ' false' + share(tally.false), 'pct-bad'],
    [num(tally.drifted) + ' drifted' + share(tally.drifted), 'drifted']
  ];
  // Thresholds match pctText: green > 75%, orange 50–75%, red < 50%.
  const files = [
    [done < total ? 'Checking ' + num(done) + ' / ' + num(total) + ' files…' : num(total)],
    [num(tally.good) + ' green (>75%)', 'pct-good'],
    [num(tally.mid) + ' orange (50–75%)', 'pct-mid'],
    [num(tally.bad) + ' red (<50%)', 'pct-bad'],
    [num(tally.driftedFiles) + ' with drifted claims', 'drifted']
  ];
  if (tally.none) files.push([num(tally.none) + ' no claims']);
  if (tally.failed) files.push([num(tally.failed) + ' failed', 'pct-bad']);
  box.append(line('Claims', claims), line('Files', files));
}

let runAllSeq = 0;

async function runAll(p, btn, err) {
  const seq = ++runAllSeq;
  const names = (p.claims || []).filter(c => c && typeof c.name === 'string').map(c => c.name);
  btn.disabled = true;
  btn.textContent = 'Running…';
  err.textContent = '';
  const rows = openRunAllDialog(names);
  const tally = {good: 0, mid: 0, bad: 0, none: 0, failed: 0,
    claims: 0, true: 0, false: 0, drifted: 0, driftedFiles: 0};
  const scores = new Map();
  renderRunAllSummary(tally, names.length);
  const checkOne = async name => {
    let data = null;
    try {
      const res = await fetch('/api/check-file', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({root: p.root, name})
      });
      const body = await res.json();
      data = res.ok ? body : {error: body.error || 'check failed'};
    } catch (e) {
      data = {error: 'check failed'};
    }
    if (seq !== runAllSeq) return;
    const row = rows.get(name);
    const [, status, trueCell, falseCell, driftedCell, totalCell] = row.cells;
    if (data.error) {
      tally.failed++;
      status.textContent = data.error;
      status.className = 'pct-bad';
    } else {
      row.data = data;
      scores.set(name, data);
      const pct = pctText(data);
      status.textContent = pct.text;
      status.className = pct.className;
      trueCell.textContent = data.true;
      falseCell.textContent = data.false;
      driftedCell.textContent = data.drifted;
      if (data.drifted) driftedCell.className = 'drifted';
      totalCell.textContent = data.total;
      tally.claims += data.total;
      tally.true += data.true;
      tally.false += data.false;
      tally.drifted += data.drifted;
      if (data.drifted) tally.driftedFiles++;
      if (pct.className === 'pct-good') tally.good++;
      else if (pct.className === 'pct-mid') tally.mid++;
      else if (pct.className === 'pct-bad') tally.bad++;
      else tally.none++;
    }
    renderRunAllSummary(tally, names.length);
  };
  const queue = names.slice();
  const worker = async () => {
    while (queue.length && seq === runAllSeq) await checkOne(queue.shift());
  };
  await Promise.all(Array.from({length: Math.min(4, names.length)}, worker));
  if (seq !== runAllSeq) return;
  if (!runAllSort) {
    runAllSort = {col: 1, asc: true};
    sortRunAllRows();
  }
  claimScores = scores;
  claimScoresRoot = p.root;
  renderWorkspace(p, lastDef);
}

$('dir-toggle').addEventListener('click', () => {
  setDirPanel($('dir-toggle').getAttribute('aria-expanded') !== 'true');
});
document.addEventListener('click', ev => {
  const panel = document.querySelector('.dir-panel');
  const toggle = $('dir-toggle');
  if (panel.hidden) return;
  if (panel.contains(ev.target) || toggle.contains(ev.target)) return;
  setDirPanel(false);
});
document.addEventListener('keydown', ev => {
  if (ev.key === 'Escape' && !(checkDialog && checkDialog.open) && !(runAllDialog && runAllDialog.open)) setDirPanel(false);
});
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
