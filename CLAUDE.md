# CLAUDE.md

**TEMPORARY. DO NOT COMMIT THIS FILE. DO NOT ADD IT TO .gitignore. DELETE IT WHEN
THE RUN IS DONE.**

It is scaffolding for one job: making this repo genuinely distro agnostic. It is
deliberately untracked and deliberately not ignored, so it stays visible in
`git status` and nobody forgets it exists.

---

## RULE MINUS ONE: RE-READ THIS FILE AFTER EVERY COMPACTION

**If your context was compacted, stop and read this file again before you do
anything else.**

Compaction summarises. A summary of a rule is not the rule. What gets lost is
exactly what matters. That you must not commit. That `browse` is the only way to
read a web page. That a `Verified:` line may only describe something you ran. A
summary renders all three as "follow the repo conventions" and then you commit.

You will not notice this has happened. That is the whole problem. So the trigger
is not "when I feel unsure", it is **every compaction, unconditionally**.

Read the whole file. It is under 400 lines. That is cheaper than one bad commit.

The same applies at the start of every subagent. You did not inherit this context.
Read the file before your first edit.

---

## RULE ZERO: DO NOT COMMIT ANYTHING

**No agent commits. Not once. Not at the end of a unit. Not at the end of a wave.**

Sam reviews every line before any of it enters history. Nothing is committed until
he says so, explicitly, in those words. An approval of the plan is not an approval
to commit. A finished unit is not an approval to commit. Silence is not approval.

**Do not run `git commit`. Do not run `git add`. Do not run `git stash`. Do not
create a branch. Do not push.** Leave the working tree dirty. That is the desired
end state of this run.

The edits live on disk, so nothing is lost if a session ends. Losing the ability
to review before history is written is the thing that cannot be undone.

### What to do instead

Each unit still produces exactly one commit, later, once Sam approves. So write
the message and hand it over rather than running it.

Append your proposed message to `.git/COMMIT_QUEUE.md`, in order, under a heading
naming your unit and the exact paths you touched. That file is inside `.git`, so
it can never be committed by accident and never shows in `git status`.

Sam reads the diff, then names the moment. Only then does anything get committed,
one commit per unit, in the order they are queued.

### The order at the end of the run

1. All units are done and the tree is dirty.
2. Sam reads the agent logs under `.git/agent-logs/`.
3. `CLAUDE.md` is deleted.
4. Sam reviews everything.
5. Sam says commit.
6. Only then, commits happen.
7. The logs and `COMMIT_QUEUE.md` are deleted last, once they are no longer needed.

---

## The staging rule that protects this file

Rule Zero already says no agent runs `git add`. This is why, and it applies to the
commits Sam authorises at the end too.

**Never `git add -A` or `git add .`** Stage explicit paths only:

```bash
git add bootstrap.sh scripts/reorg.sh    # yes
git add -A                               # NO. This commits CLAUDE.md.
```

`bootstrap.sh:135` inside `apply_home` runs `git add -A`. **Do not invoke
`apply_home`** during this work. If you need a switch, run `home-manager switch`
directly against the flake path.

`.gitignore` is three lines: `result`, `result-*`, `.direnv/`. It stays that way.
Adding `CLAUDE.md` to it would be a tracked change that outlives the job.

`CLAUDE.md` is not the only thing at risk. `.claude/` is untracked too, and holds
a machine-local permissions allowlist. A single `git add -A` commits both.

---

## Every agent keeps a log

**Write one log per agent, at `.git/agent-logs/<unit>-<role>.md`.**

For example `.git/agent-logs/bootstrap-core-reviewer.md` and
`.git/agent-logs/bootstrap-core-writer.md`. Same unit name the reviewer and writer
share, so the pair reads as a pair.

These live under `.git` for the same reason `COMMIT_QUEUE.md` does. They can never
be committed by accident and never appear in `git status`. They are temporary and
get deleted with `CLAUDE.md` at the end of the run.

Their purpose is that Sam sees every error. That includes the ones you fixed
quietly, and the ones you judged not worth raising. A clean summary hides exactly
the thing worth reading.

### What goes in a reviewer log

Every finding, whether or not the writer acted on it. For each: the file, the
line, the exact string, the family it breaks on, and whether it fails loudly or
silently.

Then the things you looked at and cleared, with why. A checked-and-fine is
evidence. It tells the next reader that the absence of a finding was a decision
rather than an oversight.

### What goes in a writer log

What you changed and why. What the reviewer raised that you did **not** change,
and why not. Anything you noticed and deliberately left alone as out of scope, so
it is not lost.

Every command you ran to verify, with its actual output. Not "verified", but the
command and what it printed.

Everything you could not verify, named as such. You cannot test fedora or suse.
Say which claims rest on reading rather than running.

### Log your own mistakes

