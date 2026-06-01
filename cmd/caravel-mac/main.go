// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The PharosVPN Authors

// Command caravel-mac is the macOS PharosVPN client and the platform's
// connectivity test harness. It reads a profile, asks the caravel core to dial
// the tunnel, and (on macOS) routes traffic through a utun device.
//
// The protocol logic (AmneziaWG, later XRay) lives in the caravel core, not
// here; this binary is the thin macOS shell — CLI, utun, routing. See README.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

// config is the resolved tunnel configuration, from a .pharos profile or flags.
type config struct {
	profilePath string
	protocol    string // "amneziawg" (default) or "xray"
	endpoint    string
	publicKey   string
	presharedKey string
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "caravel-mac:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("caravel-mac", flag.ContinueOnError)
	var cfg config
	fs.StringVar(&cfg.profilePath, "profile", "", "path to a .pharos profile")
	fs.StringVar(&cfg.protocol, "protocol", "amneziawg", "protocol: amneziawg | xray")
	fs.StringVar(&cfg.endpoint, "endpoint", "", "server endpoint host:port (without a profile)")
	fs.StringVar(&cfg.publicKey, "public-key", "", "server public key (without a profile)")
	fs.StringVar(&cfg.presharedKey, "preshared-key", "", "optional preshared key")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if cfg.profilePath == "" && cfg.endpoint == "" {
		fs.Usage()
		return fmt.Errorf("need --profile or --endpoint")
	}

	// Cancel on SIGINT/SIGTERM so the tunnel tears down cleanly.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	c, err := connect(ctx, cfg)
	if err != nil {
		return err
	}
	defer c.Close()

	fmt.Printf("caravel-mac: %s tunnel up to %s — Ctrl-C to disconnect\n", cfg.protocol, c.endpoint())
	<-ctx.Done()
	fmt.Println("\ncaravel-mac: disconnecting")
	return nil
}

// conn is a live tunnel. It wraps the caravel core engine plus the macOS utun
// and route state.
type conn struct {
	cfg config
}

func (c *conn) endpoint() string { return c.cfg.endpoint }

// Close tears down the tunnel, removes routes, and closes the utun.
func (c *conn) Close() error {
	// TODO: core.Disconnect + restore routes + close utun.
	return nil
}

// connect resolves the config, asks the caravel core to dial the tunnel, brings
// up a utun, and routes traffic through it.
//
// NEXT STEP — make this real:
//  1. If profilePath is set, parse the .pharos profile into config.
//  2. github.com/PharosVPN/caravel/core (vp engine): build the protocol stack
//     (amneziawg-go for AmneziaWG; xray-core for XRay) over a tun device.
//  3. Create the macOS utun (amneziawg-go's tun.CreateTUN), configure the
//     device via IpcSet with key/endpoint/allowed-ips/PSK + obfuscation, and
//     install the default route through it (with the server endpoint pinned to
//     the physical gateway). Restore on Close.
func connect(_ context.Context, cfg config) (*conn, error) {
	return nil, fmt.Errorf(
		"engine not wired yet — implement the caravel core AmneziaWG engine "+
			"(amneziawg-go) and call it here; see README (protocol=%s)", cfg.protocol)
}
