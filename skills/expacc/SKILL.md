---
name: expacc
description: Write and check replayable claims (.claims.jsonl) with the expacc CLI. Use when recording claims with a command and expected output, or re-checking them.
---

# expacc

## Claims file

A claims file is `claims/<name>.claims.jsonl` under the explore dir
(`./live-docs/explore` by default) and holds one JSON object per line:

```json
{"id": "login-handler", "text": "Login is handled in src/auth.js", "cmd": ["rg", "-n", "handleLogin", "src"], "expect": ["src/auth.js:42:export async function handleLogin(req, res) {"]}
```

- `id`: unique within the file
- `text`: the statement
- `cmd`: argv array, run without a shell (no pipes, redirects or globs)
- `expect`: the stdout lines the command must print, compared exactly,
  including order. Multi-file output from `rg` is not stable: pass
  `--sort path`, or search one file per claim. A negative claim
  ("X is not used in src") is `"expect": []`.

Prefer the CLI. `expacc record` runs the command and stores its output as
`expect`, so don't copy evidence by hand and don't write a new claims file
yourself. If something outside that flow happens — the statement is wrong but
the command and its evidence are already right, or you need to drop or reword
a claim in your own file — edit the claims file directly. There is no flag
that rewrites `text`. Do not record a second claim just to correct wording,
and do not spend a turn on `--help` looking for one.

### Header line (optional)

Must be the first line:

```json
{"doc": "example.md", "commit": "abcxyz1243", "depends": ["other", "another#some-claim"]}
```

- `depends`: a claims file name (`other`) or one claim (`other#id`), as in
  `claims/other.claims.jsonl`. Not a path, and not a `.md` note name.
  Followed recursively, each claim checked once, cycles are safe.
  Shown with a `(dep)` suffix.
- `doc`, `commit`: metadata only, not checked. They are not a way to
  name a claims file. `expacc check` takes the slug only.

## Recording claims

```
expacc record NAME --id ID --text TEXT [--doc D] [--commit C] [--depends DEP]... -- CMD ARG...
expacc record-append NAME --id ID --text TEXT -- CMD ARG...
expacc record-fix NAME ID
```

- `record` creates `claims/NAME.claims.jsonl` (with a header when `--doc`,
  `--commit` or `--depends` is given). It fails if the file exists.
- `record-append` adds one claim to your file. It fails on a duplicate id.
- `record-fix` re-runs that claim's command and rewrites its `expect`, and shows
  the diff. Use it when the code changed and the claim should follow it. It
  does not change `text` or `cmd`. To correct a statement, edit that field in
  your own claims file.
- Everything after `--` is the argv, run without a shell. The output it printed is
  stored as `expect` and echoed back, so that is your evidence. Don't run the
  command separately first.
- If the command fails (exit 2 or more, or it can't run) nothing is written.
- An empty output is recorded as `"expect": []`, a negative claim. Check that is
  what you meant.

### First time on a project

If there are no prior notes or claims files, there is nothing to check and nothing
to depend on. Skip that, investigate with your usual tools (`rg`, `sed`), then
record the findings you will report:

```
expacc record 1234 --id src-files --text "JavaScript files under src/" --doc my-doc.md --commit abc123 -- rg --files --sort path --type js src
expacc record-append 1234 --id scripts --text "npm scripts in package.json" -- rg -n -A8 "\"scripts\"" package.json
expacc check 1234
```

- `record` is only for recording. It is not a search tool: don't use it to explore.
- Pick the command that shows each finding (`rg -n`, `rg --files --sort path <dir>`,
  `ls -A <dir>`). It re-runs, so a narrow path or pattern keeps the output small.
- No `--depends` on the first `record` when there is nothing to depend on.

## Checking claims

```
expacc check NAME... [--print-all | --print-true | --print-false]
```

- `NAME` is a slug (`other`, or `other#id` for one claim). It resolves to
  `claims/other.claims.jsonl` in `$EXPACC_DIR` (default
  `./live-docs/explore`). A path, `.claims.jsonl` or `.md` is rejected
  (exit 2). Do not pass what `rg -l` printed; pass the filename without
  its directory and without `.claims.jsonl`.
- Run it from the root of the repo the claims describe.
- `--print-false` (default) shows failing claims with a diff; `--print-true`
  and `--print-all` show passing / all claims.
- The last line is `OK: N true, 0 false` or `FAILED: N true, M false`.
- Exit code: `0` all true (including dependencies), `1` any false, `2` bad
  usage. Read the summary line rather than the exit code when piping.

### Why a claim is FALSE

- `output differs`: the diff shows expected vs actual.
- `same lines, different order`: make the command output stable (`rg --sort path`).
- `no expect recorded`: the claim has no `expect`.
- `rejected`: empty command.
- `exec failed`: the command could not run, or exited with 2 or more.
- `missing dependency`: a `depends` file or claim id does not exist. The
  message lists the claims files that do.
- `file:line: error`: malformed JSON at that line.
- `lint: ...`: the file has an unknown header key, a duplicate claim id, or a
  `cmd` containing a shell token such as `|` or `&&`. `check` reports these
  itself; `expacc lint NAME...` reports them without running anything.

Output is compared exactly as the command printed it. Exit code 1 (for example,
no matches) is a normal result.

## Rules

- Write only your own claims file. Never edit another claims file. To build on
  one, list it in `depends` of your own file. Editing your own file is for
  the cases the CLI does not cover (a wrong statement, a claim to drop). New
  evidence still goes through `record` / `record-append` / `record-fix`.
- Never put a shell in `cmd`: no pipes, redirects or globs, and `cmd` is an
  array, not a string.
