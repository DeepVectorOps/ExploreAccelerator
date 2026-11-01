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
expacc record NAME --id ID --text TEXT [--doc D] [--commit C] [--depends DEP]... -- CMD ARG...
expacc record-append NAME --id ID --text TEXT -- CMD ARG...
expacc record-fix NAME ID
```

`record` runs the command and stores its output as the expected output.
`check` also reports lint problems. `NAME` (`foo`, `foo.claims.jsonl` or `foo.md`) resolves to `claims/foo.claims.jsonl`
in `$EXPACC_DIR` (default `./live-docs/explore`). Commands run from
the current directory, so run it from the repo the claims describe.

`--print-false` (default) shows only failing claims, with a diff; `--print-true`
and `--print-all` show passing / all claims. Exit code: `0` all true, `1` any
false, `2` bad usage.

```
TRUE  auth-flow#login-handler  Login is handled in src/auth.js
FALSE auth-flow#token-ttl  Tokens expire after 1h  -- output differs
    - src/auth.js:const TTL = 3600;
    + src/auth.js:const TTL = 7200;
1 true, 1 false
```
