// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

// Command caravel-mac is the macOS PharosVPN client and the platform's
// connectivity test harness. It imports `.pharos` profiles (the format the
// controller exports), brings up an AmneziaWG tunnel via the caravel core over a
// utun, and routes traffic through it.
//
// Subcommands (run connect as root — utun + route changes need it):
//
//	caravel-mac import <file.pharos> [--name NAME]   # store a profile
//	caravel-mac list                                 # list stored profiles
//	caravel-mac rm <name>                            # forget a profile
//	sudo caravel-mac connect --profile NAME [--password PW]
//	sudo caravel-mac connect --config test.json      # legacy inline JSON
//
// A `.pharos` profile in `password` mode prompts for / takes --password;
// `none` (plaintext) needs nothing; `account` mode (sealed to a device) needs
// the device key + the controller's signing key (the sync flow — future work).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/PharosVPN/caravel/core/deviceid"
	"github.com/PharosVPN/caravel/core/profile"
	csync "github.com/PharosVPN/caravel/core/sync"
	"github.com/PharosVPN/caravel/core/vp"
	"github.com/amnezia-vpn/amneziawg-go/device"
	"github.com/amnezia-vpn/amneziawg-go/tun"
	"golang.org/x/term"
)

func main() {
	if err := dispatch(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "caravel-mac:", err)
		os.Exit(1)
	}
}

func dispatch(args []string) error {
	if len(args) == 0 {
		usage()
		return errors.New("a subcommand is required")
	}
	switch args[0] {
	case "connect":
		return cmdConnect(args[1:])
	case "import":
		return cmdImport(args[1:])
	case "sync":
		return cmdSync(args[1:])
	case "list", "ls":
		return cmdList(args[1:])
	case "rm", "remove":
		return cmdRemove(args[1:])
	case "status":
		return cmdStatus(args[1:])
	case "daemon":
		return cmdDaemon(args[1:])
	case "ctl":
		return cmdCtl(args[1:])
	case "install-helper":
		return cmdInstallHelper(args[1:])
	case "uninstall-helper":
		return cmdUninstallHelper(args[1:])
	case "-h", "--help", "help":
		usage()
		return nil
	default:
		// Back-compat: `caravel-mac --config x` (a leading flag) means connect.
		if strings.HasPrefix(args[0], "-") {
			return cmdConnect(args)
		}
		usage()
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `caravel-mac — PharosVPN macOS client

  caravel-mac import <file.pharos> [--name NAME]   store a profile
  caravel-mac sync <file.pharosid> [--email E] [--password PW] [--name NAME]
                                                   fetch your profile from the controller
  caravel-mac list                                 list stored profiles
  caravel-mac rm <name>                            forget a profile
  caravel-mac status                               show whether a tunnel is up
  sudo caravel-mac connect --profile NAME [--password PW] [--node ID]
  sudo caravel-mac connect --config FILE.json      legacy inline JSON config

connect flags:
  --profile NAME|PATH   a stored profile name, or a path to a .pharos file
  --config PATH         a JSON tunnel config (legacy / testing)
  --password PW         password for a password-mode profile (prompted if omitted)
  --node ID             which node in the profile to use (default: the first)
  --full-tunnel         route all traffic through the tunnel (default true)
`)
}

// ───────── store ─────────

// openStore opens the on-disk profile store
// (~/Library/Application Support/PharosVPN/profiles).
func openStore() (*profile.Store, error) {
	base, err := pharosBase()
	if err != nil {
		return nil, err
	}
	return profile.NewStore(filepath.Join(base, "PharosVPN", "profiles"))
}

func cmdImport(args []string) error {
	// Parse <file> + optional --name in any order (the stdlib flag package stops
	// at the first positional, so we scan manually).
	var src, name string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--name" || a == "-name":
			if i+1 >= len(args) {
				return errors.New("--name needs a value")
			}
			name = args[i+1]
			i++
		case strings.HasPrefix(a, "--name="):
			name = strings.TrimPrefix(a, "--name=")
		case !strings.HasPrefix(a, "-") && src == "":
			src = a
		default:
			return fmt.Errorf("unexpected argument %q (usage: caravel-mac import <file.pharos> [--name NAME])", a)
		}
	}
	if src == "" {
		return errors.New("usage: caravel-mac import <file.pharos> [--name NAME]")
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	n := name
	if n == "" {
		n = strings.TrimSuffix(filepath.Base(src), profile.Extension)
	}
	st, err := openStore()
	if err != nil {
		return err
	}
	path, err := st.Import(n, data)
	if err != nil {
		return err
	}
	fmt.Printf("imported profile %q → %s\n", n, path)
	return nil
}

