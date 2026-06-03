# Plan: split DNS (use the VPN resolver *alongside* the local one)

Status: **not implemented** — design notes to revisit.

## Goal

When connected, resolve internal names via the VPN resolver and everything
else via the normal local resolver:

- `*.anjuna.io` (covers `jenkins.dev.anjuna.io` etc.) → `10.255.0.1` (VPN, via `p81`)
- everything else → the local DNS NetworkManager already provides (e.g. `192.168.1.1`)

Today the agent instead points **all** DNS at `10.255.0.1` while connected.

## Why this isn't just a config flag

Two `nameserver` lines in `resolv.conf` is **failover, not split** — the resolver
sends every query to the first server and only falls back on *timeout*, never on
NXDOMAIN. Real per-domain routing needs a resolver in front (systemd-resolved).

But the blocker is the agent itself: **on connect it overwrites `/etc/resolv.conf`
with just `10.255.0.1`, and throws an uncaught exception (crash-loops) if the write
fails.** In this packaging that write is made to land on the host file via a
bubblewrap bind (see `fhsenv.nix`). Any split-DNS layer (resolved or dnsmasq) is
pointless until the agent stops owning the host's `resolv.conf` — but it must still
be allowed to write *somewhere* so it doesn't crash.

So the work is three parts: (1) contain the agent's write [this repo], (2) put
systemd-resolved in charge [consumer], (3) register the VPN resolver per-link on
`p81` [consumer].

## Part 1 — contain the agent's resolv.conf write (this repo)

Add an opt-out so the daemon writes to a throwaway file instead of the host's
`/etc/resolv.conf`. Default stays `true` so plain-`resolvconf` users (who rely on
the agent owning `resolv.conf`) are unaffected.

**`fhsenv.nix`** — thread a `manageDns` flag through to the daemon's bwrap args:

```nix
{ lib, ..., perimeter81-unwrapped, manageDns ? true, ... }:
# in the daemon (writable = true) extraBwrapArgs, replace the fixed resolv bind with:
  ++ lib.optional writable (
       if manageDns
       then "--bind /etc/resolv.conf /.host-etc/resolv.conf"        # current behaviour
       else "--bind /var/lib/p81/resolv.conf /.host-etc/resolv.conf" # throwaway scratch
     )
```

**`module.nix`** — expose the option and build the package with it; ensure the
scratch file exists so the bind source is present:

```nix
options.services.perimeter81.manageDns = lib.mkOption {
  type = lib.types.bool;
  default = true;
  description = ''
    Whether the agent manages the system /etc/resolv.conf. Set false to let a
    host resolver (e.g. systemd-resolved) own DNS and do split-DNS; the agent's
    DNS write is then redirected to a throwaway /var/lib/p81/resolv.conf.
  '';
};

# use a package built with the flag (the fhsenv wrapper takes `manageDns` via callPackage,
# so .override works):
let pkg = cfg.package.override { manageDns = cfg.manageDns; }; in
# ExecStartPre setup script: also `touch /var/lib/p81/resolv.conf` when !manageDns
```

Note: do **not** add `systemd`/`resolvectl` into the FHS. Without it the agent's
own "systemd-resolved" DNS strategy fails and falls back to the (now harmless)
file write, so it can't fight the split config we set in Part 3.

## Part 2 — systemd-resolved on the host (consumer config)

```nix
services.resolved.enable = true;
networking.networkmanager.dns = "systemd-resolved";
```

`/etc/resolv.conf` becomes the stable `127.0.0.53` stub; NM keeps feeding the
default resolver (192.168.1.1) on the main link.

## Part 3 — register the VPN resolver on `p81` (consumer config)

A oneshot bound to the `p81` device, so it fires when the agent brings the tunnel
up and is torn down with it:

```nix
services.perimeter81 = { enable = true; manageDns = false; };

systemd.services.p81-split-dns = {
  bindsTo  = [ "sys-subsystem-net-devices-p81.device" ];
  after    = [ "sys-subsystem-net-devices-p81.device" ];
  wantedBy = [ "sys-subsystem-net-devices-p81.device" ];
  serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
  script = ''
    ${pkgs.systemd}/bin/resolvectl dns    p81 10.255.0.1
    ${pkgs.systemd}/bin/resolvectl domain p81 anjuna.io
    # optional, for reverse lookups of internal IPs:
    # ${pkgs.systemd}/bin/resolvectl domain p81 anjuna.io 10.in-addr.arpa
  '';
};
```

## Verify

```sh
resolvectl status p81                 # DNS 10.255.0.1, Domain anjuna.io
resolvectl query jenkins.dev.anjuna.io # resolved via p81 / 10.255.0.1
resolvectl query example.com           # resolved via 192.168.1.1
readlink -f /etc/resolv.conf           # -> stub-resolv.conf (127.0.0.53)
```

## Rollback

Set `services.perimeter81.manageDns = true` (or drop it), remove the resolved /
NM / p81-split-dns settings, `nixos-rebuild switch`. DNS returns to the current
"all via VPN while connected" behaviour.

## Open questions / risks

- DNS is load-bearing: a mistake means nothing resolves until reverted. Stage and
  test (`resolvectl query`) before relying on it.
- Confirm the agent tolerates the scratch-file write without the crash we saw on
  EROFS (it should — it's a normal writable file).
- Only `anjuna.io` is routed to the VPN; if other internal domains or reverse
  zones are needed, extend the `resolvectl domain` line.
