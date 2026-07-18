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
pkgs.php85.buildEnv {
  extensions = { all, enabled }: enabled ++ (with all; [
    apcu memcached redis msgpack
    xdebug
    pgsql pdo_pgsql mysqli pdo_mysql pdo_odbc pdo_sqlite sqlite3
    intl gd bcmath bz2 gmp ldap soap xsl zip tidy calendar exif ffi sodium
    gettext dba enchant snmp sockets pcntl
    amqp ast ds imagick mailparse mongodb uuid yaml smbclient
  ]) ++ pkgs.lib.optional (!pkgs.stdenv.isDarwin) all.pdo_dblib;
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
