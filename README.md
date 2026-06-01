# caravel-mac

The **macOS** client for PharosVPN — and, first, the **connectivity test harness**
for the whole platform.

macOS is the easiest place to bring the VPN data plane up: full root, a `utun`
device, and no NetworkExtension entitlement/provisioning dance. So caravel-mac
is where we make the [`caravel`](https://github.com/PharosVPN/caravel) core
*real* (AmneziaWG first, then XRay) and validate it against live `buoy` nodes,
before that same core ships in caravel-ios / caravel-android via gomobile.

## What it is

A small Go command-line client that:

1. reads a `.pharos` profile (or inline `--endpoint/--key/...` flags),
2. asks the **caravel core** to dial the tunnel, and
3. on macOS, creates a `utun` and routes traffic through it.

The protocol logic lives in the core, not here — caravel-mac is the thin macOS
shell (utun + routing + CLI). The same core backs iOS and Android.

## Single binary, all protocols

Both data-plane protocols have pure-Go implementations, so the core compiles
**both into one static binary** and dispatches on the profile's protocol:

| Protocol | Library | Notes |
|---|---|---|
| AmneziaWG | `github.com/amnezia-vpn/amneziawg-go` (userspace, wireguard-go fork) | small, no CGO |
| XRay / REALITY | `github.com/xtls/xray-core` | pure Go, large |

`CGO_ENABLED=0` → one self-contained binary that speaks both. The only cost is
size (xray-core dominates); the exported API stays tiny (`Connect`/`Disconnect`).

## Status

Scaffold. The CLI flow and the macOS `utun`/routing shell are laid out; the core
AmneziaWG engine (`amneziawg-go`) is the next step — that's what turns this into
a working client and our `buoy` connectivity test.

## Develop

```sh
# from a checkout that sits beside ../caravel (the core)
go run ./cmd/caravel-mac --help
sudo go run ./cmd/caravel-mac --profile ~/Downloads/test.pharos   # needs root for utun
```

Licensed Apache-2.0, matching the rest of PharosVPN.