// cmdSync fetches the account's end-to-end-encrypted profile from the controller
// (through the relay named in the `.pharosid` bundle), decrypts it on-device, and
// stores it as a connectable profile marked cloud-synced. The controller only
// ever served ciphertext.
func cmdSync(args []string) error {
	var src, name, email, password string
	havePW := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		val := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value", a)
			}
			i++
			return args[i], nil
		}
		var err error
		switch {
		case a == "--name":
			name, err = val()
		case a == "--email":
			email, err = val()
		case a == "--password":
			password, err = val()
			havePW = true
		case a == "--password-stdin":
			// Read the passphrase from stdin so it never appears in the process
			// table (the GUI pipes it here).
			pw, rerr := io.ReadAll(os.Stdin)
			if rerr != nil {
				return fmt.Errorf("read passphrase from stdin: %w", rerr)
			}
			password, havePW = strings.TrimRight(string(pw), "\r\n"), true
		case strings.HasPrefix(a, "--name="):
			name = strings.TrimPrefix(a, "--name=")
		case strings.HasPrefix(a, "--email="):
			email = strings.TrimPrefix(a, "--email=")
		case strings.HasPrefix(a, "--password="):
			password, havePW = strings.TrimPrefix(a, "--password="), true
		case !strings.HasPrefix(a, "-") && src == "":
			src = a
		default:
			return fmt.Errorf("unexpected argument %q (usage: caravel-mac sync <file.pharosid> [--email E] [--password PW] [--name NAME])", a)
		}
		if err != nil {
			return err
		}
	}
	if src == "" {
		return errors.New("usage: caravel-mac sync <file.pharosid> [--email E] [--password PW] [--name NAME]")
	}

	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	bundle, err := deviceid.Parse(data)
	if err != nil {
		return err
	}
	// Email is optional: with none, sync authenticates by the device's leaf
	// (cert-auth) and the passphrase never leaves this Mac. An email opts into the
	// legacy passphrase login.
	who := bundle.User
	if email != "" {
		who = email
	}
	if who == "" {
		who = "your account"
	}
	if !havePW {
		fmt.Fprintf(os.Stderr, "account passphrase for %s: ", who)
		pw, err := term.ReadPassword(int(syscall.Stdin))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return fmt.Errorf("read passphrase: %w", err)
		}
		password = string(pw)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	res, err := csync.Fetch(ctx, bundle, email, password)
	if errors.Is(err, csync.ErrNoProfile) {
		return fmt.Errorf("signed in as %s, but no profile has been issued for this account yet", email)
	}
	if err != nil {
		return err
	}

	env, err := profile.WrapPlaintext(res.Plaintext)
	if err != nil {
		return err
	}
	if name == "" {
		// Default the profile name to the device's friendly alias, else the email.
		if bundle.Alias != "" {
			name = syncProfileName(bundle.Alias)
		} else {
			name = syncProfileName(email)
		}
	}
	st, err := openStore()
	if err != nil {
		return err
	}
	path, err := st.Import(name, env)
	if err != nil {
		return err
	}
	// Mark it cloud-synced (the app shows synced profiles as disable-only, never
	// delete) and stash the bundle next to it so a later refresh needs no re-import.
	marker, _ := json.Marshal(map[string]any{"user": email, "revision": res.Revision, "relay": bundle.RelayAddr})
	_ = os.WriteFile(filepath.Join(st.Dir(), name+".synced"), marker, 0o600)
	_ = os.WriteFile(filepath.Join(st.Dir(), name+deviceid.Extension), data, 0o600)

	// Summarize the nodes the synced profile carries.
	var summary struct {
		User  string `json:"user"`
		Nodes []struct {
			Name   string `json:"name"`
			Region string `json:"region"`
		} `json:"nodes"`
	}
	_ = json.Unmarshal(res.Plaintext, &summary)
	fmt.Printf("synced profile %q (rev %d, %d node(s)) → %s\n", name, res.Revision, len(summary.Nodes), path)
	for _, n := range summary.Nodes {
		fmt.Printf("  · %s (%s)\n", n.Name, n.Region)
	}
	fmt.Printf("connect with:  sudo caravel-mac connect --profile %s\n", name)
	return nil
}

