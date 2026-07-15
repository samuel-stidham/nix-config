{ config, pkgs, lib, ... }:

# The one nginx. Owns port 443 and serves everything with a name.
#
# WHY IT LIVES HERE AND NOT IN THE sites STACK
#
# nginx used to be a process in `nix run .#sites`, started by hand and gone when
# zellij closed. That was fine when it only served dev sites. It is not fine now
# that it fronts Forgejo, which is always-on infrastructure: HTTPS to your git
# server should not depend on a terminal being open. So nginx is a systemd user
# service, and php-fpm stays in the dev stack where it belongs.
#
# The consequence is deliberate: when the dev stack is down, nginx is still up
# and a dev site returns 502. That is the honest answer ("php is not running")
# rather than connection refused, and Forgejo is unaffected.
#
# WHY ONE NGINX AND NOT TWO
#
# A listener on 0.0.0.0:443 blocks every specific-IP bind on the box. Verified,
# not assumed: binding 100.68.26.36:443 while nginx held 0.0.0.0:443 returned
# EADDRINUSE. So port 443 has exactly one owner, and splitting by address only
# works if nothing takes 0.0.0.0. Since dev sites want loopback and the home lab
# names want the Tailscale address, one nginx on 0.0.0.0 serving both is simpler
# than two nginxes negotiating over addresses.
#
# THE TWO NAMING SCHEMES
#
#   <site>.test                     -> dnsmasq, 127.0.0.1, self-signed cert
#   <site>.home.samuelstidham.me    -> cloudflare, 100.68.26.36, real wildcard
#
# Both serve the same files out of ~/sites/<site>. .test stays because it works
# with no internet at all, which the .home. names cannot: they need a real DNS
# lookup. .home. exists because it can do two things .test never will, namely
# carry a real certificate and be reachable from the MacBook. No CA will ever
# issue for .test, and 127.0.0.1 means nothing on another machine.
#
# forgejo. and atlantis. are the same scheme, they just proxy instead of serving
# files. Tailscale gives a machine one MagicDNS name; this is what turns that
# into as many service names as we want.