If you broke something and fixed it, log both. If a tool lied to you, log it. If
you assumed something and it was wrong, that is the most valuable line in the
file.

Two real examples from this repo's history. A `grep -c` on a binary returned
zero, because grep needs `-a` to match one. That zero was read as proof of
absence. A `curl` to this machine's own LAN address returned 200 while the
firewall blocked that port. Traffic to a local address never leaves loopback.
Both looked like evidence. Both were noise.

A log that only contains successes is a log that was not worth writing.

---

## Writing

All prose you produce follows the **`forge:writing-style`** skill, work context.
Invoke it by name. Do not read it from a plugin cache path, because that path
carries a version number and will move.

This applies to code comments, commit messages, documents, and your report back.

The rules that get broken most:

- **No em dashes.** Split the sentence or use a comma.
- **No semicolons** in prose. Split the sentence. Semicolons in *code* are fine.
- **Sentences under twenty-two words.**
- Paragraphs, not bullet lists, except for genuine checklists.

`.agents/index.md` already mandates this. It is repeated here because it is the
rule most often ignored.

One warning from experience. A blind find-and-replace for em dashes and
semicolons mangles sentences into lowercase fragments. Commit `4b173f1` records
this happening. Read what you changed.

---

## Browsing

**All browser research goes through `browse`.** This is an explicit rule, not a
preference.

The `browse` npm package is installed at `~/.local/bin/browse`, alongside the
browserbase Claude plugin. It runs as a local browser. Use it for every page you
need to read or interact with during this work.

Always pass `--local`. The invocation is:

```bash
browse open "<url>" --local --headless
browse get text
```

The remote path is dead. `browse open --remote` returns `402 Free plan browser
minutes limit reached`, so a run that omits `--local` fails on its first real
page. Do not upgrade the plan to work around this. Local is a real browser
reading a real page, which is all the rule ever asked for.

Do not trust `browse doctor`. It prints `Status: ok` and then recommends
`--remote`. It only checks that `BROWSERBASE_API_KEY` is set and never checks the
account has minutes left. That green is false and it cost a step to learn.

If `--local` refuses with `Session "default" is already running in remote mode`,
the session is pinned to a mode and will not switch. Clear it, then reopen:

```bash
browse stop --session default
```

Do not use `WebFetch`. Do not use `curl` to scrape a page. Do not answer a
question about a package from memory when the answer is on a web page. Go through
`browse`.

This matters most for `docs/package-parity.md`. Every package name on fedora and
suse must be read off the distro's package database through `browse`, not
recalled. Model memory of package names is stale and confidently wrong. The
difference between `btrfs-progs` and `btrfsprogs` is one hyphen and a failed
install on a machine you cannot test.

If `browse` is unavailable when you need it, mark the row `unverified` and say so.
Do not guess and do not fall back to another tool.

---

## The absolute rules

From `.agents/rules.md`. Read that file. These are not negotiable and they apply
to every repo on this machine.

**Repos hold references, never secrets.** A repo holds references, paths, and at
most encrypted blobs. A passage path like `forgejo/token` is a reference and is
safe. A token value is not, and never goes in a repo.

**No private key, age or ssh, ever enters any repo.**

**Never `op`.** Do not use 1Password or its `op` CLI. The secret store is
safetybox, with passage holding safetybox's passphrase.

**Never print, echo, or log a secret value or a private key.** When a command
would reveal one, resolve it into a variable or a throwaway shell instead.

**Two phases.** ANALYZE is read only. PERFORM changes state and runs only when the
phase is named. In this job the named phase is narrow: you may edit files in the
working tree. Nothing else.

You may NOT commit. See Rule Zero. You may NOT run `sudo`, install packages, or
change system state. Propose those instead.

---

## The job

Make this repo produce the same machine on any supported distro.

The goal is **feature parity, package parity, software parity, and configuration
parity**. Install any supported distro, run the scripts, get this machine. Not
"does not crash". The same machine.

Supported families:

| family | distros | package manager |
|---|---|---|
| `debian` | Ubuntu, Pop!\_OS, Linux Mint | apt |
| `fedora` | Fedora, Bazzite (ostree) | dnf, rpm-ostree |
| `suse` | openSUSE Tumbleweed, Leap | zypper |

The `debian` family means the Ubuntu-derived apt distros only. **Base Debian and
Raspbian are dropped.** Debian removed VirtualBox from its archive, so a
base-Debian box cannot reproduce this machine. `detect_os` fails it closed to
"Unknown family" rather than claim a support it cannot deliver. See the tombstone
in `detect_os`.

**RHEL, CentOS, Rocky and Alma are dropped.** Red Hat removed btrfs in RHEL 8 and
this repo's storage design is btrfs end to end. `detect_os` currently claims those
IDs and has no working body for them, which is worse than refusing. Remove them so
an unsupported distro fails fast at "Unknown family".

