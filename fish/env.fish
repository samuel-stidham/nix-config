# ================================
# Default Fish Environment Settings
# ================================
set VIRTUAL_ENV_DISABLE_PROMPT 1
# -gx, not -xU. -U writes to ~/.config/fish/fish_variables, which is machine
# state home-manager does not own. The variable then OUTLIVES this file: deleting
# a `set -U` line does not unset it, so an upgraded machine keeps a value a fresh
# install of the same flake never gets. Confirmed present as `SETUVAR --export
# MANPAGER` in fish_variables before this change. That is a parity hole in a repo
# whose whole job is parity. These are plain per-shell settings and want -gx.
# Retracting the four stale universals is a machine change, so it is Sam's call:
#   set -eU MANPAGER; set -eU MANROFFOPT; set -eU LS_COLORS; set -eU GCC_COLORS
set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"
set -gx MANROFFOPT -c

# ================================/
# Personal Settings
# ================================
set -x DEFAULT_USER $USER
# TERM stays pinned to xterm-256color, deliberately, to keep this session's
# appearance identical to the pre-existing setup. Sam asked for the look not to
# change, and unpinning it hands the session to ghostty's xterm-ghostty terminfo.
#
# PARITY NOTE, tracked in the commit queue, not lost. Pinning TERM in a shell rc
# is wrong on Bazzite, inside tmux, over ssh, and in a TTY, because only the
# terminal knows what it is. The honest fix is to unpin it. That changes the
# look, so it waits until Sam opts in rather than being forced here.
set -x TERM xterm-256color
set -x LANG en_US.UTF-8
set -x EDITOR nvim
set -x VEDITOR code
set -x COMPOSER_ALLOW_XDEBUG 1

# The tree root, ~/Code, matching the MacBook whose projects live in ~/Code. The
# casing flip-flopped. a375a03 moved it to ~/code because the old ~/Code pointed
# at nothing on Linux. But the MacBook kept ~/Code, so the two boxes disagreed.
# Standardizing on ~/Code settles it, and the Linux folder was renamed to match.
# On darwin APFS is case insensitive, so ~/Code and ~/code are one inode there
# anyway. Unverified on darwin, no such machine available.
#
# This is the tree ROOT. The identity level below it (dqfan2012, samuel-stidham,
# sandbox) is per repo and deliberately not encoded here.
set -x CODE "$HOME/Code"

# XDG defaults, as FALLBACKS only. These used to be asserted unconditionally,
# which overrode a session that had deliberately set something else. They only
# restate the spec defaults, so `set -q` loses nothing and stops the override.
# XDG_CONFIG_HOME was missing from the set entirely while safetybox depends on it
# for $XDG_CONFIG_HOME/safetybox/identity.age, so the coverage was arbitrary.
set -q XDG_CACHE_HOME; or set -x XDG_CACHE_HOME "$HOME/.cache"
set -q XDG_CONFIG_HOME; or set -x XDG_CONFIG_HOME "$HOME/.config"
set -q XDG_DATA_HOME; or set -x XDG_DATA_HOME "$HOME/.local/share"
set -q XDG_STATE_HOME; or set -x XDG_STATE_HOME "$HOME/.local/state"

# Flameshot needs two hints on Cinnamon X11, or it selects a broken screenshot
# backend. This is measured, not theoretical: removing them broke Flameshot on
# Ubuntu Cinnamon 24.04 LTS. Asserting them everywhere is the other failure,
# because on Bazzite, which is KDE on Wayland, XDG_CURRENT_DESKTOP=X-Cinnamon
# misleads xdg-desktop-portal and QT_QPA_PLATFORM=xcb forces every Qt app onto
# XWayland. So probe the live session and set them only where they hold.
#
# The one hard rule is do not touch these on Wayland. QT_QPA_PLATFORM=xcb is right
# on any X11 session and harmless in a TTY, so it sets whenever this is not
# Wayland. XDG_CURRENT_DESKTOP names Cinnamon only when a Cinnamon session is
# actually running, so it never lies on a GNOME or KDE X11 host either.
#
# HISTORY: the desktop id was once wrongly "Sway", left from a Sway config, and
# Flameshot picked a broken Wayland backend (e8fa642f). That is why the value is
# probed, not hardcoded to any one constant.
if not set -q WAYLAND_DISPLAY; and test "$XDG_SESSION_TYPE" != wayland
    set -x QT_QPA_PLATFORM xcb
    if string match -qi '*cinnamon*' "$XDG_CURRENT_DESKTOP$DESKTOP_SESSION$GDMSESSION"
        set -x XDG_CURRENT_DESKTOP X-Cinnamon
    end
