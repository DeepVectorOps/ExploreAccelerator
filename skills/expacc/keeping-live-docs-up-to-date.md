# Keeping live-docs up to date

A doc in `live-docs/explore/` is only as good as its claims. Code moves, so claims go FALSE over time. Most of that is harmless: the lines a claim quotes are still there, just at other line numbers. `expacc fix-line-shift` clears those, so the FALSE claims left are the ones that need reading.

Run everything from the root of the repo the claims describe.

## 1. Clear the line shifts

```
expacc fix-line-shift --dry-run
expacc fix-line-shift
```

- With no NAME it covers every claims file. `fix-line-shift NAME...` takes `other` or `other#id`. It does not follow `depends`.
- It fixes a claim only when the same lines sit at other line numbers:
  - `rg -n` output: `expect` gets the new numbers.
  - `sed -n 'A,Bp' FILE` as the whole command: the range in `cmd` moves to where the expected lines now are. They must occur exactly once in the file.
- `text` is never changed. Every other claim is left as it is.
- Each fixed claim prints one row per line, `path  OLD -> NEW  text` (the path is always shown; for single-file `rg` output it comes from the command, or reads `(file unknown: ...)` when the command names no single file). Then a per-file line map that merges every moved line of every fixed claim, then one summary line:

```
shifted auth-flow#login-handler  by +8
output (command output was transformed: one row per line, path  old -> new line number):
    src/auth.js  42 -> 50  export function login(req) {

line map (every line of the drifted claims above, merged per file; old -> new):
  src/auth.js
    offsets (listed lines only): lines 42-44: +8, lines 120-131: +15
     42 -> 50     +8  auth-flow#login-handler
    ...
Only the lines listed are known. ...

1 shifted claims fixed, 2 still false, 19 true
```

- `--moved-lines-jsonl` (also on `check`) prints instead one JSON object per line: `{"path", "old", "new", "claim", "text"}`, `path` null when unknown.

## 2. Fix line numbers in the prose

`fix-line-shift` updates the claims only (`expect`, or the range in a `sed` `cmd`). It does not update the note, or the line numbers written inside a claim's `text`. Fix those yourself, as a join, not a guess:

1. Get the map: `expacc fix-line-shift --dry-run --moved-lines-jsonl` (run it before the real fix; afterwards nothing is drifted). Or read the per-file line map.
2. For each citation in the note or in a claim's `text` (`src/auth.js:42`), look up that exact path and old line. Found: use its `new`.
3. Not found: the line is unknown. It may have moved by another offset or changed, even when it sits between two listed lines with the same offset. Re-grep it (`rg -n 'its text' PATH`) and cite what that prints. Never interpolate from the offsets.
4. A range such as `155-163` moves only when both ends are in the map and both moved by the same amount: `155 -> 162` and `163 -> 170` means the range is now `162-170`. Otherwise re-grep for it.
5. If the map lists a line with `CONFLICT` (two claims disagree), re-grep it too.

## 3. Read what is still FALSE

```
expacc check NAME... --print-all
```

These changed in content, so each needs a decision:

- The statement still holds: `expacc record-fix NAME ID`.
- The statement is wrong now: reword `text` or drop the claim, and fix the doc.
- Most of a doc is wrong: `expacc prune --dry-run --delete-if-inaccurate RATIO` lists docs worth deleting.

Never `record-fix` a shifted `sed -n` claim: that stores whatever lines are at the old range now. Use `fix-line-shift`.

## Finding claims

Claims files are JSONL, so `jq` into `rg` finds every claim that touches a file or symbol:

```
jq -r 'select(.id) | "\(input_filename)#\(.id)\t\(.text)\t\(.cmd)"' live-docs/explore/claims/*.claims.jsonl | rg PATTERN
```