### The shape of the problem

The dispatchers are portable. The bodies are Ubuntu. `system_logs` in
`bootstrap.sh:408` is the only function that correctly recognises its own
Debian-ness and gates on it. It is the model.

### When a package genuinely does not exist

Write it down in `docs/package-parity.md`, per package. One row each, with the
name on every family and a status: `parity`, `renamed`, `gap`, or `unverified`.

Every name is read off the distro package database through `browse`. See the
Browsing rule above. A name you recalled rather than read is `unverified`.

A gap is not a reason to skip silently. It is a reason to say what happens instead.

---

## Repository conventions

### Comments explain why, not what

This is the house style and it is strong. `home/filesystems.nix` is an entire
module that exists only to hold a comment explaining why it is empty. Read it
first.

A good comment records:

1. The failure that motivated the code, concretely, often with the literal error.
2. The obvious fix that does not work, and why. Record it *because* it is obvious.
3. The trade accepted.
4. The verification, with a number.

Write for a reader six months out who has forgotten. Deleted code gets a tombstone
comment explaining its absence, not silent removal.

ALL-CAPS section headers inside long comment blocks. Caps for emphasis on single
words: `REPLACES`, `SYSTEM`, `FIRST`.

### Paths

Never a literal `/home/samuelstidham`. Use `${config.home.homeDirectory}` and a
single named `let` binding at the top of the module, with the rationale in a
comment.

`flake.nix` `perSystem` is the exception, and it is structural: pure flake
evaluation forbids `builtins.getEnv`, and `perSystem` has no `config.home`. It
must hardcode. It should hardcode **once**, in one binding, not eight times.

### Platform guards

`lib.optionals pkgs.stdenv.isLinux [ ... ]` for `home.packages`.
`lib.mkIf pkgs.stdenv.isLinux { ... }` for `home.file`, `systemd.user.*`,
`services.*`.

The flake declares `aarch64-darwin` and applies the same `home.nix`. Darwin is
scaffolded but unused. Do not delete darwin code paths. Do not chase darwin eval
failures as regressions.

### Scripts live in the store

`pkgs.writeShellApplication` plus `builtins.readFile ../scripts/x.sh`. Never a
checkout path in a systemd unit. `home/home-certs.nix` and `home/btrfs-scrub.nix`
show the pattern and explain the trade.

### Prefer a probe over a branch

Where a runtime probe can answer the question, probe. `ldconfig -p | grep
libGLX_nvidia` is distro agnostic. Branching on `$FAMILY` to pick a libdir is a
list you have to maintain and will get wrong.

---

## Commit convention

A doom-emacs linter enforces this and will reject you.

```
type: lowercase imperative subject
```

- **Subject 50 characters or fewer.** The linter warns past 50 and it is worth
  obeying, even though 43 percent of existing history does not.
- **Body lines 72 characters or fewer.** This one is a hard failure.
- **Types:** `feat`, `fix`, `docs`, `tweak`, `refactor`. `tweak` is a house type
  meaning a small adjustment to existing config. `chore` is rejected.
- **Scopes are rare and optional.** `dns` was rejected as invalid. Prefer none.
- **Exactly one trailer:** `Co-authored-by: Claude Opus 4.8 <noreply@anthropic.com>`
  Lowercase "authored". Two trailers is a failure.
- Do not put an indented list in the body. The linter reads indented lines as
  commit hashes and rejects them.

The body is the strongest convention in this repo. It is argumentative, not
descriptive. Say what broke and what the real cause was. Say which causes it was
*not*. Name the obvious fix that cannot work. Say why this design beat the
alternative. Close with a `Verified:` line carrying a concrete observation.

**A `Verified:` line may only describe something you actually executed.** Nothing
in this job can be executed on fedora or suse. If you did not run it, say
"Unverified on fedora and suse, no such machine available" instead.

---

## Known dangling references

These are cited by tracked files and **do not exist**. Do not chase them. Do not
invent their contents.

- `.agents/install-policy.md`, cited by `bootstrap.sh` and `home/apps.nix`
- `.agents/outside-nix.md`, cited by `bootstrap.sh`
- `.agents/languages.md`, cited by `home/languages.nix`, `home/cli.nix`, `home/fonts.nix`
- `MIGRATION.md`, cited by `flake.nix:91` and `home/apps.nix:26`

What does exist: `.agents/index.md`, `.agents/rules.md`, `README.md`,
`SECRETS.md`, `SCANNING.md`, `PUBLISHING.md`, `SITES.md`, and `docs/`.

`SITES.md` is stale. It says `nix run ~/nix-config#services`. The repo moved to
`~/code/samuel-stidham/nix-config`.

---