end

# Nix home-manager profile root. Its bin is added to PATH in
# configure_path.fish. This used to say the Nix dev tooling therefore "leads",
# which is false and is measured false in the comment on that line: nix sits at
# positions 10 and 14 of 26 in a real login shell. Do not restate the claim here.
set -x NIX_HOME "$HOME/.nix-profile"

# ================================
# Colors
# ================================
# -gx, not -Ux, for the same reason as MANPAGER above: -U persists outside
# home-manager and cannot be retracted by editing this file.
set -gx LS_COLORS '*~=0;38;2;58;60;78:bd=1;38;2;241;250;140;48;2;40;42;54:ca=0:cd=1;38;2;241;250;140;48;2;40;42;54:di=0;38;2;189;147;249:do=1;38;2;255;121;198;48;2;40;42;54:ex=0;38;2;80;250;123:fi=0;38;2;248;248;242:ln=0;38;2;139;233;253:mh=0:mi=0;38;2;255;85;85;48;2;40;42;54:no=0;38;2;248;248;242:or=1;38;2;255;85;85;48;2;40;42;54:ow=0;38;2;189;147;249;48;2;80;250;123:pi=0;38;2;241;250;140;48;2;40;42;54:rs=0;38;2;255;184;108:sg=0;38;2;40;42;54;48;2;241;250;140:so=1;38;2;255;121;198;48;2;40;42;54:st=0;38;2;248;248;242;48;2;189;147;249:su=0;38;2;248;248;242;48;2;255;85;85:tw=0;38;2;40;42;54;48;2;80;250;123:*.a=0;38;2;80;250;123:*.c=0;38;2;255;184;108:*.d=0;38;2;255;184;108:*.h=0;38;2;255;184;108:*.m=0;38;2;255;184;108:*.o=0;38;2;58;60;78:*.p=0;38;2;255;184;108:*.r=0;38;2;255;184;108:*.t=0;38;2;255;184;108:*.z=1;38;2;255;85;85:*.7z=1;38;2;255;85;85:*.as=0;38;2;255;184;108:*.bc=0;38;2;58;60;78:*.bz=1;38;2;255;85;85:*.cc=0;38;2;255;184;108:*.cp=0;38;2;255;184;108:*.cr=0;38;2;255;184;108:*.cs=0;38;2;255;184;108:*.di=0;38;2;255;184;108:*.el=0;38;2;255;184;108:*.ex=0;38;2;255;184;108:*.fs=0;38;2;255;184;108:*.go=0;38;2;255;184;108:*.gv=0;38;2;255;184;108:*.gz=1;38;2;255;85;85:*.hh=0;38;2;255;184;108:*.hi=0;38;2;58;60;78:*.hs=0;38;2;255;184;108:*.jl=0;38;2;255;184;108:*.js=0;38;2;255;184;108:*.ko=0;38;2;80;250;123:*.kt=0;38;2;255;184;108:*.la=0;38;2;58;60;78:*.ll=0;38;2;255;184;108:*.lo=0;38;2;58;60;78:*.md=0;38;2;255;184;108:*.ml=0;38;2;255;184;108:*.mn=0;38;2;255;184;108:*.nb=0;38;2;255;184;108:*.pl=0;38;2;255;184;108:*.pm=0;38;2;255;184;108:*.pp=0;38;2;255;184;108:*.ps=0;38;2;255;184;108:*.py=0;38;2;255;184;108:*.rb=0;38;2;255;184;108:*.rm=1;38;2;255;184;108:*.rs=0;38;2;255;184;108:*.sh=0;38;2;255;184;108:*.so=0;38;2;80;250;123:*.td=0;38;2;255;184;108:*.ts=0;38;2;255;184;108:*.ui=0;38;2;255;184;108:*.vb=0;38;2;255;184;108:*.wv=0;38;2;139;233;253:*.xz=1;38;2;255;85;85:*.aif=0;38;2;139;233;253:*.ape=0;38;2;139;233;253:*.apk=1;38;2;255;85;85:*.arj=1;38;2;255;85;85:*.asa=0;38;2;255;184;108:*.aux=0;38;2;58;60;78:*.avi=1;38;2;255;184;108:*.awk=0;38;2;255;184;108:*.bag=1;38;2;255;85;85:*.bak=0;38;2;58;60;78:*.bat=0;38;2;80;250;123:*.bbl=0;38;2;58;60;78:*.bcf=0;38;2;58;60;78:*.bib=0;38;2;255;184;108:*.bin=1;38;2;255;85;85:*.blg=0;38;2;58;60;78:*.bmp=0;38;2;255;121;198:*.bsh=0;38;2;255;184;108:*.bst=0;38;2;255;184;108:*.bz2=1;38;2;255;85;85:*.c++=0;38;2;255;184;108:*.cfg=0;38;2;255;184;108:*.cgi=0;38;2;255;184;108:*.clj=0;38;2;255;184;108:*.com=0;38;2;80;250;123:*.cpp=0;38;2;255;184;108:*.css=0;38;2;255;184;108:*.csv=0;38;2;255;184;108:*.csx=0;38;2;255;184;108:*.cxx=0;38;2;255;184;108:*.deb=1;38;2;255;85;85:*.def=0;38;2;255;184;108:*.dll=0;38;2;80;250;123:*.dmg=1;38;2;255;85;85:*.doc=0;38;2;255;184;108:*.dot=0;38;2;255;184;108:*.dox=0;38;2;255;184;108:*.dpr=0;38;2;255;184;108:*.elc=0;38;2;255;184;108:*.elm=0;38;2;255;184;108:*.epp=0;38;2;255;184;108:*.eps=0;38;2;255;121;198:*.erl=0;38;2;255;184;108:*.exe=0;38;2;80;250;123:*.exs=0;38;2;255;184;108:*.fls=0;38;2;58;60;78:*.flv=1;38;2;255;184;108:*.fnt=0;38;2;255;184;108:*.fon=0;38;2;255;184;108:*.fsi=0;38;2;255;184;108:*.fsx=0;38;2;255;184;108:*.gif=0;38;2;255;121;198:*.git=0;38;2;58;60;78:*.gvy=0;38;2;255;184;108:*.h++=0;38;2;255;184;108:*.hpp=0;38;2;255;184;108:*.htc=0;38;2;255;184;108:*.htm=0;38;2;255;184;108:*.hxx=0;38;2;255;184;108:*.ico=0;38;2;255;121;198:*.ics=0;38;2;255;184;108:*.idx=0;38;2;58;60;78:*.ilg=0;38;2;58;60;78:*.img=1;38;2;255;85;85:*.inc=0;38;2;255;184;108:*.ind=0;38;2;58;60;78:*.ini=0;38;2;255;184;108:*.inl=0;38;2;255;184;108:*.ipp=0;38;2;255;184;108:*.iso=1;38;2;255;85;85:*.jar=1;38;2;255;85;85:*.jpg=0;38;2;255;121;198:*.kex=0;38;2;255;184;108:*.kts=0;38;2;255;184;108:*.log=0;38;2;58;60;78:*.ltx=0;38;2;255;184;108:*.lua=0;38;2;255;184;108:*.m3u=0;38;2;139;233;253:*.m4a=0;38;2;139;233;253:*.m4v=1;38;2;255;184;108:*.mid=0;38;2;139;233;253:*.mir=0;38;2;255;184;108:*.mkv=1;38;2;255;184;108:*.mli=0;38;2;255;184;108:*.mov=1;38;2;255;184;108:*.mp3=0;38;2;139;233;253:*.mp4=1;38;2;255;184;108:*.mpg=1;38;2;255;184;108:*.nix=0;38;2;255;184;108:*.odp=0;38;2;255;184;108:*.ods=0;38;2;255;184;108:*.odt=0;38;2;255;184;108:*.ogg=0;38;2;139;233;253:*.org=0;38;2;255;184;108:*.otf=0;38;2;255;184;108:*.out=0;38;2;58;60;78:*.pas=0;38;2;255;184;108:*.pbm=0;38;2;255;121;198:*.pdf=0;38;2;255;184;108:*.pgm=0;38;2;255;121;198:*.php=0;38;2;255;184;108:*.pid=0;38;2;58;60;78:*.pkg=1;38;2;255;85;85:*.png=0;38;2;255;121;198:*.pod=0;38;2;255;184;108:*.ppm=0;38;2;255;121;198:*.pps=0;38;2;255;184;108:*.ppt=0;38;2;255;184;108:*.pro=0;38;2;255;184;108:*.ps1=0;38;2;255;184;108:*.psd=0;38;2;255;121;198:*.pyc=0;38;2;58;60;78:*.pyd=0;38;2;58;60;78:*.pyo=0;38;2;58;60;78:*.rar=1;38;2;255;85;85:*.rpm=1;38;2;255;85;85:*.rst=0;38;2;255;184;108:*.rtf=0;38;2;255;184;108:*.sbt=0;38;2;255;184;108:*.sql=0;38;2;255;184;108:*.sty=0;38;2;58;60;78:*.svg=0;38;2;255;121;198:*.swf=1;38;2;255;184;108:*.swp=0;38;2;58;60;78:*.sxi=0;38;2;255;184;108:*.sxw=0;38;2;255;184;108:*.tar=1;38;2;255;85;85:*.tbz=1;38;2;255;85;85:*.tcl=0;38;2;255;184;108:*.tex=0;38;2;255;184;108:*.tgz=1;38;2;255;85;85:*.tif=0;38;2;255;121;198:*.tml=0;38;2;255;184;108:*.tmp=0;38;2;58;60;78:*.toc=0;38;2;58;60;78:*.tsx=0;38;2;255;184;108:*.ttf=0;38;2;255;184;108:*.txt=0;38;2;255;184;108:*.vcd=1;38;2;255;85;85:*.vim=0;38;2;255;184;108:*.vob=1;38;2;255;184;108:*.wav=0;38;2;139;233;253:*.wma=0;38;2;139;233;253:*.wmv=1;38;2;255;184;108:*.xcf=0;38;2;255;121;198:*.xlr=0;38;2;255;184;108:*.xls=0;38;2;255;184;108:*.xml=0;38;2;255;184;108:*.xmp=0;38;2;255;184;108:*.yml=0;38;2;255;184;108:*.zip=1;38;2;255;85;85:*.zsh=0;38;2;255;184;108:*.zst=1;38;2;255;85;85:*TODO=1;38;2;255;184;108:*hgrc=0;38;2;255;184;108:*.bash=0;38;2;255;184;108:*.conf=0;38;2;255;184;108:*.dart=0;38;2;255;184;108:*.diff=0;38;2;255;184;108:*.docx=0;38;2;255;184;108:*.epub=0;38;2;255;184;108:*.fish=0;38;2;255;184;108:*.flac=0;38;2;139;233;253:*.h264=1;38;2;255;184;108:*.hgrc=0;38;2;255;184;108:*.html=0;38;2;255;184;108:*.java=0;38;2;255;184;108:*.jpeg=0;38;2;255;121;198:*.json=0;38;2;255;184;108:*.less=0;38;2;255;184;108:*.lisp=0;38;2;255;184;108:*.lock=0;38;2;58;60;78:*.make=0;38;2;255;184;108:*.mpeg=1;38;2;255;184;108:*.opus=0;38;2;139;233;253:*.orig=0;38;2;58;60;78:*.pptx=0;38;2;255;184;108:*.psd1=0;38;2;255;184;108:*.psm1=0;38;2;255;184;108:*.purs=0;38;2;255;184;108:*.rlib=0;38;2;58;60;78:*.sass=0;38;2;255;184;108:*.scss=0;38;2;255;184;108:*.tbz2=1;38;2;255;85;85:*.tiff=0;38;2;255;121;198:*.toml=0;38;2;255;184;108:*.webm=1;38;2;255;184;108:*.webp=0;38;2;255;121;198:*.woff=0;38;2;255;184;108:*.xbps=1;38;2;255;85;85:*.xlsx=0;38;2;255;184;108:*.yaml=0;38;2;255;184;108:*.cabal=0;38;2;255;184;108:*.cache=0;38;2;58;60;78:*.class=0;38;2;58;60;78:*.cmake=0;38;2;255;184;108:*.dyn_o=0;38;2;58;60;78:*.ipynb=0;38;2;255;184;108:*.mdown=0;38;2;255;184;108:*.patch=0;38;2;255;184;108:*.scala=0;38;2;255;184;108:*.shtml=0;38;2;255;184;108:*.swift=0;38;2;255;184;108:*.toast=1;38;2;255;85;85:*.xhtml=0;38;2;255;184;108:*README=0;38;2;255;184;108:*passwd=0;38;2;255;184;108:*shadow=0;38;2;255;184;108:*.config=0;38;2;255;184;108:*.dyn_hi=0;38;2;58;60;78:*.flake8=0;38;2;255;184;108:*.gradle=0;38;2;255;184;108:*.groovy=0;38;2;255;184;108:*.ignore=0;38;2;255;184;108:*.matlab=0;38;2;255;184;108:*COPYING=0;38;2;255;184;108:*INSTALL=0;38;2;255;184;108:*LICENSE=0;38;2;255;184;108:*TODO.md=1;38;2;255;184;108:*.desktop=0;38;2;255;184;108:*.gemspec=0;38;2;255;184;108:*Doxyfile=0;38;2;255;184;108:*Makefile=0;38;2;255;184;108:*TODO.txt=1;38;2;255;184;108:*setup.py=0;38;2;255;184;108:*.DS_Store=0;38;2;58;60;78:*.cmake.in=0;38;2;255;184;108:*.fdignore=0;38;2;255;184;108:*.kdevelop=0;38;2;255;184;108:*.markdown=0;38;2;255;184;108:*.rgignore=0;38;2;255;184;108:*COPYRIGHT=0;38;2;255;184;108:*README.md=0;38;2;255;184;108:*configure=0;38;2;255;184;108:*.gitconfig=0;38;2;255;184;108:*.gitignore=0;38;2;255;184;108:*.localized=0;38;2;58;60;78:*.scons_opt=0;38;2;58;60;78:*CODEOWNERS=0;38;2;255;184;108:*Dockerfile=0;38;2;255;184;108:*INSTALL.md=0;38;2;255;184;108:*README.txt=0;38;2;255;184;108:*SConscript=0;38;2;255;184;108:*SConstruct=0;38;2;255;184;108:*.gitmodules=0;38;2;255;184;108:*.synctex.gz=0;38;2;58;60;78:*.travis.yml=0;38;2;255;184;108:*INSTALL.txt=0;38;2;255;184;108:*LICENSE-MIT=0;38;2;255;184;108:*MANIFEST.in=0;38;2;255;184;108:*Makefile.am=0;38;2;255;184;108:*Makefile.in=0;38;2;58;60;78:*.applescript=0;38;2;255;184;108:*.fdb_latexmk=0;38;2;58;60;78:*CONTRIBUTORS=0;38;2;255;184;108:*appveyor.yml=0;38;2;255;184;108:*configure.ac=0;38;2;255;184;108:*.clang-format=0;38;2;255;184;108:*.gitattributes=0;38;2;255;184;108:*.gitlab-ci.yml=0;38;2;255;184;108:*CMakeCache.txt=0;38;2;58;60;78:*CMakeLists.txt=0;38;2;255;184;108:*LICENSE-APACHE=0;38;2;255;184;108:*CONTRIBUTORS.md=0;38;2;255;184;108:*.sconsign.dblite=0;38;2;58;60;78:*CONTRIBUTORS.txt=0;38;2;255;184;108:*requirements.txt=0;38;2;255;184;108:*package-lock.json=0;38;2;58;60;78:*.CFUserTextEncoding=0;38;2;58;60;78'
set -gx GCC_COLORS 'error=01;91:warning=01;95:note=01;96:caret=01;92:locus=01;94:quote=01;93'

