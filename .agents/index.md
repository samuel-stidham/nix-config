# nix-config agent index

This is the home-manager flake for samuelstidham. It also holds the hardening
plan for secrets, git identity, and secret scanning. Read this first, then read
the file that fits your task.

## Hardening plan and rules

- [rules.md](rules.md) is the hard rule for this repo. Repos hold references
  only, never secret values, never private keys, never op. Read it every time.
- [../SECRETS.md](../SECRETS.md) is the passage plus age plus direnv plan and the
  git identity plan.
- [../SCANNING.md](../SCANNING.md) is the gitleaks and trufflehog setup.
- [../PUBLISHING.md](../PUBLISHING.md) is the pre-publish checklist for going open
  source.

## Writing style

Follow the forge writing-style rules for all prose. No em dashes, no semicolons,
sentences under twenty-two words, paragraphs over bullet lists except for genuine
checklists, American English.
