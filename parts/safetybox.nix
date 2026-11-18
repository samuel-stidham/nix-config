# safetybox: an age-encrypted secrets vault CLI. This is your own tool, and on
# the new machine it replaces passage as the secret store. The crypto family is
# the same (age), so the migration is a concept you already know. The vault is a
# single SQLite database, secrets are held with memguard while in memory, and the
# cobra command set covers init, set, get, reveal, rekey, passwd, exec, and more.
#
# Built straight from the tagged release on GitHub with buildGo127Module. Bump
# the version, then update both hashes. The src hash comes from nix flake
# prefetch, and the vendorHash comes from the build error when it is wrong.
#
# WHY buildGo127Module and not buildGoModule. safetybox 4.0.1 raised its go.mod
# floor to 1.27.0. The plain builder uses nixpkgs' default Go, which was 1.26.10
# on 2026-11-18, and the vendor step died with:
#   go: go.mod requires go >= 1.27.0 (running go 1.26.10; GOTOOLCHAIN=local)
# buildGo127Module uses go_1_27, 1.27.3 that day, which the binary cache has.
# Return to buildGoModule once the nixpkgs default Go reaches 1.27.
pkgs:
let
  version = "4.0.1";
in
pkgs.buildGo127Module {
  pname = "safetybox";
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "samuel-stidham";
    repo = "safetybox";
    rev = "v${version}";
    hash = "sha256-s7t+3GtCzN/irS0JNB+4GetGVl0JhA1CvpWBlLSp2qM=";
  };

  vendorHash = "sha256-aploEP3n2Yf0EQ29Lmwbm4BigYr2EDJuahnqoyRMzZs=";

  # Match the goreleaser build. CGO is off (memguard, modernc sqlite, and age are
  # all pure Go), and the version is stamped into main.version with the leading v
  # that goreleaser uses, so `safetybox --version` reports the tag, not dev.
  env.CGO_ENABLED = "0";
  ldflags = [ "-s" "-w" "-X main.version=v${version}" ];

  meta = with pkgs.lib; {
    description = "age-encrypted secrets vault CLI, replaces passage on this machine";
    homepage = "https://github.com/samuel-stidham/safetybox";
    license = licenses.mit;
    mainProgram = "safetybox";
    platforms = platforms.unix;
  };
}
