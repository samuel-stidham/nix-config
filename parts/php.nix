# Shared PHP 8.5 build with a curated, non-conflicting extension set. Imported by
# both home/languages.nix (the CLI php and composer) and flake.nix (the php-fpm
# process behind nginx), so the served apps and the CLI share one PHP.
#
# The caching stack is apcu, opcache (default), memcached, and redis, which
# coexist. memcache (old) is dropped since it clashes with memcached. igbinary is
# broken in nixpkgs for php85, so msgpack covers serialization. imap and pspell
# are left out. Extensions with no nixpkgs package are dropped: oauth, raphf,
# xmlrpc, zmq, interbase. odbc maps to pdo_odbc and sybase to pdo_dblib.
#
# pdo_dblib is Linux-only here. It is broken for php85 on darwin, and this build
# is imported into the unguarded home.packages in home/languages.nix, which is on
# the aarch64-darwin homeConfigurations path, so an unconditional pdo_dblib aborts
# the darwin eval. Guarding all of languages.nix would leave darwin with no PHP at
# all, so the guard belongs here, on the one broken extension. Linux keeps it.

pkgs:
let
  # TEMPORARY, 2026-10-22. Build PHP 8.5.12 from source ahead of nixpkgs.
  #
  # 8.5.12 fixes CVE-2026-109618 and CVE-2026-109619. Both are unauthenticated
  # remote code execution through php-fpm, and nginx exposes php-fpm on
  # 0.0.0.0:443. nixpkgs master took the bump on 2026-10-21. The flake tracks
  # nixos-unstable, which still carried 8.5.11 a day later because that branch
  # waits on the full Hydra test set.
  #
  # The obvious fix, pinning the whole flake to the nixos-unstable-small commit
  # that has 8.5.12, was tried first and reverted. Chromium 155 is not in the
  # binary cache at that commit, so the switch began compiling Chromium from
  # source. That is hours of CPU for one PHP patch release.
  #
  # Two overrides compose here. overrideAttrs on the buildEnv goes through
  # phpAttrsOverrides, the hook nixpkgs provides for swapping the interpreter
  # source. It rebuilds PHP and then every extension against it, so nothing
  # stays linked to 8.5.11. The hash is the one nixpkgs master records for
  # php-8.5.12.tar.bz2. The cost is one local compile of PHP and its
  # extensions, minutes on this machine.
  #
  # packageOverrides patches the filter extension's tests. 8.5.12 adds three
  # out-of-memory regression tests for CVE-2026-109618, and they run `php -n`
  # without loading the freshly built filter.so, so all three fail and the
  # whole env refuses to build:
  #
  #   filter_input() doesn't reach hard limit [tests/oom_filter_input.phpt]
  #
  # nixpkgs master fixed the harness in php-packages.nix on the same day by
  # appending `-d extension=$PWD/modules/filter.so` to the test command. The
  # locked nixpkgs predates that, so the same substitution is carried here.
  # It patches the tests, never the extension.
  #
  # SELF RETIRING. The version probe hands back plain pkgs.php85 as soon as
  # the locked nixpkgs reaches 8.5.12, so this cannot freeze PHP at 8.5.12
  # and quietly skip later security releases. Delete the whole block once
  # the probe is true, there is nothing left for it to do.
  php =
    if pkgs.lib.versionAtLeast pkgs.php85.version "8.5.12"
    then pkgs.php85
    else
      (pkgs.php85.override {
        packageOverrides = final: prev: {
          extensions = prev.extensions // {
            filter = prev.extensions.filter.overrideAttrs (old: {
              postConfigure = (old.postConfigure or "") + ''
                substituteInPlace \
                  tests/oom_filter_input.phpt \
                  tests/oom_filter_input_array.phpt \
                  tests/oom_filter_default_encoded.phpt \
                  --replace-fail "'-n'," "'-n', '-d', 'extension=$PWD/modules/filter.so',"
              '';
            });
          };
        };
      }).overrideAttrs (_: rec {
        version = "8.5.12";
        src = pkgs.fetchurl {
          url = "https://www.php.net/distributions/php-${version}.tar.bz2";
          hash = "sha256-/7YO3EN87WO1E35JhNs3moERxQBJxxFRDYuVgnfvwag=";
        };
      });
in
php.buildEnv {
  extensions = { all, enabled }: enabled ++ (with all; [
    apcu memcached redis msgpack
    xdebug
    pgsql pdo_pgsql mysqli pdo_mysql pdo_odbc pdo_sqlite sqlite3
    intl gd bcmath bz2 gmp ldap soap xsl zip tidy calendar exif ffi sodium
    gettext dba enchant snmp sockets pcntl
    amqp ast ds imagick mailparse mongodb uuid yaml smbclient
  ]) ++ pkgs.lib.optional (!pkgs.stdenv.hostPlatform.isDarwin) all.pdo_dblib;
  # date.timezone applies to every SAPI built from this php, so the CLI and the
  # php-fpm behind nginx share it. Store all datetimes as UTC in the database and
  # let this timezone drive display and offset math.
  #
  # Xdebug 3 uses port 9003, not the old 9000 that clashed with php-fpm and
  # MinIO. Trigger mode means no overhead until you start a session, so it is
  # safe to leave on. Point your IDE listener at 127.0.0.1:9003.
  extraConfig = ''
    memory_limit = 512M
    date.timezone = America/Kentucky/Monticello

    [xdebug]
    xdebug.mode = develop,debug
    xdebug.client_host = 127.0.0.1
    xdebug.client_port = 9003
    xdebug.start_with_request = trigger
    xdebug.discover_client_host = false
  '';
}
