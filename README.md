# expacc

Explore agents write notes about a codebase, and those notes go stale.
`expacc` makes them checkable: each note comes with **replayable claims**,
each one a statement, a bash command and the output that command is expected to
print. A claim holds while replaying the command prints the same output. When
code only moves, the claim is marked DRIFTED and can be updated automatically.

This repo contains:

- `expacc`, the CLI that records, checks, fixes and prunes claims
- `live-docs-web`, a local web UI for browsing notes and running checks
- the `AcceleratedExplore` Claude Code agent and the `expacc` skill it uses

## Quick start

```sh
nix-env -i -f default.nix                 # installs expacc and live-docs-web
cd ~/src/my-project                       # the repo the claims describe
expacc record auth --id login --text "Login is handled in src/auth.js" \
  -- 'rg -n --sort path handleLogin src'
expacc check auth
```

## Install

```sh
nix-env -i -f default.nix
```

This builds the package (and runs its tests), then installs both `expacc` and
`live-docs-web` into `~/.nix-profile/bin`.

## CLI

```
expacc check NAME... [--print-all | --print-true | --print-false | --minimal-output] [--moved-lines-jsonl]
expacc lint NAME...
expacc record NAME --id ID --text TEXT [--doc D] [--commit C] [--depends DEP]... -- CMD
expacc record-append NAME --id ID --text TEXT -- CMD
expacc record-fix NAME ID
expacc fix-line-shift [NAME...] [--dry-run] [--moved-lines-jsonl]
expacc prune [--dry-run] [--delete-if-older DUR] [--delete-if-inaccurate RATIO] [--delete-if-missing-claim]
```

- `NAME` is a slug (`auth`, or `auth#login` for one claim). It resolves to
  `$EXPACC_DIR/claims/NAME.claims.jsonl`, where `EXPACC_DIR` defaults to
  `./live-docs/explore`.
- `CMD` is one bash string run with `bash -c` from the current directory, so
  pipes and redirects work. Run expacc from the repo the claims describe.
- `record` creates the file with one claim, `record-append` adds a claim, and
  `record-fix` re-runs a claim and rewrites its expected output.
- `check` also reports lint problems. Exit code: `0` all true, `1` any false
  or drifted, `2` bad usage.

The claims file format and how to write good claims are in
[skills/expacc/SKILL.md](skills/expacc/SKILL.md).

### Check output

`--print-false` (default) shows failing and drifted claims; `--print-true` and
`--print-all` also show passing ones. `--minimal-output` prints only the totals
and, for each failing claim, `FALSE file#id` (or `DRIFTED file#id`) with its
command. The summary line is printed at the top and the bottom:

```
FAILED: 0 true, 1 false, 1 drifted

DRIFTED demo#port  -- same lines, line numbers moved by +4 (expacc fix-line-shift demo to update)
claim: The web UI listens on port 3090
command: rg -n --sort path 'setPort 3090' web/Main.hs
output (command output was transformed: one row per line, path  old -> new line number):
    web/Main.hs  30 -> 34    let settings = setHost "127.0.0.1" (setPort 3090 (setTimeout 0 defaultSettings))

FALSE demo#static  Static dir defaults to web/static  -- output differs
command: rg -n --sort path 'LIVE_DOCS_STATIC' web/Main.hs
output: 33:  staticDir <- maybe "web/static" id <$> lookupEnv "LIVE_DOCS_STATIC"
diff (command output was transformed: rg lines grouped into path:START-END blocks):
      line 33
    -     staticDir <- maybe "static" id <$> lookupEnv "LIVE_DOCS_STATIC"
    +     staticDir <- maybe "web/static" id <$> lookupEnv "LIVE_DOCS_STATIC"

line map (every line of the drifted claims above, merged per file; old -> new):
  web/Main.hs
    offsets (listed lines only): line 30: +4
    30 -> 34    +4  demo#port
Only the lines listed are known. A cited line that is not listed may have moved by
another offset or changed: find it again (rg -n 'its text' PATH), never interpolate
between listed lines or extend an offset range past its listed ends.

FAILED: 0 true, 1 false, 1 drifted
```

### Drift and `fix-line-shift`

A claim is DRIFTED rather than FALSE when its lines are unchanged and only
their position moved. This covers two kinds of command:

