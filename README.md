# expacc

Re-checks **replayable claims** written by explore agents: a statement, a
command, and the output it is expected to produce. A claim holds while
replaying the command gives the same output.

For writing claims and checking them, see [skills/expacc/SKILL.md](skills/expacc/SKILL.md).

## Build

```sh
nix-build   # builds expacc and runs the tests
nix-shell   # dev shell
```

## Usage

```
expacc check NAME... [--print-all | --print-true | --print-false]
expacc lint NAME...
expacc record NAME --id ID --text TEXT [--doc D] [--commit C] [--depends DEP]... -- 'CMD'
expacc record-append NAME --id ID --text TEXT -- 'CMD'
expacc record-fix NAME ID
```

`CMD` is one bash string, run with `bash -c`, so pipes and redirects work.
`record` runs it and stores its output as the expected output.
`check` also reports lint problems. `NAME` is a slug (`other`, or `other#id` for one claim) and resolves to `claims/other.claims.jsonl`
in `$EXPACC_DIR` (default `./live-docs/explore`). Commands run from
the current directory, so run it from the repo the claims describe.

`--print-false` (default) shows only failing claims, with a diff; `--print-true`
and `--print-all` show passing / all claims. Each shown claim also prints the
command that ran and its stdout, prefixed `command:` and `output:`. Exit code:
`0` all true, `1` any false, `2` bad usage.

```
TRUE  auth-flow#login-handler  Login is handled in src/auth.js
command: rg -n handleLogin src
output: src/auth.js:42:export async function handleLogin(req, res) {
FALSE auth-flow#token-ttl  Tokens expire after 1h  -- output differs
command: rg -n TTL src/auth.js
output: src/auth.js:const TTL = 7200;
    - src/auth.js:const TTL = 3600;
    + src/auth.js:const TTL = 7200;
1 true, 1 false
```

## Claude Code setup: the AcceleratedExplore agent

[agents/AcceleratedExplore.md](agents/AcceleratedExplore.md) is a Claude Code
subagent that works like the built-in Explore agent, but records its answer.
It checks prior notes in `live-docs/explore/` with `expacc`, investigates only
the gaps, writes `live-docs/explore/<slug>.md`, and messages the parent the
path straight away so it isn't kept waiting. Only then does it record and check
the claims file (best effort; the note itself is never edited afterwards), and
it finishes by replying with just the path. It runs on Haiku and has the `expacc` skill
preloaded.

### 1. Install expacc

```sh
nix-env -i -f default.nix   # installs expacc into ~/.nix-profile/bin
```

### 2. Configure Claude

Install the skill (user-wide, or use `<repo>/.claude/skills/` for one project):

```sh
mkdir -p ~/.claude/skills/expacc
cp skills/expacc/SKILL.md ~/.claude/skills/expacc/SKILL.md
```

Then add a line to the installed `SKILL.md`, under the `# expacc` heading, giving the absolute path to the binary (`readlink -f $(which expacc)` or `~/.nix-profile/bin/expacc` expanded), so the agent can call it:

```
The path to executable is /home/<you>/.nix-profile/bin/expacc
```

Install the agent:

```sh
mkdir -p ~/.claude/agents          # or <repo>/.claude/agents for one project
cp agents/AcceleratedExplore.md ~/.claude/agents/
```

Restart Claude Code so it picks up the agent and skill.

### 3. Use it

Ask Claude to explore with the AcceleratedExplore agent. The prompt must start
with a slug line, then the question and the breadth (`medium` or `very thorough`):

```
SLUG: logging-systems-overview-and-config
Where is logging configured? Breadth: medium
```

The agent works from the repo root and creates `live-docs/explore/` files
there, so run it in the repo you want explored.
