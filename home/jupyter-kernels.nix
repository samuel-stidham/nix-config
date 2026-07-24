{ pkgs, lib, ... }:

# Jupyter kernels that are not Python.
#
# WHY THIS MODULE EXISTS. Every kernel on this machine was installed by hand,
# outside Nix, and nothing recorded that it happened. On 2026-07-23 the launcher
# listed three kernels and only one of them worked. `Python (pysci-ai)` pointed
# at ~/miniconda3/envs/pysci-ai/bin/python3, an interpreter deleted when conda
# was retired. It still appeared in the launcher, still had a friendly name, and
# died on click. Two others were already gone without trace: xeus-cling for C++
# and kotlin-jupyter-kernel from the jetbrains channel, both `mamba install`ed
# and both removed with conda. Shell history was the only surviving record.
#
# A kernelspec is a path to an interpreter plus a display name. Nothing
# validates the path. A stale one is invisible until a notebook fails to start,
# which is the silent-failure shape this repo treats as worse than a crash.
# So anything reachable from a notebook is declared here or it does not exist.
#
# The PYTHON kernel is deliberately NOT here. It lives inside the pysci-ai
# devenv venv, which owns its interpreter and its own ipykernel, and devenv
# rebuilds it when requirements.txt or the interpreter changes. Declaring a
# python kernel here would point notebooks at a Nix python with none of the
# scientific stack, which is precisely the wrong-environment bug above.

let
  # ── RAPAIO JUPYTER KERNEL (Java) ───────────────────────────────────
  # Not in nixpkgs. Verified on 2026-07-23:
  #   nix eval nixpkgs#rapaio-jupyter-kernel.name
  #   error: flake 'flake:nixpkgs' does not provide attribute ...
  # So the release jar is fetched and pinned by hash instead.
  #
  # Pinned at 3.0.2 because that is the version already proven working here,
  # installed 2026-03-11. Upstream has since shipped 3.0.4. Bumping is a
  # separate change with its own hash, not a drive-by.
  rjkVersion = "3.0.2";

  rjkJar = pkgs.fetchurl {
    url = "https://github.com/padreati/rapaio-jupyter-kernel/releases/download/${rjkVersion}/rapaio-jupyter-kernel-${rjkVersion}.jar";
    hash = "sha256-xi/pUWMBcTi348j6occZpD66G+Tks3gznOKyUR8KLz0=";
  };

  # PINNED JDK, not a bare `java`. The installer-written kernelspec had
  # "argv": ["java", ...], which resolves through whatever PATH the Jupyter
  # server inherited. That server is launched from inside the pysci-ai devenv,
  # and devenv puts its own toolchain on PATH, so the JVM running the kernel
  # was decided by shell state rather than by anything declared. Naming the
  # store path removes the question.
  #
  # temurin-21 is the default in jdks.nix and it is enough. Verified 2026-07-23
  # by running the jar under temurin 21, 25, and 26: none threw
  # UnsupportedClassVersionError, so the jar's class files predate 22.
  rjkJdk = pkgs.temurin-bin-21;

  # The env block is upstream's own defaults, written by `-i -auto`. It is
  # reproduced verbatim rather than trimmed, so this kernelspec behaves exactly
  # like the hand-installed one it replaces. RJK_MIMA_CACHE is relative on
  # purpose upstream, so the cache lands beside the notebook.
  rjkKernel = pkgs.writeText "rjk-kernel.json" (builtins.toJSON {
    argv = [ "${rjkJdk}/bin/java" "-jar" "${rjkJar}" "{connection_file}" ];
    display_name = "Java (rjk ${rjkVersion})";
    language = "java";
    interrupt_mode = "message";
    env = {
      RJK_CLASSPATH = "";
      RJK_COMPILER_OPTIONS = "";
      RJK_INIT_SCRIPT = "";
      RJK_TIMEOUT_MILLIS = "-1";
      RJK_MIMA_CACHE = "mima_cache";
    };
  });

  # ── XEUS-CPP (C and C++) ───────────────────────────────────────────
  # REPLACES xeus-cling, which is how C++ notebooks worked here until conda
  # was retired. xeus-cling is not coming back, and nixpkgs says so on eval:
  #   error: 'xeus-cling' has been removed: it is unmaintained upstream.
  #          Use 'xeus-cpp' (a clang-repl/CppInterOp-based successor) instead
  # So this is a successor rather than a restoration. cling is gone as the
  # engine, clang-repl drives it now, and the C kernels are new. Expect
  # different behaviour on anything that leaned on cling specifics.
  #
  # SIX of the package's EIGHT kernelspecs are wired up. xc23-omp and
  # xcpp23-omp are deliberately left out. Their argv carries CMake's
  # not-found sentinel where the OpenMP flag belongs:
  #   "-std=c++23","NOTFOUND","-D_LIBCPP_DISABLE_AVAILABILITY"
  # The build did not find OpenMP, so those two advertise a feature the
  # binary does not have. Whether they ALSO fail is unknown. Starting xcpp
  # with and without that argument on 2026-07-23 printed identical output,
  # so it may simply be ignored. Mislabelled is reason enough here. This
  # module exists because a kernel that looks right in the launcher and is
  # not right is the exact failure being cleaned up.
  xcppKernels = [ "xc11" "xc17" "xc23" "xcpp17" "xcpp20" "xcpp23" ];

  # Whole kernelspec directories are linked, not rebuilt. Upstream's argv
  # already names absolute store paths for xcpp, its clang resource dir, and
  # its include tree, so there is nothing here that PATH could get wrong and
  # nothing worth restating. This differs from the Java kernel above only
  # because that one shipped a bare "java" that needed pinning.
  xcppKernelFiles = lib.listToAttrs (map
    (k: lib.nameValuePair ".local/share/jupyter/kernels/${k}" {
      source = "${pkgs.xeus-cpp}/share/jupyter/kernels/${k}";
    })
    xcppKernels);
in
{
  # GUARDED ON LINUX, for the same reason jdks.nix is. The flake declares
  # aarch64-darwin and applies this module too, and the whole temurin set there
  # is Linux-only. Jupyter also reads a different data directory on darwin
  # (~/Library/Jupyter), so this path would be wrong there even if it evaluated.
  home.file = lib.mkIf pkgs.stdenv.isLinux ({
    ".local/share/jupyter/kernels/rapaio-jupyter-kernel/kernel.json".source =
      rjkKernel;
  } // xcppKernelFiles);
}
