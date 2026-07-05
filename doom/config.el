;;; config.el -*- lexical-binding: t; -*-

;; Personal Doom settings. Evil mode itself is enabled in init.el. This file is
;; for preferences on top of it.

(setq user-full-name "Samuel Stidham"
      user-mail-address "dqfan2012@gmail.com")

;; Catppuccin Frappe, to match the rest of the system.
(setq catppuccin-flavor 'frappe)
(setq doom-theme 'catppuccin)

;; Relative line numbers, so vim motions like 5j read naturally.
(setq display-line-numbers-type 'relative)

;; A few evil comforts. Doom already sets sane evil defaults, these just tune it.
(after! evil
  (setq evil-want-fine-undo t          ; undo in smaller steps, like neovim
        evil-kill-on-visual-paste nil)) ; do not clobber the clipboard on paste
