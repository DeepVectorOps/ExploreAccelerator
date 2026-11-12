---
name: expacc
description: Write and check replayable claims (.claims.jsonl) with the expacc CLI. Use when recording claims with a command and expected output, or re-checking them.
---

# expacc

A claim is a statement, a bash command and the output that command must print. It holds while replaying the command prints exactly that output.

## Claims file

`claims/<name>.claims.jsonl` under the explore dir (`$EXPACC_DIR`, default `./live-docs/explore`). One JSON object per line:

```json
{"id": "login-handler", "text": "Login is handled in src/auth.js", "cmd": "rg -n handleLogin src", "expect": ["src/auth.js:42:export async function handleLogin(req, res) {"]}
```

- `id`: unique within the file.
- `text`: the statement.
- `cmd`: one raw bash string, run with `bash -c` from the current directory. Pipes, redirects and globs all work.
- `expect`: the stdout lines the command must print, compared exactly, including order. A negative claim ("X is not used in src") has `"expect": []`.
  - **Every `rg` in a claim command needs `--sort path`**, including each `rg` inside a pipe and searches over files you list yourself. `rg` searches files in parallel, so without it the line order changes from run to run and the claim flips between TRUE and FALSE ("same lines, different order"). The alternative is one file per claim. `| head` and `| sort` do not make an unsorted `rg` safe.
  - Exit code 1 (no matches) is a normal result; exit 2 or more is a failure.

Optional first line, a header:

```json
{"doc": "example.md", "commit": "abc1234", "depends": ["other", "another#some-claim"]}
```

- `depends`: a claims name (`other`) or one claim (`other#id`). Followed recursively, each claim checked once, shown with a `(dep)` suffix. Depend on the specific claims you use, not on whole files.
- `doc`, `commit`: metadata only, never checked.

## Names

A NAME is a slug: `other`, or `other#id` for one claim. It resolves to `claims/other.claims.jsonl`. A path, a `.claims.jsonl` suffix or a `.md` name is rejected (exit 2). If `rg -l` printed a path, strip the directory and the suffix.

## Recording

```
expacc record NAME --id ID --text TEXT [--doc D] [--commit C] [--depends DEP]... -- 'CMD'
expacc record-append NAME --id ID --text TEXT -- 'CMD'
expacc record-fix NAME ID
```

- `record` creates the file (with a header if `--doc`, `--commit` or `--depends` is given). It fails if the file exists.
- `record-append` adds a claim to your file. It fails on a duplicate id.
- `record-fix` re-runs a claim's `cmd` and rewrites its `expect`, showing the diff. It never changes `text` or `cmd`.
- Quote `CMD` as one argument. Several arguments after `--` are treated as an argv and quoted into one command.
- The command runs and its output is stored and echoed back, so that output is your evidence. Don't run it first, and don't copy output by hand.
- If the command fails, nothing is written. Empty output is recorded as `"expect": []`; make sure that is what you meant.
- `record` is not a search tool. Explore with `rg` and `sed`, then record the command that shows each finding. It re-runs on every check, so keep output small with a narrow path or pattern.

When the CLI cannot do what you need, edit your own claims file directly: reword `text`, change `cmd`, drop a claim, or drop a stale entry from `depends`. There is no flag for these. Don't record a second claim just to fix wording, and don't spend a turn on `--help`.

## Checking

```
expacc check NAME... --print-all
expacc check NAME... --minimal-output
expacc lint NAME...
```

- Run from the root of the repo the claims describe.
- Use `expacc check NAME... --print-all`, not plain `check`. Each shown claim prints the command that ran and the output it printed, one prefix per line (`command: ...`, `output: ...`; a bare `output:` means it printed nothing). `--print-false` is the flag default and shows only failing claims; `--print-true` shows only passing claims. Prefer `--print-all`.
- `--minimal-output` prints only the summary (`OK: N true, M false` or `FAILED: N true, M false`) and, for each false claim, `FALSE file#id` plus the command that failed. No diffs, no stdout.
- The last line is `OK: N true, 0 false` or `FAILED: N true, M false`. Exit code: `0` all true including dependencies, `1` any false, `2` bad usage.
- `lint` reports file problems without running any command; `check` reports them too.

### Why a claim is FALSE

- `output differs`: the diff shows expected against actual.
- `same lines, different order`: an `rg` in the command has no `--sort path`. Add it to every `rg`, edit `cmd` in your own claims file, then `record-fix` the claim.
- `no expect recorded`: the claim has no `expect`.
- `rejected`: empty command.
- `exec failed`: the command could not run, or exited with 2 or more.
- `missing dependency`: a `depends` file or claim does not exist; the message lists the claims files that do.
- `file:line: error`: malformed JSON at that line.
- `lint: ...`: an unknown header key or a duplicate claim id.

A FALSE claim matters only if what it states matters to your task.

## Rules

- Write only your own claims file. Never edit another one; build on it with `depends`.
- New evidence always goes through `record`, `record-append` or `record-fix`. Direct edits are for statements, commands and dependencies the CLI cannot change.