// syncProfileName derives a stable store name from an account email.
func syncProfileName(email string) string {
	n := email
	if at := strings.IndexByte(n, '@'); at > 0 {
		n = n[:at]
	}
	n = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		default:
			return '-'
		}
	}, n)
	if n == "" {
		n = "account"
	}
	return n
}

func cmdList(args []string) error {
	st, err := openStore()
	if err != nil {
		return err
	}
	entries, err := st.List()
	if err != nil {
		return err
	}
	if len(entries) == 0 {
		fmt.Printf("no profiles in %s — import one with `caravel-mac import <file.pharos>`\n", st.Dir())
		return nil
	}
	fmt.Printf("profiles in %s:\n", st.Dir())
	for _, e := range entries {
		fmt.Printf("  %-24s  (%s)\n", e.Name, e.Enc)
	}
	return nil
}

func cmdRemove(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: caravel-mac rm <name>")
	}
	st, err := openStore()
	if err != nil {
		return err
	}
	if err := st.Remove(args[0]); err != nil {
		return err
	}
	fmt.Printf("removed profile %q\n", args[0])
	return nil
}

// ───────── connect ─────────

// fileConfig is the legacy inline JSON config (--config), kept for testing.
type fileConfig struct {
	Endpoint        string         `json:"endpoint"`
	ServerPublicKey string         `json:"server_public_key"`
	PrivateKey      string         `json:"private_key"`
	PresharedKey    string         `json:"preshared_key"`
	Address         string         `json:"address"`
	AllowedIPs      []string       `json:"allowed_ips"`
	Keepalive       int            `json:"keepalive"`
	MTU             int            `json:"mtu"`
	Obfuscation     vp.Obfuscation `json:"obfuscation"`
}

// dialSpec is the unified tunnel input both --config and --profile resolve to.
type dialSpec struct {
	cfg     vp.Config
	address string // bare utun IP
	mtu     int
	label   string // for logs
}

func cmdConnect(args []string) error {
	fs := flag.NewFlagSet("connect", flag.ContinueOnError)
	profileRef := fs.String("profile", "", "a stored profile name, or a path to a .pharos file")
	cfgPath := fs.String("config", "", "a JSON tunnel config (legacy / testing)")
	password := fs.String("password", "", "password for a password-mode profile (prompted if omitted)")
	nodeID := fs.String("node", "", "which node in the profile to use (default: the first)")
	fullTunnel := fs.Bool("full-tunnel", true, "route all traffic through the tunnel")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if (*profileRef == "") == (*cfgPath == "") {
		return errors.New("give exactly one of --profile or --config")
	}

	var spec dialSpec
	var err error
	if *cfgPath != "" {
		spec, err = specFromConfig(*cfgPath)
	} else {
		spec, err = specFromProfile(*profileRef, *nodeID, password)
	}
	if err != nil {
		return err
	}

	if os.Geteuid() != 0 {
		return errors.New("must run as root (utun + routes) — re-run with sudo")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	tn, err := connect(spec, *fullTunnel)
	if err != nil {
		return err
	}
	defer tn.Close()

	// Record the running tunnel so the menu-bar UI / `caravel-mac status` can see
	// it and stop it; clear it on the way out.
	since := time.Now()
	writeTunnelState := func() {
		rx, tx := tn.stats()
		_ = writeState(State{Profile: spec.label, Iface: tn.iface, Endpoint: spec.cfg.Endpoint,
			PID: os.Getpid(), Since: since, RX: rx, TX: tx})
	}
	writeTunnelState()
	defer clearState()

	// Refresh RX/TX in the state file while connected (so `status` / the UI show
	// live throughput).
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				writeTunnelState()
			}
		}
	}()

	fmt.Printf("caravel-mac: tunnel up on %s → %s (%s, full-tunnel=%v). Ctrl-C to disconnect.\n",
		tn.iface, spec.cfg.Endpoint, spec.label, *fullTunnel)
	<-ctx.Done()
	fmt.Println("\ncaravel-mac: disconnecting")
	return nil
}

