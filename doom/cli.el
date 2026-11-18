;;; cli.el -*- lexical-binding: t; -*-

;; Doom's CLI loads this file, and Emacs itself never does. It configures
;; `doom ci hook commit-msg', the commit linter that the global git
;; commit-msg hook runs in every repo.
;;
;; The linter ships with scopes for Doom's own repo only, so it rejects
;; ordinary scopes such as `deps'. This sets the list for every project
;; under ~/Code.
;;
;; bin/doom-ci declares `doom-ci-commit-scopes' with `defvar', which does
;; not replace a value that is already set. This file loads first, so the
;; value below is the whole list, not an addition to the default. The two
;; symbols at the end are Doom's own predicates and must stay:
;;
;;   `doom-ci-enforce-scopeless-types' rejects a scope on bump, merge,
;;   release, and revert commits.
;;   `doom-ci-module-scopes' accepts any Doom module name, such as `magit'.
;;
;; Several scopes in one commit must be comma-separated and sorted, as in
;; `fix(deps,docs): ...'. The linter enforces the order.

(setq doom-ci-commit-scopes
      '(;; Generic, valid in any project.
        "a11y" "api" "assets" "auth" "bench" "build" "changelog" "ci" "cli"
        "config" "core" "db" "deps" "dependencies" "dev" "docker" "docs"
        "documentation" "examples" "hooks" "i18n" "infra" "license" "lint"
        "make" "makefile" "perf" "readme" "release" "scripts" "security"
        "style" "test" "tests" "tooling" "types" "ui" "ux" "vendor"

        ;; Languages and toolchains.
        "c" "cmake" "cpp" "csharp" "go" "java" "js" "nix" "php" "python"
        "rust" "shell" "ts"

        ;; Common source layout.
        "cmd" "include" "internal" "lib" "src"

        ;; safetybox and safetybox-rs: packages, then verbs.
        "envelope" "identity" "logging" "secret" "vault"
        "delete" "disable" "exec" "get" "init" "list" "migrate" "passwd"
        "purge" "rekey" "reveal" "set" "show" "stale"
        "envname" "output" "prompt"

        ;; nix-config.
        "backup" "bootstrap" "btrfs" "certs" "dns" "doom" "emacs" "fish"
        "flake" "fonts" "git" "home" "jdks" "languages" "nvim" "parts"
        "samba" "secrets" "steam" "syncthing" "terminals" "theme"

        ;; Web and app projects: grocery-list, pacer, atm10-guide, php-repl.
        "backend" "components" "data" "database" "deploy" "frontend"
        "overlay" "repl" "server" "tauri" "web"

        ;; Infrastructure: infra-backups, atm10-guide.
        "atlantis" "bucket" "terraform" "tofu"

        ;; Python environments: pysci-ai and friends.
        "devenv" "kernels" "requirements"

        ;; catkins, retroarch-presence.
        "bedrock" "contrib" "presence" "tools"

        ;; Art and game projects: cat-scientist, witchy-catgirl.
        "blender" "exports" "textures" "unity"

        ;; cs-degree-journey.
        "bachelors" "masters" "schedule"

        ;; Doom's own predicates. Keep these last. See the note above.
        doom-ci-enforce-scopeless-types
        doom-ci-module-scopes))
