{ lib
, stdenvNoCC
, buildFHSEnv
, makeDesktopItem
, copyDesktopItems
, runCommandLocal
, iproute2
, perimeter81-unwrapped
, extraPkgs ? pkgs: [ ]
, extraLibs ? pkgs: [ ]
}:
let
    # Rewrite `ip route add` -> `ip route replace`. The 10.x agent re-runs its
    # connect flow and re-adds routes it already installed; without this it
    # aborts on "RTNETLINK answers: File exists". hiPrio'd into the FHS so it
    # shadows iproute2's ip.
    ipWrapper = runCommandLocal "p81-ip-wrap" { } ''
      mkdir -p $out/bin $out/sbin
      cat > $out/bin/ip <<'WRAP'
      #!/bin/sh
      if [ "$1" = "route" ] && [ "$2" = "add" ]; then
        shift 2
        exec __IP__ route replace "$@"
      fi
      exec __IP__ "$@"
      WRAP
      substituteInPlace $out/bin/ip --replace __IP__ ${iproute2}/bin/ip
      chmod +x $out/bin/ip
      ln -s ../bin/ip $out/sbin/ip
    '';

    # The daemon (writable = true) needs /opt/Perimeter81 writable -- the 10.x
    # agent writes runtime state there (swg, yarkon, ...) which is EROFS against
    # the read-only Nix store -- and its DNS override needs a writable
    # /etc/resolv.conf. The GUI needs neither, so only the daemon gets the
    # overlay, the resolv.conf bind, and the ip shim.
    fhs = { runScript, writable ? false }: buildFHSEnv {
        name = "p81fhs";
        inherit runScript;

        targetPkgs = pkgs: with pkgs; [
          xorg.libXrandr
        ] ++ lib.optionals writable [ (lib.hiPrio ipWrapper) ]
          ++ extraPkgs pkgs;

        multiPkgs = pkgs: with pkgs; [
          cups
          gtk3
          expat
          libxkbcommon
          alsa-lib
          nss
          libgbm
          libdrm
          mesa
          nspr
          atk
          dbus
          pango
          xorg.libXcomposite
          xorg.libXext
          xorg.libXdamage
          xorg.libXfixes
          xorg.libxcb
          xorg.libxshmfence

          openssl
          iproute2
          procps
          cairo
          libnotify
          udev
          libappindicator
          xorg.libX11
          glib
          gdk-pixbuf

          perimeter81-unwrapped
        ] ++ extraLibs pkgs;

        extraBuildCommands = ''
            mkdir -p $out/usr/local
        '';

        extraBwrapArgs = [
            "--bind /var/lib/p81/local /usr/local"
            "--bind /var/lib/p81/etc /etc/Perimeter81"
        ] ++ lib.optionals writable [
            # Writable /opt/Perimeter81: read-only store app as the lower layer,
            # writes go to an ephemeral tmpfs upper.
            "--overlay-src ${perimeter81-unwrapped}/opt/Perimeter81"
            "--tmp-overlay /opt/Perimeter81"
            # DNS override must reach the host's real resolv.conf. /etc/resolv.conf
            # in the FHS is a symlink to /.host-etc/resolv.conf (the ro-bound host
            # /etc); binding directly onto it aborts bwrap ("can't create file"
            # over a symlink), so bind the writable host file onto the symlink
            # target instead. Writes via /etc/resolv.conf then land on the host.
            "--bind /etc/resolv.conf /.host-etc/resolv.conf"
        ];

    };
in
    stdenvNoCC.mkDerivation {
        name = "perimeter81";

        dontUnpack = true;
        dontConfigure = true;
        dontBuild = false;

        nativeBuildInputs = [ copyDesktopItems ];

        postInstall = ''
            mkdir -p $out/bin
            mkdir -p $out/share
            ln -s ${fhs { runScript = "/opt/Perimeter81/perimeter81"; }}/bin/p81fhs $out/bin/perimeter81
            ln -s ${fhs { runScript = "/opt/Perimeter81/artifacts/daemon"; writable = true; }}/bin/p81fhs $out/bin/p81-helper-daemon
            cp -r ${perimeter81-unwrapped}/share/doc ${perimeter81-unwrapped}/share/icons $out/share
        '';

        desktopItems = [(makeDesktopItem {
            name = "Perimeter81";
            desktopName = "Perimeter 81";
            exec = "perimeter81 %U";
            terminal = false;
            type = "Application";
            icon = "perimeter81";
            startupWMClass = "Perimeter81";
            comment = "Perimeter81 Linux Agent";
            mimeTypes = [
                "x-scheme-handler/perimeter81"
            ];
            categories = [
                "Network"
            ];
        })];

    }