# REMOVED: `if not set -q LS_COLORS; set -Ux LS_COLORS (vivid generate dracula); end`
#
# Dead twice over. The guard could never be true, because the line above sets
# LS_COLORS unconditionally three lines earlier, so vivid never ran. And vivid is
# not installed and is packaged in no module here: `command -v vivid` finds
# nothing, and vivid appears in no .nix file in this repo. So it was a false
# branch calling a missing binary.
#
# If the vivid path is ever wanted, it needs two things, not one: package vivid
# in a module, and delete the literal LS_COLORS above so the guard can fire.

# ================================
# DOTNET
# The SDK comes from Nix, whose dotnet wrapper self-resolves its own root, so
# DOTNET_ROOT is intentionally unset (pointing it at ~/.dotnet was wrong, that is
# not an SDK). DOTNET_INSTALL keeps global dotnet tools (e.g. godotenv, which
# lives in ~/.dotnet/tools) on PATH.
# ================================
set -x DOTNET_CLI_TELEMETRY_OPTOUT 1
set -x DOTNET_ROLL_FORWARD_TO_PRERELEASE 1
set -x DOTNET_INSTALL "$HOME/.dotnet/tools"

# ================================
# Fish Configuration
# ================================
set -x FISH_CONFIG "$HOME/fish"