// specFromConfig builds a dialSpec from a legacy JSON config file.
func specFromConfig(path string) (dialSpec, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return dialSpec{}, err
	}
	var fc fileConfig
	if err := json.Unmarshal(raw, &fc); err != nil {
		return dialSpec{}, fmt.Errorf("parse config: %w", err)
	}
	if fc.Address == "" {
		return dialSpec{}, errors.New("config needs an address")
	}
	mtu := fc.MTU
	if mtu == 0 {
		mtu = 1420
	}
	return dialSpec{
		cfg: vp.Config{
			PrivateKey:      fc.PrivateKey,
			ServerPublicKey: fc.ServerPublicKey,
			PresharedKey:    fc.PresharedKey,
			Endpoint:        fc.Endpoint,
			AllowedIPs:      fc.AllowedIPs,
			Keepalive:       fc.Keepalive,
			Obfuscation:     fc.Obfuscation,
		},
		address: fc.Address,
		mtu:     mtu,
		label:   "config",
	}, nil
}

// specFromProfile loads a .pharos profile (from the store by name, or a file
// path) and resolves the chosen node to a dialSpec, prompting for a password if
// one is needed (the interactive CLI path).
func specFromProfile(ref, nodeID string, password *string) (dialSpec, error) {
	data, err := loadProfileBytes(ref)
	if err != nil {
		return dialSpec{}, err
	}
	spec, err := resolveProfileSpec(data, nodeID, *password)
	if errors.Is(err, profile.ErrPasswordNeeded) && *password == "" {
		pw, perr := promptPassword(fmt.Sprintf("password for profile %q: ", ref))
		if perr != nil {
			return dialSpec{}, perr
		}
		*password = pw
		spec, err = resolveProfileSpec(data, nodeID, pw)
	}
	return spec, err
}

// resolveProfileSpec decrypts a .pharos and resolves the chosen node to a
// dialSpec, without prompting — the form the daemon uses (the password, if any,
// is supplied by the caller).
func resolveProfileSpec(data []byte, nodeID, password string) (dialSpec, error) {
	p, err := profile.Parse(data, profile.Options{Password: password})
	if err != nil {
		return dialSpec{}, err
	}
	node, err := p.Node(nodeID)
	if err != nil {
		return dialSpec{}, err
	}
	tun, err := node.Tunnel()
	if err != nil {
		return dialSpec{}, err
	}
	return dialSpec{
		cfg: vp.Config{
			PrivateKey:      tun.PrivateKey,
			ServerPublicKey: tun.ServerPublicKey,
			PresharedKey:    tun.PresharedKey,
			Endpoint:        tun.Endpoint,
			AllowedIPs:      tun.AllowedIPs,
			Keepalive:       tun.Keepalive,
			Obfuscation:     toVPObfuscation(tun.Obfuscation),
		},
		address: tun.Address,
		mtu:     tun.MTU,
		label:   fmt.Sprintf("%s/%s", p.FleetID, tun.NodeName),
	}, nil
}

// loadProfileBytes resolves a --profile reference: a readable file path, else a
// stored profile name.
func loadProfileBytes(ref string) ([]byte, error) {
	if data, err := os.ReadFile(ref); err == nil {
		return data, nil
	}
	st, err := openStore()
	if err != nil {
		return nil, err
	}
	data, err := st.Raw(ref)
	if errors.Is(err, profile.ErrProfileNotFound) {
		return nil, fmt.Errorf("no profile %q (not a file path, not in %s)", ref, st.Dir())
	}
	return data, err
}

// toVPObfuscation maps a profile obfuscation set to the engine's.
func toVPObfuscation(o profile.Obfuscation) vp.Obfuscation {
	return vp.Obfuscation{
		Jc: o.Jc, Jmin: o.Jmin, Jmax: o.Jmax,
		S1: o.S1, S2: o.S2, S3: o.S3, S4: o.S4,
		H1: o.H1, H2: o.H2, H3: o.H3, H4: o.H4,
		I1: o.I1, I2: o.I2, I3: o.I3, I4: o.I4, I5: o.I5,
	}
}

