# gha-pin

Pin GitHub Actions references in workflow files to full commit SHAs, keeping
the original ref as a trailing comment:

```yaml
- uses: actions/checkout@v4
# becomes
- uses: actions/checkout@<40-character commit sha> # v4
```

## Why

A tag like `v4` is a mutable pointer: whoever controls the action's repository
can move it to different code, and so can anyone who compromises that
repository. A workflow that says `@v4` runs whatever the tag points to today.
Pinning to a commit SHA makes the workflow run exactly the code you reviewed.

The trailing `# v4` comment keeps the line readable, and it is the format
Dependabot and Renovate understand: they keep proposing updates for pinned
actions, bumping the SHA and the comment together.

## Requirements

- Python 3.8 or later (standard library only).
- The GitHub CLI, `gh`, authenticated (`gh auth login`). Refs are resolved with
  `gh api`, so public actions work with any login, and private ones need a
  token that can read their repository. `GH_HOST` selects a GitHub Enterprise
  host.

Copy the script to a directory on your `PATH`:

```sh
install -m 0755 gha-pin/gha-pin ~/.local/bin/gha-pin
```

## Usage

```sh
gha-pin --dry-run                    # show the changes as a unified diff, write nothing
gha-pin                              # pin .github/workflows/*.yml and *.yaml in place
gha-pin --dir path/to/workflows      # another directory
gha-pin action.yml other/action.yml  # explicit files, e.g. composite actions
```

Run it from the repository root. With FILE arguments, only those files are
processed; `--dir` and FILEs cannot be combined. Files are rewritten in place,
atomically, keeping their permissions. Nothing else in a file changes: line
endings (LF or CRLF), quoting, indentation, and a missing final newline are all
kept. An existing comment on a `uses:` line stays, after the new ref comment
(`# v4 your old comment`).

A summary goes to stderr:

```
gha-pin: pinned 7, already pinned 1, skipped 2 (local/docker), failed 0
```

## What it pins and skips

| Reference | Result |
|---|---|
| `owner/repo@ref` | pinned |
| `owner/repo/path@ref` (subdirectory action) | pinned, resolved against `owner/repo` |
| `owner/repo/.github/workflows/x.yml@ref` (reusable workflow) | pinned, resolved against `owner/repo` |
| `owner/repo@<40-hex sha>` | already pinned, left alone |
| `./path`, `../path` (local action) | skipped |
| `docker://image` | skipped |
| anything else after `uses:` | reported as not pinnable |

`uses:` text inside block scalars, such as a `run: |` script that mentions
`uses:`, is not touched.

## How refs are resolved

1. `gh api repos/OWNER/REPO/git/ref/tags/REF`.
2. An **annotated tag** is a tag object of its own, with its own SHA, that
   points to a commit. Pinning the tag object's SHA would not work, so gha-pin
   follows `gh api repos/OWNER/REPO/git/tags/SHA` until it reaches the commit
   (a tag of a tag is followed too, with a loop guard). A lightweight tag points
   to the commit directly.
3. If no tag has that name, `gh api repos/OWNER/REPO/git/ref/heads/REF`. A
   **branch** (`@main`) is pinned to its current head commit, and a note says
   so: the branch keeps moving, so the pin freezes whatever it pointed to at
   that moment. Prefer a release tag where one exists.
4. Otherwise the line is reported as `file:line: cannot resolve ...` and left
   unchanged; the other references are still pinned.

Each distinct `owner/repo@ref` is looked up once per run, however many times it
appears.

## Exit status

| Status | Meaning |
|---|---|
| 0 | success, including when there was nothing to pin |
| 1 | some references could not be resolved (all others were pinned) |
| 2 | usage or runtime error, e.g. `gh` missing or unauthenticated. gh failures other than "not found" stop the run before any file is written. |

## Tests

`bash gha-pin/test.sh` runs the suite against a file-backed fake `gh` that
answers from a fixture table (lightweight, annotated, and nested annotated
tags; a branch; missing refs) and logs every call. Nothing talks to GitHub.
Name tests to run a subset: `bash gha-pin/test.sh t_crlf_is_preserved`.
