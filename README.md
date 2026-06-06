<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".assets/logo-inverse.svg">
    <img src=".assets/logo.svg" alt="PharosVPN" width="120" height="120">
  </picture>
</p>

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

Working. The AmneziaWG engine (in the `caravel` core's `vp` package) is real,
the macOS `utun`/routing shell brings a tunnel up, and the client speaks the
real `.pharos` profile format the controller exports.

- **`.pharos` profiles** — the core parses all three modes: `none` (plaintext),
  `password` (Argon2id + XChaCha20-Poly1305), and `account` (sealed to a device;
  needs the device key + the controller's signing key — the sync flow, still to
  come). A node's AmneziaWG params resolve to a dialable endpoint + obfuscation.
- **CLI** — `import` / `list` / `rm` / `status` / `connect` (by stored profile,
  a `.pharos` path, or a legacy `--config` JSON).
- **Menu-bar UI** — `cmd/caravel-menubar`: an unprivileged tray app that lists
  profiles and connects/disconnects via the macOS authorization prompt (no
  privileged daemon). The root tunnel worker is `caravel-mac` itself.

Still ahead: XRay/REALITY behind the same engine, account-sync (gRPC + device
keystore) to fetch account-mode profiles, and the gomobile bridge for iOS/Android.

## Use

```sh
# build (from a checkout beside ../caravel, the core)
go install ./cmd/caravel-mac ./cmd/caravel-menubar

caravel-mac import ~/Downloads/edge.pharos --name edge   # store a profile
caravel-mac list
sudo caravel-mac connect --profile edge                  # password-prompted if needed
caravel-mac status                                        # from any shell
caravel-menubar &                                         # the menu-bar UI

# legacy / quick test with an inline JSON config:
sudo caravel-mac connect --config test.json
```

## Live test

`scripts/livetest.sh` stands up a throwaway AmneziaWG server on DigitalOcean and
writes a matching profile, so you can verify the whole client end to end:

```sh
./scripts/livetest.sh up        # spins a server, writes ./livetest/test.pharos
sudo caravel-mac connect --profile ./livetest/test.pharos
curl -s https://ifconfig.me      # should print the server's IP
./scripts/livetest.sh down       # destroy the server
```

Licensed Apache-2.0, matching the rest of PharosVPN.