// promptPassword reads a password from the terminal without echo.
func promptPassword(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	pw, err := term.ReadPassword(int(syscall.Stdin))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", fmt.Errorf("read password: %w", err)
	}
	return strings.TrimSpace(string(pw)), nil
}

// ───────── tunnel (utun + routing) ─────────

// tunnel is a running tunnel plus the host network state to undo on close.
type tunnel struct {
	vt    *vp.Tunnel
	iface string
	undo  []string // route specs to delete on close
}

func connect(spec dialSpec, full bool) (*tunnel, error) {
	dev, err := tun.CreateTUN("utun", spec.mtu)
	if err != nil {
		return nil, fmt.Errorf("create utun: %w", err)
	}
	name, err := dev.Name()
	if err != nil {
		dev.Close()
		return nil, err
	}

	vt, err := vp.Up(spec.cfg, dev, device.LogLevelError)
	if err != nil {
		dev.Close() // vp.Up closes the device on failure, but be safe
		return nil, err
	}

	tn := &tunnel{vt: vt, iface: name}
	if err := tn.configureNetwork(spec, full); err != nil {
		tn.Close()
		return nil, fmt.Errorf("configure network: %w", err)
	}
	return tn, nil
}

// configureNetwork sets the utun address and, for a full tunnel, pins the server
// endpoint to the physical gateway and overrides the default route with the
// 0.0.0.0/1 + 128.0.0.0/1 split so connectivity to the server is preserved while
// everything else flows through the tunnel.
func (t *tunnel) configureNetwork(spec dialSpec, full bool) error {
	if spec.address == "" {
		return errors.New("profile/config has no tunnel address")
	}
	if err := sh("ifconfig", t.iface, "inet", spec.address, spec.address, "up"); err != nil {
		return err
	}

	if !full {
		for _, cidr := range spec.cfg.AllowedIPs {
			_ = sh("route", "-n", "add", "-net", cidr, "-interface", t.iface)
			t.undo = append(t.undo, "net "+cidr)
		}
		return nil
	}

	// Pin the server endpoint to the current physical gateway, so the encrypted
	// WireGuard packets to it don't get routed back into the tunnel.
	host, _, err := net.SplitHostPort(spec.cfg.Endpoint)
	if err != nil {
		host = spec.cfg.Endpoint
	}
	ip, err := net.ResolveIPAddr("ip4", host)
	if err != nil {
		return fmt.Errorf("resolve endpoint %q: %w", host, err)
	}
	gw, err := defaultGateway()
	if err != nil {
		return err
	}
	if err := sh("route", "-n", "add", "-host", ip.String(), gw); err != nil {
		return err
	}
	t.undo = append(t.undo, "host "+ip.String())

	for _, half := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
		if err := sh("route", "-n", "add", "-net", half, "-interface", t.iface); err != nil {
			return err
		}
		t.undo = append(t.undo, "net "+half)
	}
	return nil
}

// Close tears down routes and the tunnel.
func (t *tunnel) Close() error {
	for _, spec := range t.undo {
		parts := strings.Fields(spec)
		_ = sh(append([]string{"route", "-n", "delete", "-" + parts[0]}, parts[1:]...)...)
	}
	if t.vt != nil {
		t.vt.Close()
	}
	return nil
}

// stats returns the tunnel's cumulative RX/TX bytes (0 if unavailable).
func (t *tunnel) stats() (rx, tx int64) {
	if t.vt == nil {
		return 0, 0
	}
	rx, tx, _ = t.vt.Stats()
	return rx, tx
}

// defaultGateway returns the current IPv4 default gateway.
func defaultGateway() (string, error) {
	out, err := exec.Command("route", "-n", "get", "default").Output()
	if err != nil {
		return "", fmt.Errorf("read default route: %w", err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if gw, ok := strings.CutPrefix(line, "gateway:"); ok {
			return strings.TrimSpace(gw), nil
		}
	}
	return "", errors.New("no default gateway found")
}

func sh(args ...string) error {
	cmd := exec.Command(args[0], args[1:]...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%s: %w (%s)", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}
