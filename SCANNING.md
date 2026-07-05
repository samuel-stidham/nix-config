# Secret scanning

This is the plan for keeping secrets out of every repo. It pairs a fast commit
guard with a deep pre-publish audit. It was seeded from the same one-time prompt
as `SECRETS.md`. The standing rule lives in `.agents/rules.md`.

## Two tools, two jobs

gitleaks is the primary scanner and the commit guard. Confirmed `gitleaks` 8.30.1
on the channel. It runs on every commit and blocks staged secrets. It also does a
fast full-history scan before a repo goes public.

trufflehog is the auditor. Confirmed `trufflehog` 3.95.7 on the channel. It runs
a deep, verified scan before a repo goes public. Verified means it tests whether a
found credential is still live, not just whether a string looks like a secret.

## Pre-commit guard through home-manager

This is codified now in `home/secrets.nix`. home-manager sets `core.hooksPath` to
a managed hooks directory at `~/.config/git/hooks`, and the pre-commit hook runs
gitleaks on the staged changes. Because `core.hooksPath` is global, the guard runs
in every repo you work in, not just this one. It applies on the next
`home-manager switch`. The hook calls the pinned gitleaks by absolute store path,
so it runs even with a bare hook PATH.

The invocation is confirmed against the pinned gitleaks 8.30.1. Version 8.19
replaced the old `protect` and `detect` commands with `git`, `dir`, and `stdin`.
The `--staged`, `--redact`, and `--no-banner` flags all exist in 8.30.1, so the
hook command is:

```bash
gitleaks git --staged --redact --no-banner
```

`--staged` scans only what is staged, which is right for a pre-commit hook.
`--redact` keeps any match out of the output. `--no-banner` keeps the output
quiet. A non-zero exit blocks the commit.

For repos that run CI, provide a per-repo `.pre-commit-config.yaml` option too, so
the same guard runs in the pre-commit framework. That is an addition to the global
hook, not a replacement.

## Allowlist

The store references and age recipient strings must not trip false positives. The
repo ships a `.gitleaks.toml` that allowlists passage reference paths like
`forgejo/token` and age recipient strings like `age1...`. The file extends the
default gitleaks rules rather than replacing them, so real detections still fire.
The allowlist holds patterns, never a secret value.

## Pre-publish scan

Before any repo flips public, run both tools over the full history. Record the
results. The commands are:

```bash
gitleaks git --redact .        # fast full-history scan
trufflehog git file://.        # verified scan, tests whether a find is still live
```

If either finds a real secret in history, rotate the credential. Do not only
scrub it. An exposed secret is burned, since the history may already be copied.
Rotation replaces the value at the source, which scrubbing alone does not.

The full pre-publish checklist lives in `PUBLISHING.md`.

## Phases

The scanner work is one named phase in the bootstrap, `scanners-wire`. See the
phase list in `SECRETS.md`. Nothing runs until you name it.
