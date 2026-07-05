# =========================
# General Aliases
# =========================

alias g git
alias c '$VEDITOR'
alias quit exit
alias python python3
alias vim '$EDITOR' # Uncomment if you want nvim instead of vim

# Dotnet NuGet cleanup
alias nugetclean 'dotnet nuget locals --clear all'

# =========================
# Comprehensive eza Aliases (from your zsh config)
# =========================

alias ls 'eza --color=always --git --group-directories-first --sort=type --icons'
alias ll 'eza -algF --color=always --git --group-directories-first --sort=type --icons --time-style=iso'
alias la 'eza -a --color=always --git --group-directories-first --sort=type --icons'
alias l 'eza -F --color=always --git --group-directories-first --sort=type --icons'

# Custom eza aliases
alias lm 'eza -lbg --git --sort=modified' # only directories, sort by modified
alias lfm 'eza -albgf --git --sort=modified' # only files, sort by modified
alias lam 'eza -algF --color=always --git --group-directories-first --sort=modified --icons --time-style=iso' # show all, sort by modified
alias lt 'eza -aT --level=2' # show tree and all files to two levels.
alias lx 'eza -lbhHigUmuSa@ --color=always --git --group-directories-first --sort=type --icons --time-style=iso' # extended eza

# =========================
# Other Useful Aliases (from Garuda defaults and your zsh config)
# =========================
alias cat 'bat --style header --style snip --style changes --style header'

alias .. 'cd ..'
alias ... 'cd ../..'
alias .... 'cd ../../..'
alias ..... 'cd ../../../..'
alias ...... 'cd ../../../../..'

alias grubup 'sudo update-grub'
alias hw 'hwinfo --short'
alias ip 'ip -color'
alias psmem 'ps auxf | sort -nr -k 4'
alias psmem10 'ps auxf | sort -nr -k 4 | head -10'
alias tarnow 'tar -acf '
alias untar 'tar -zxvf '
alias wget 'wget -c '
alias rmpkg 'sudo apt remove'
alias upd 'sudo apt update && sudo apt upgrade -y'

# =========================
# Application and Service Shortcuts
# =========================

# Foundry VTT
alias foundry 'nohup $HOME/foundryvtt/foundryvtt &> /dev/null &'

# Godot
alias gd godot

# MailHog (if installed via Go)
# alias mailhog "$HOME/go/bin/MailHog"

# =========================
# Directory Colors and grep
# =========================
alias dir 'dir --color=auto'
alias vdir 'vdir --color=auto'
alias grep 'rg --color=always'
alias fgrep 'rg -F --color=always'
alias egrep 'rg --color=always'
