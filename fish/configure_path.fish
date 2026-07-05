if not set -q SET_PATH_SOURCED
    set -x SET_PATH_SOURCED 1

    # Texlive
    add_to_path "$TEXLIVE_HOME/bin/x86_64-linux"

    # Savvy
    add_to_path "$SAVVY_HOME/bin"

    # PHP (Composer global)
    add_to_path "$HOME/.config/composer/vendor/bin"

    # JetBrains Toolbox
    add_to_path "$HOME/.local/share/JetBrains/Toolbox/scripts"

    # Golang (GOPATH bin and go install SDKs). go itself is from Nix.
    add_to_path "$GOPATH/bin"
    add_to_path "$HOME/sdk"

    # .NET global tools. The dotnet SDK itself is from Nix and already on PATH;
    # this only adds ~/.dotnet/tools (godotenv, etc.).
    add_to_path "$DOTNET_INSTALL"

    # local binaries
    add_to_path "$HOME/.local/bin"
    add_to_path "$HOME/bin"

    # Nix home-manager profile. Added last so add_to_path prepends it last,
    # leaving it first on PATH. The Nix dev tooling then leads over apt, cargo,
    # conda, and the manual installs.
    add_to_path "$NIX_HOME/bin"
end
