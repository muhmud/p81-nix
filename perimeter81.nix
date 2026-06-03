{ stdenv, dpkg }:
stdenv.mkDerivation rec {
  pname = "perimeter81";
  version = "10.1.0.53";
  src = builtins.fetchurl {
    url =
      "https://static.perimeter81.com/agents/linux/Perimeter81_${version}.deb";
    sha256 = "041j3hkzm79gb47i3vhdaf6rmdydp38vhhmgr0dv7zzjw3mzhayv";
  };

  nativeBuildInputs = [ dpkg ];

  unpackPhase = ''
    runHook preUnpack

    dpkg-deb -x $src .

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    cp -R "opt" "$out"
    cp -R "usr/share" "$out/share"
    chmod -R g-w "$out"

    # Desktop file
    mkdir -p "$out/share/applications"

    # wg-quick shim. The 10.x agent creates and peers the `p81` WireGuard
    # interface natively, then runs `wg-quick up p81` as a connect-flow
    # checkpoint -- which fails "already exists". It also relies on the SWG
    # netfilter driver (absent on NixOS) to install split-tunnel routes, so it
    # only ever adds the gateway route. Replace wg-quick with a shim that, on
    # `up`, ensures the interface is up and installs a route per peer AllowedIP
    # (skipping default routes to stay split- not full-tunnel). The poll covers
    # the race where the agent sets the peer around the same time it calls us.
    # Other verbs (down, ...) pass through to the real wg-quick.
    wgdir="$out/opt/Perimeter81/binaries/wireguard/linux"
    mv "$wgdir/wg-quick" "$wgdir/wg-quick.real"
    cat > "$wgdir/wg-quick" <<'WGSHIM'
    #!/bin/sh
    dir=$(dirname "$0")
    if [ "$1" = "up" ]; then
      iface="$2"
      ip link show "$iface" >/dev/null 2>&1 || "$dir/wg-quick.real" up "$iface" || true
      cidrs=""
      i=0
      while [ "$i" -lt 50 ]; do
        cidrs=$("$dir/wg" show "$iface" allowed-ips 2>/dev/null | while read -r peer rest; do printf '%s ' "$rest"; done)
        [ -n "$cidrs" ] && break
        i=$((i + 1))
        sleep 0.1
      done
      for cidr in $cidrs; do
        case "$cidr" in
          0.0.0.0/0|::/0) ;;
          */*) ip route replace "$cidr" dev "$iface" 2>/dev/null ;;
        esac
      done
      exit 0
    fi
    exec "$dir/wg-quick.real" "$@"
    WGSHIM
    chmod +x "$wgdir/wg-quick"

    runHook postInstall
  '';

}
