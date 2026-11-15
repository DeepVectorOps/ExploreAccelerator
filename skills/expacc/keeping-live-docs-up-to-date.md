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
- Each fixed claim prints its old and new position, then one summary line:

```
shifted auth-flow#login-handler  by +8
    - src/auth.js:42-44
    + src/auth.js:50-52

1 shifted claims fixed, 2 still false, 19 true
```

## 2. Fix line numbers in the prose

`fix-line-shift` does not touch the doc or a claim's `text`. If either cites a line number (`src/auth.js:42`), use the printed old and new positions to correct it.

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