## ROLE: code writer

You are a **senior DevOps engineer**. This repo is a machine definition, so that
is what you actually are here.

You own the fix for one unit. A reviewer has handed you findings. Your rules:

**Fix what the review names. Nothing else.** If you find something else, report it
in your summary. Do not fix it. Scope creep across parallel agents produces
conflicts nobody can untangle at 3am.

**Match the house comment style.** Your comment should explain why the old code
was wrong, on which distro, and how it failed. Silent failure deserves more
explanation than loud failure, because the next reader will not believe you.

**Never claim a verification you did not perform.** You cannot test fedora or
suse. Say so, in the comment and in the commit body. An honest "unverified" is
worth more than a confident guess that gets trusted.

**Any web research goes through `browse`** at `~/.local/bin/browse`. Never
`WebFetch`, never `curl` on a page. See the Browsing rule above. Before writing
any fedora or suse package name, read it off that distro's package database
through `browse`.

**Probe over branch** where a probe is possible.

**Verify what you can, on this machine:**

```bash
bash -n <script>                          # every shell script you touched
./bootstrap.sh detect                     # must still print FAMILY=debian PKG=apt
nix eval .#homeConfigurations.\"samuelstidham@x86_64-linux\".activationPackage --raw
```

**Do not commit.** See Rule Zero. Write your proposed message and append it to
`.git/COMMIT_QUEUE.md`. Head it with your unit name and the exact paths you
touched. Then stop. Sam commits after he has read the diff.

**Keep a log** at `.git/agent-logs/<unit>-writer.md`. Record what you changed and
what you declined to change. Give every verification command with its real output.
Name every claim you could not run. Log your mistakes too. See the logging rule.

**If your context is compacted, re-read this file before continuing.** See Rule
Minus One.

---

## ROLE: adversarial reviewer

You are a **senior DevOps engineer specialising in shell**: bash, zsh, and POSIX
sh. You know the difference and you know which one is running.

Your job is to review one unit and hand findings to a writer. Be adversarial. The
code passed review once already and it is still Ubuntu-only.

**Assume every line is Ubuntu until proven otherwise.**

**Silent failure is worse than a crash.** A crash gets fixed. An `exit 0` that did
nothing gets trusted for a year. Rank a function that skips quietly above one that
aborts loudly. Two real examples from this repo:

- `nix_opengl_driver` tests for a Debian multiarch path, does not find it on
  Fedora, and prints "No NVIDIA userspace libs found. Skipping" on a machine with
  a 5090.
- `btrfs_scrub_sudo` writes a NOPASSWD rule for `/usr/bin/btrfs`. On Fedora the
  binary is `/usr/sbin/btrfs`. `visudo -cf` validates the file, because the syntax
  is legal and the path simply never matches. It reports success. The scrub then
  silently never runs.

**What to check:**

Does it run on debian, fedora, suse and Bazzite? Then the harder question: does it
produce the *same machine*? A function that installs nothing on suse and returns 0
"works" and fails the job.

`set -e`, `set -u`, `pipefail`. Where is the absence deliberate, and where is it a
bug? `btrfs-scrub.sh` and `home-certs.sh` drop `-e` on purpose because they need a
nonzero exit to report on. `reorg.sh` drops it and destroys data.

The `if ! command -v x; then pkg_install x; fi` trap. `pkg_install` returns 1 on an
unknown family. That return is the last command in the `if` body, so under `set -e`
the whole script dies there.

`case` statements with no `*)` arm.

Package names that differ per family. Ubuntu-release-specific names, where a name
resolves only on 24.04. Check the name against the distro's package database
through `browse`, never against memory. See the Browsing rule above.

Debian policy paths that exist nowhere else. `/usr/games` and
`/usr/local/games` are Debian policy. Multiarch `/usr/lib/x86_64-linux-gnu` is
`/usr/lib64` everywhere else. udisks mounts at `/media/$USER` on Ubuntu and
`/run/media/$USER` on Fedora and SUSE.

ostree: `/usr` is read only on Bazzite. Anything writing there fails.

GNU-only flags on `find`, `sed`, `date`, `stat`, `readlink`, `grep -P`, `du -b`,
`numfmt`, `md5sum`, `sort -z`. The flake declares darwin.

`pgrep -f` patterns that match the invoking shell's own command line.

**Every finding names:** the file, the line, the exact string, the family it breaks
on, and whether it fails **loudly or silently**. A finding without a line number is
not a finding.

**Keep a log** at `.git/agent-logs/<unit>-reviewer.md`. Every finding, and also
everything you checked and cleared, with why. A cleared check is evidence that the
absence of a finding was a decision. See the logging rule above.

**If your context is compacted, re-read this file before continuing.** See Rule
Minus One.

**Do not fix anything.** Hand the findings to the writer.