# ================================
# fzf Setup
# ================================
set -x FZF_DEFAULT_COMMAND 'rg --no-messages --files --no-ignore --hidden --follow --glob "!.git/*"'
set -x FZF_DEFAULT_OPTS "--no-separator --layout=reverse --inline-info"
set -x _ZO_FZF_OPTS "--no-sort --keep-right --height=50% --info=inline --layout=reverse --exit-0 --select-1 --bind=ctrl-z:ignore --preview='\command exa --long --all {2..}' --preview-window=right"

# ================================
# Godot
# ================================
set -x GODOT "$HOME/.config/godotenv/godot/bin/godot"

# ================================
# Golang (go is from Nix, which sets its own GOROOT)
# ================================
set -x GOPATH "$HOME/go"
# REMOVED: `set -x GOPROJECTS "$CODE/go-projects"`
#
# It inherited the broken $CODE above and pointed at nothing. `go-projects` does
# not exist anywhere under ~/Code or ~/go, and a375a03 records why: the old tree
# organized by LANGUAGE, 20 of 25 language folders were empty, and the taxonomy
# was replaced by identity. A per-language Go folder has no slot in the new
# layout, so there is no honest value to give this variable.
#
# NOT a silent guess: reinstating it means naming an identity, for example
# $CODE/samuel-stidham. That is Sam's call, not this file's.
set -x GOPRIVATE "github.com/dqfan2012"

