#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2026 The PharosVPN Authors
#
# livetest.sh — stand up (or tear down) a throwaway AmneziaWG server on
# DigitalOcean and generate a matching `.pharos` profile, so you can verify
# caravel-mac end to end with one command.
#
#   ./scripts/livetest.sh up      # spin a server, write ./livetest/test.pharos
#   sudo caravel-mac connect --profile ./livetest/test.pharos
#   # in another shell:  curl https://ifconfig.me   → should be the server IP
#   ./scripts/livetest.sh down    # destroy the server
#
# Requires: doctl (authed), the DO ssh key 56790376 (pharos-laptop = ~/.ssh/
# id_ed25519). The droplet is tagged pharos-cascade-test.
set -euo pipefail

NAME="caravel-testsrv"
REGION="${REGION:-nyc1}"
SIZE="s-1vcpu-1gb"
IMAGE="ubuntu-24-04-x64"
SSH_KEY_ID="56790376"
TAG="pharos-cascade-test"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i $HOME/.ssh/id_ed25519"
OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/livetest"

# The obfuscation set the server advertises and the client must match exactly.
OBF_JC=4; OBF_JMIN=40; OBF_JMAX=70
OBF_S1=50; OBF_S2=50; OBF_S3=50; OBF_S4=50
OBF_H1=5; OBF_H2=6; OBF_H3=7; OBF_H4=8

server_ip() { doctl compute droplet list --tag-name "$TAG" --format Name,PublicIPv4 --no-header | awk -v n="$NAME" '$1==n{print $2; exit}'; }

up() {
  if [ -n "$(server_ip)" ]; then echo "already up at $(server_ip)"; else
    echo "→ creating $NAME ($REGION)…"
    cat >/tmp/caravel-testsrv-userdata.sh <<'CLOUDINIT'
#!/bin/bash
set -uxo pipefail
export DEBIAN_FRONTEND=noninteractive
chage -d "$(date +%F)" -M -1 -E -1 root || true
apt-get update && apt-get install -y software-properties-common curl ca-certificates
add-apt-repository -y ppa:amnezia/ppa
apt-get update && apt-get install -y "linux-headers-$(uname -r)" amneziawg amneziawg-tools
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-pharos.conf && sysctl --system
modprobe amneziawg || true
command -v awg >/dev/null 2>&1 && touch /var/lib/awg-ready
CLOUDINIT
    doctl compute droplet create "$NAME" --region "$REGION" --size "$SIZE" --image "$IMAGE" \
      --ssh-keys "$SSH_KEY_ID" --tag-name "$TAG" --user-data-file /tmp/caravel-testsrv-userdata.sh --wait \
      --format Name,PublicIPv4 --no-header
  fi
  IP="$(server_ip)"; echo "  server IP: $IP"

  echo "→ waiting for AmneziaWG to finish installing…"
  for i in $(seq 1 30); do
    if $SSH "root@$IP" 'test -f /var/lib/awg-ready' 2>/dev/null; then break; fi
    sleep 15
  done

  echo "→ generating keys + configuring the AmneziaWG server…"
  read -r SERVER_PRIV SERVER_PUB CLIENT_PRIV CLIENT_PUB < <($SSH "root@$IP" '
    sp=$(awg genkey); spub=$(echo "$sp" | awg pubkey)
    cp=$(awg genkey); cpub=$(echo "$cp" | awg pubkey)
    echo "$sp $spub $cp $cpub"')

  $SSH "root@$IP" "
    mkdir -p /etc/amnezia/amneziawg
    cat >/etc/amnezia/amneziawg/awg0.conf <<CONF
[Interface]
PrivateKey = $SERVER_PRIV
Address = 10.86.0.1/24
ListenPort = 443
Jc = $OBF_JC
Jmin = $OBF_JMIN
Jmax = $OBF_JMAX
S1 = $OBF_S1
S2 = $OBF_S2
S3 = $OBF_S3
S4 = $OBF_S4
H1 = $OBF_H1
H2 = $OBF_H2
H3 = $OBF_H3
H4 = $OBF_H4

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.86.0.2/32
CONF
    awg-quick down awg0 2>/dev/null || true
    awg-quick up awg0
    EGRESS=\$(ip route show default | awk '{print \$5; exit}')
    iptables -t nat -C POSTROUTING -o \$EGRESS -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o \$EGRESS -j MASQUERADE
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo '  awg0:' \$(awg show awg0 listen-port) 'peer' \$(awg show awg0 peers)
  "

  mkdir -p "$OUTDIR"
  cat >"$OUTDIR/test.pharos" <<PROFILE
{
  "fmt": "pharos-profile", "v": 1, "enc": "none",
  "payload": {
    "fleet_id": "livetest", "user": "livetest", "revision": 1,
    "nodes": [{
      "id": "testsrv", "name": "caravel-testsrv", "region": "$REGION",
      "endpoints": ["$IP"],
      "protocols": [{"type": "amneziawg", "v": 2, "params": {
        "private_key": "$CLIENT_PRIV",
        "address": "10.86.0.2/32",
        "public_key": "$SERVER_PUB",
        "endpoints": [{"ip": "$IP", "port_min": 443, "port_max": 443}],
        "allowed_ips": ["0.0.0.0/0"],
        "obfuscation": {"jc": $OBF_JC, "jmin": $OBF_JMIN, "jmax": $OBF_JMAX, "s1": $OBF_S1, "s2": $OBF_S2, "s3": $OBF_S3, "s4": $OBF_S4, "h1": $OBF_H1, "h2": $OBF_H2, "h3": $OBF_H3, "h4": $OBF_H4}
      }}]
    }]
  }
}
PROFILE

  echo
  echo "✅ server ready at $IP, profile written → $OUTDIR/test.pharos"
  echo
  echo "Now verify the client (needs your sudo password for the utun + routes):"
  echo "    sudo caravel-mac connect --profile $OUTDIR/test.pharos"
  echo "  then in another shell:"
  echo "    curl -s https://ifconfig.me      # should print $IP"
  echo "  Ctrl-C to disconnect, then: ./scripts/livetest.sh down"
}

down() {
  echo "→ destroying $NAME…"
  doctl compute droplet delete "$NAME" --force 2>/dev/null || true
  rm -f "$OUTDIR/test.pharos"
  echo "  done."
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 {up|down}"; exit 2 ;;
esac
