;;; init.el -*- lexical-binding: t; -*-

;; This file controls which Doom modules load. Run `doom sync` after editing it.
;; Evil mode is on through (evil +everywhere), which gives vim and neovim style
;; keybindings across Emacs. Only long-stable modules are enabled here, to keep
;; `doom sync` clean while you settle in.

(doom! :completion
       vertico            ; the search and completion UI
       (corfu +orderless) ; in-buffer completion

       :ui
       doom               ; the default look
       doom-dashboard     ; the startup screen
       hl-todo            ; highlight TODO and FIXME
       modeline           ; a fancy modeline
       ophints            ; highlight the region an operation affects
       (popup +defaults)  ; tame stray windows

       :editor
       (evil +everywhere) ; vim and neovim keybindings, everywhere
       fold               ; folding, vim style
       snippets           ; template expansion

       :emacs
       dired              ; the file manager
       electric           ; smarter indentation
       undo               ; persistent, branching undo
       vc                 ; version control basics

       :checkers
       syntax             ; on-the-fly syntax checking

       :tools
       lookup             ; jump to definition and docs
       magit              ; the git porcelain

       :lang
       emacs-lisp         ; for editing this config
       markdown           ; for the repo docs
       (sh +fish)         ; shell and fish scripts

       :config
       (default +bindings +smartparens))
