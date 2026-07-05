# Pre-publish checklist

Run this before any repo flips from private to public. The goal is simple. No
secret value and no private key ever reaches a public repo. Work through every
step. Do not skip the history scan.

## Before you flip the switch

1. Confirm the repo holds references only. Search for the secret var names your
   `.envrc` files export, and confirm each is a `passage show` reference, not a
   value. See `.agents/rules.md`.

2. Confirm no private key is tracked. Look for `id_ed25519`, `id_rsa`, `.pem`,
   and `identities`, and confirm none is committed. Keys live out of band, per
   `SECRETS.md`.

3. Run the fast full-history scan with gitleaks:

   ```
   gitleaks git --redact .
   ```

4. Run the verified deep scan with trufflehog:

   ```
   trufflehog git file://.
   ```

5. If either tool finds a real secret in history, stop. Rotate the credential at
   its source. Do not only scrub it. An exposed secret is burned. Rotation
   replaces the value, which scrubbing alone does not. Re-run both scans after
   rotation.

6. Confirm the git identity resolves as expected in the repo, so the public
   history carries the right name and email:

   ```
   git config user.email
   git config user.signingkey
   ```

7. Confirm `.gitleaks.toml` is present and its allowlist did not hide a real
   finding. The allowlist covers passage references and age recipients only.

## Only then

Flip the repo to public. Keep the pre-commit guard on, so no new secret can land
after the repo is public. The guard is wired in `SCANNING.md`.
