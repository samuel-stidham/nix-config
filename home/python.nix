{ pkgs, ... }:

# Python strategy. poetry owns per-project environments. micromamba owns the
# scientific stacks that used to live in conda. There is no pyenv. The existing
# miniconda install and the pysci-ai env migrate to micromamba during the
# PERFORM phase, they are not touched now.

{
  home.packages = with pkgs; [
    python3    # interpreter for tooling and quick scripts
    poetry     # project dependency and virtualenv manager
    micromamba # replacement for conda and mamba, owns pysci-ai style stacks
  ];

  # micromamba needs a root prefix for its environments. Point it at a stable
  # location so environments survive a home-manager switch.
  home.sessionVariables = {
    MAMBA_ROOT_PREFIX = "$HOME/.micromamba";
  };
}