# ================================
# pnpm
# ================================
# pnpm is NOT from Nix, unlike node, bun and deno beside it in home/languages.nix.
# It comes from get.pnpm.io so it can `pnpm self-update`, the same trade as Claude
# Code and the AWS CLI. See the pnpm_cli function in bootstrap.sh for the argument.
#
# DECLARED HERE RATHER THAN LEFT TO THE INSTALLER, which is the whole point. pnpm's
# installer normally writes PNPM_HOME and a PATH line into a shell rc, and for fish
# its own documentation names $HOME/.config/fish/config.fish. That file is a read
# only symlink into the Nix store on this machine, generated by home-manager, so the
# installer cannot own it and must not try. bootstrap.sh therefore passes this exact
# value to the installer and redirects its rc write to ~/.profile.
#
# The two must agree. Change this path and pnpm_cli in bootstrap.sh is wrong, and
# pnpm's global packages land somewhere PATH does not look. They are a pair.
set -x PNPM_HOME "$HOME/.local/share/pnpm"

# ================================
# Savvy
# ================================
set -x SAVVY_HOME "$HOME/.savvy"

# ================================
# Starship Prompt
# ================================
set -x STARSHIP_CACHE "$HOME/.cache/starship"
# STARSHIP_CONFIG stays pointed at the hand-written prompt, deliberately, to keep
# the prompt identical to the pre-existing setup. Sam asked for the look not to
# change, and dropping this override hands the prompt to the flake's generated
# catppuccin config instead.
#
# PARITY NOTE, tracked in the commit queue, not lost. theme.nix enables
# programs.starship and catppuccin.starship and builds a prompt, but this
# override wins, so a fresh install of any distro gets a different prompt because
# that hand-written file does not exist there. The real fix is to move this
# file's content into theme.nix so every distro renders the same prompt. That is
# Sam's call, so the override is kept until he opts in.
set -x STARSHIP_CONFIG "$HOME/.config/starship/starship.toml"