let
  siteRoot = "${config.home.homeDirectory}/sites";
  runDir = "${config.home.homeDirectory}/.local/share/dev-services";
  certDir = "${runDir}/certs";
  homeDomain = "home.samuelstidham.me";

  # Shared serving logic for a dev site, included by every vhost that serves
  # files. The driver picks the document root: public/ (Laravel, Symfony 4+,
  # Bedrock), then web/ (Symfony 2/3, older Drupal), else the site root
  # (WordPress, plain PHP, static HTML).
  siteBody = pkgs.writeText "nginx-site-body.conf" ''
    set $base ${siteRoot}/$site;
    set $sroot $base;
    if (-d $base/public) { set $sroot $base/public; }
    if (-d $base/web)    { set $sroot $base/web; }
    root $sroot;

    index index.php index.html index.htm;
    charset utf-8;

    location / {
      try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
      # php-fpm lives in the dev stack. When that is down this socket does not
      # exist and nginx returns 502, which is the correct and legible failure.
      fastcgi_pass unix:${runDir}/php-fpm/php-fpm.sock;
      fastcgi_index index.php;
      include ${pkgs.nginx}/conf/fastcgi_params;
      fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
      fastcgi_param PATH_INFO $fastcgi_path_info;
      fastcgi_param HTTPS $https if_not_empty;
    }
    location ~ /\.(?!well-known).* { deny all; }
  '';

  # Shared proxy headers.
  #
  # X-Forwarded-Proto: without it Forgejo believes the request arrived over plain
  # http and redirects https clients back to http, which loops.
  #
  # Upgrade/Connection: websockets. Atlantis streams live plan and apply output
  # to /jobs/<id> over a websocket, and nginx does not forward an upgrade unless
  # told to. Without these the page loads and stays blank forever, which looks
  # like atlantis is broken rather than the proxy dropping the socket. HTTP/1.1
  # is required too, since proxy_http_version defaults to 1.0 and 1.0 has no
  # upgrade mechanism.
  proxyHeaders = pkgs.writeText "nginx-proxy-headers.conf" ''
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_http_version 1.1;
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        $connection_upgrade;
    proxy_read_timeout 300s;
  '';

  nginxConf = pkgs.writeText "nginx.conf" ''
    daemon off;
    pid ${runDir}/nginx/nginx.pid;
    error_log ${runDir}/nginx/error.log;
    events { worker_connections 1024; }
    http {
      include ${pkgs.nginx}/conf/mime.types;
      default_type application/octet-stream;
      access_log ${runDir}/nginx/access.log;
      client_body_temp_path ${runDir}/nginx/tmp/client_body;
      proxy_temp_path ${runDir}/nginx/tmp/proxy;
      fastcgi_temp_path ${runDir}/nginx/tmp/fastcgi;
      uwsgi_temp_path ${runDir}/nginx/tmp/uwsgi;
      scgi_temp_path ${runDir}/nginx/tmp/scgi;

      # Websocket plumbing. Connection: upgrade only when the client actually
      # asked for an upgrade, otherwise close. Sending "upgrade" unconditionally
      # breaks ordinary requests.
      map $http_upgrade $connection_upgrade {
        default upgrade;
        ""      close;
      }

      # ---- forgejo ----------------------------------------------------------
      server {
        listen 443 ssl;
        http2 on;
        server_name forgejo.${homeDomain};
        ssl_certificate     ${certDir}/${homeDomain}.crt;
        ssl_certificate_key ${certDir}/${homeDomain}.key;
        ssl_protocols TLSv1.2 TLSv1.3;

        # git pushes objects through here. The default 1m would fail a large
        # push with a 413, which looks like a git bug and is not.
        client_max_body_size 0;

        location / {
          proxy_pass http://127.0.0.1:3000;
          include ${proxyHeaders};
        }
      }

      # ---- atlantis ---------------------------------------------------------
      server {
        listen 443 ssl;
        http2 on;
        server_name atlantis.${homeDomain};
        ssl_certificate     ${certDir}/${homeDomain}.crt;
        ssl_certificate_key ${certDir}/${homeDomain}.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        location / {
          proxy_pass http://127.0.0.1:4141;
          include ${proxyHeaders};
        }
      }

      # ---- dev sites, real cert, reachable from the mac ---------------------
      # One vhost for every site in ~/sites. forgejo and atlantis are matched by
      # the exact-name servers above, which win over this regex, so they never
      # fall through to here.
      server {
        listen 443 ssl;
        http2 on;
        server_name ~^(?<site>.+)\.home\.samuelstidham\.me$;
        ssl_certificate     ${certDir}/${homeDomain}.crt;
        ssl_certificate_key ${certDir}/${homeDomain}.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        include ${siteBody};
      }

      # ---- dev sites, .test, offline ----------------------------------------
      # If secure_sites has made a cert for this host, force HTTPS. Otherwise
      # serve over HTTP, so an unsecured site still works.
      server {
        listen 80;
        server_name ~^(?<site>.+)\.test$;
        if (-f ${certDir}/$host.crt) {
          return 301 https://$host$request_uri;
        }
        include ${siteBody};
      }

      server {
        listen 443 ssl;
        server_name ~^(?<site>.+)\.test$;
        ssl_certificate     ${certDir}/$ssl_server_name.crt;
        ssl_certificate_key ${certDir}/$ssl_server_name.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        include ${siteBody};
      }

      # ---- anything else ----------------------------------------------------
      # A request for a name we do not serve. Refuse it rather than silently
      # handing over the first vhost, which is nginx's default and makes
      # misrouting invisible.
      server {
        listen 80 default_server;
        server_name _;
        return 404;
      }
      server {
        listen 443 ssl default_server;
        server_name _;
        ssl_certificate     ${certDir}/${homeDomain}.crt;
        ssl_certificate_key ${certDir}/${homeDomain}.key;
        return 421;
      }
    }
  '';
in
{
  systemd.user.services.nginx = lib.mkIf pkgs.stdenv.isLinux {
    Unit = {
      Description = "nginx: *.test and *.home.samuelstidham.me";
      After = [ "network.target" ];
    };
    Service = {
      Type = "simple";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${runDir}/nginx/tmp ${certDir}";
      ExecStart = "${pkgs.nginx}/bin/nginx -c ${nginxConf} -p ${runDir}/nginx";
      ExecReload = "${pkgs.nginx}/bin/nginx -c ${nginxConf} -p ${runDir}/nginx -s reload";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
