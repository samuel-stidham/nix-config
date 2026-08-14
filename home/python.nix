{ pkgs, ... }:

# Python strategy. poetry owns per-project environments. devenv owns the
# scientific stack that used to live in conda, inside the pysci-ai repo
# itself rather than in this machine definition. There is no pyenv.
#
# TOMBSTONE: micromamba was declared here as the planned conda replacement,
# with MAMBA_ROOT_PREFIX pointed at ~/.micromamba. It never held an env.
# The prefix was never created, because pysci-ai moved to devenv on
# 2026-07-23 and the migration never needed mamba. It was removed on
# 2026-08-13 when a nixpkgs bump broke the build: libmamba 2.6.2 fails
# to compile against fmt 12.2.0 with "'format' is not a member of 'fmt'",
# upstream had no fix, and hydra had no cached binary. The obvious fix is
# overriding fmt back to fmt_11. That needs FOUR overrides, because spdlog
# propagates its own fmt: spdlog, libmamba, mamba-cpp, micromamba. Real
# maintenance for a package with zero usage, so removal won.
# Verified: `ls ~/.micromamba` had no such directory on 2026-08-13.

{
  home.packages = with pkgs; [
    python3    # interpreter for tooling and quick scripts
    poetry     # project dependency and virtualenv manager
  ];
}