- `rg` with line numbers (`-n`, `--line-number`, `-nA5`, ...) whose output
  parses as rg lines. The output is grouped into `path:START-END` blocks, so a
  FALSE diff shows only headers and changed lines. The recorded `expect` stays
  raw rg output.
- a bare `sed -n 'A,Bp' FILE`, when the expected lines appear unchanged at
  exactly one other place in the file.

Drifted claims are followed by a per-file line map of every moved line. Any
transformed section is labelled `(command output was transformed: ...)`.

`expacc fix-line-shift [NAME...]` rewrites drifted claims (a new `expect` for
rg, a new range for sed) and prints what moved. With no `NAME` it covers every
claims file; `--dry-run` changes nothing. `--moved-lines-jsonl` (on `check` or
`fix-line-shift`) prints one JSON object per moved line instead,
`{"path", "old", "new", "claim", "text"}` with `path` null when unknown, and
leaves the exit status unchanged. See
[skills/expacc/keeping-live-docs-up-to-date.md](skills/expacc/keeping-live-docs-up-to-date.md).

### Prune

`prune` deletes notes in `$EXPACC_DIR/*.md` together with their claims file.

- `--delete-if-older DUR` (`7d`, `1h`, `30m`, `45s`, by file mtime) and
  `--delete-if-inaccurate RATIO` (true claims over total below `RATIO`) apply
  to notes with a claims file and are ANDed when both are given.
- `--delete-if-missing-claim` deletes notes with no claims file. With
  `--delete-if-older` as well, only old ones are deleted.
- Each deleted note prints `deleted SLUG (reasons)` and the files removed;
  `--dry-run` prints `would delete` and removes nothing.

## Web UI

```sh
cd /path/to/explore-accelerator   # or set LIVE_DOCS_STATIC
live-docs-web
```

`live-docs-web` listens on http://127.0.0.1:3090 only. It reads its assets from
`web/static` relative to the current directory on every request, so start it
from this checkout or set `LIVE_DOCS_STATIC=/path/to/web/static`.

It uses the library directly rather than calling the `expacc` binary. Project
directories you add are stored in the browser. You can browse notes, run one
claim or a file's claims (results appear in a modal), or Run all, which streams
results file by file and ends with a summary. The note lifetime is stored as
seconds in `explore-lifetime` in `live-docs/.live-docs-config.json`; the page
accepts seconds or days.

## Claude Code setup

[agents/AcceleratedExplore.md](agents/AcceleratedExplore.md) is a subagent
that works like the built-in Explore agent but keeps its answer. It checks
prior notes in `live-docs/explore/` with `expacc`, investigates only the gaps,
writes `live-docs/explore/<slug>.md` and sends the parent that path straight
away. It then records and checks a claims file in the background (the note is
never edited afterwards) and replies with just the path. It runs on Haiku with
the `expacc` skill preloaded.

1. Install expacc (see [Install](#install)) and make sure `~/.nix-profile/bin`
   is on your `PATH`; the skill and agent call `expacc` by name.
2. Install the skill and the agent, user-wide or per project
   (`<repo>/.claude/skills/`, `<repo>/.claude/agents/`):

   ```sh
   mkdir -p ~/.claude/skills/expacc ~/.claude/agents
   cp skills/expacc/SKILL.md skills/expacc/keeping-live-docs-up-to-date.md ~/.claude/skills/expacc/
   cp agents/AcceleratedExplore.md ~/.claude/agents/
   ```

3. Restart Claude Code.

To use it, ask Claude to explore with the AcceleratedExplore agent. The prompt
must start with a slug line, then the question and the breadth (`medium` or
`very thorough`):

```
SLUG: logging-systems-overview-and-config
Where is logging configured? Breadth: medium
```

The agent writes under `live-docs/explore/` in the current repo, so run it in
the repo you want explored.

## Development

```sh
nix-build        # build both executables and run the test suite
nix-shell        # GHC with all dependencies, ripgrep, and the built expacc/live-docs-web
```

The tests shell out to `rg`, so it must be on `PATH` when running them outside
`nix-build`.

Code layout: `app/` is the CLI, `src/` the library (claims, record, prune),
`web/` the web UI, `test/` the test suite.