# ================================
# TeX Live
# ================================
# TeX Live installs one tree per year. The year was hardcoded to 2026: correct
# today, a stale tree the day 2027 lands, and PATH would silently keep pointing
# at the old one. Probe for the newest instead. The glob sorts ascending, so the
# last match wins, and it matches nothing when TeX Live is absent, leaving
# TEXLIVE_HOME unset rather than pointing at a directory that is not there.
#
# DO NOT "SIMPLIFY" THIS TO A BRACKET GLOB. The first attempt at this probe was
# `for dir in /usr/local/texlive/[0-9][0-9][0-9][0-9]`, which is a bash and zsh
# habit. FISH HAS NO BRACKET CHARACTER CLASSES. It supports *, ** and ? only, so
# the pattern is a literal string, matches nothing, and fish hands the unexpanded
# pattern to the loop body. TEXLIVE_HOME then ends up empty and texlive silently
# leaves PATH. It survived its own test only because the test shell had inherited
# TEXLIVE_HOME from a parent, so the echo printed the inherited value and looked
# like a pass. Verified: `for dir in /usr/local/texlive/[0-9][0-9][0-9][0-9]`
# yields one iteration, the literal `/usr/local/texlive/[0-9][0-9][0-9][0-9]`.
#
# So the year filter is `string match -r`, a fish builtin, not a glob. It is also
# what keeps `texmf-local`, the other entry in that directory, out.
for dir in /usr/local/texlive/*
    string match -qr '/\d{4}$' "$dir"; and test -d "$dir/bin"
    and set -gx TEXLIVE_HOME "$dir"
end

# MANPATH and INFOPATH used to read:
#   set -gx MANPATH $MANPATH "$MANPATH:$TEXLIVE_HOME/texmf-dist/doc/man"
# $MANPATH was expanded TWICE, once as a list and once inside the quoted string.
# Both are fish path variables, so the quoted half colon-joined and re-split, and
# every existing entry got duplicated. It is exported and inherited with no
# guard, so it also grew on every nested shell. Measured with MANPATH unset at
# the start, sourcing three times: 11 elements, where 2 is correct. The live
# login shell carries 5. `man` still worked, so nobody looked.
#
# THE OBVIOUS FIX IS WRONG AND BREAKS man. Dropping the duplicate to
# `set -gx MANPATH $MANPATH "$m"` looks right and is a silent regression. An
# EMPTY element in MANPATH is load bearing: it is what tells man to splice in its
# own default search path. The old bug produced that empty element by accident,
# via the colon in the quoted half when MANPATH was unset. Measured here, MANPATH
# unset beforehand, counting the directories `manpath` then resolves:
#   (no MANPATH at all)                -> 8 dirs, the baseline
#   set -gx MANPATH $MANPATH "$m"      -> 1 dir. MANPATH=/usr/local/.../man and
#                                         EVERY other man page is gone
#   set -gx MANPATH $MANPATH "" "$m"   -> 9 dirs. MANPATH=:/usr/local/.../man,
#                                         the baseline 8 plus texlive. Correct.
# So the empty element is written explicitly now, on purpose, and the `contains`
# guard stops the growth: 2 elements after three sources, down from 11.
if set -q TEXLIVE_HOME
    set -l texman "$TEXLIVE_HOME/texmf-dist/doc/man"
    if test -d "$texman"; and not contains "$texman" $MANPATH
        set -gx MANPATH $MANPATH "" "$texman"
    end

    set -l texinfo "$TEXLIVE_HOME/texmf-dist/doc/info"
    if test -d "$texinfo"; and not contains "$texinfo" $INFOPATH
        set -gx INFOPATH $INFOPATH "" "$texinfo"
    end
end

# ================================
# Zig and ZLS
# ================================
set -gx ZLS_HOME "$HOME/zls"

# ================================
# Nix (home-manager)
# ================================
# The Nix installer wrote /etc/fish/conf.d/nix.fish, which sources this same
# profile. This block is a backup so nix stays on PATH if that file is removed,
# for example by the 26.04 upgrade. It is guarded so it never sources twice.
if not set -q __NIX_ENV_SOURCED
    if test -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish'
        set -gx __NIX_ENV_SOURCED 1
        source '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish'
    end
end

# ================================
# Source Additional Configuration
# ================================
# Nothing is sourced here now. home/fish.nix sources the whole fish tree in one
# place, in dependency order, so every file loads exactly once. Sourcing aliases
# and functions from here too would load them a second time in an interactive
# shell. See the shellInit block in home/fish.nix.
