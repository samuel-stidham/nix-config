# safetybox: an age-encrypted secrets vault CLI. This is your own tool, and on
# the new machine it replaces passage as the secret store. The crypto family is
# the same (age), so the migration is a concept you already know. The vault is a
# single SQLite database, secrets are held with memguard while in memory, and the
# cobra command set covers init, set, get, reveal, rekey, passwd, exec, and more.
#
# Built straight from the tagged release on GitHub with buildGoModule. Bump the
# version, then update both hashes. The src hash comes from nix flake prefetch,
# and the vendorHash comes from the build error when it is wrong.
pkgs:
let
  version = "4.0.0";
in
pkgs.buildGoModule {
  pname = "safetybox";
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "samuel-stidham";
    repo = "safetybox";
    rev = "v${version}";
    hash = "sha256-4uvHgKUYoN0qpXplABWpAAR+AoXa/Zmvu3Riys0F9mA=";
  };

  vendorHash = "sha256-+hx1UYmKv9Tqqswi3oNt2nSW6WVCzF2FCL0TpskGWKo=";

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
