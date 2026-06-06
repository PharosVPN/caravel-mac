// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// controlSocket is where the root daemon listens; the (unprivileged) app and CLI
// connect to it to bring tunnels up/down without an authorization prompt each
// time — the daemon already holds root (installed once as a LaunchDaemon). It is
// chmod 0666 so any local user can drive it; it carries no secrets at rest.
const controlSocket = "/Library/Application Support/PharosVPN/control.sock"

// ctlRequest / ctlResponse are the newline-free JSON control protocol.
type ctlRequest struct {
	Op       string `json:"op"`                 // connect | disconnect | status
	Profile  string `json:"profile,omitempty"`  // absolute .pharos path (connect)
	Password string `json:"password,omitempty"` // password-mode profiles (connect)
	Full     *bool  `json:"full,omitempty"`     // full-tunnel (default true)
}

type ctlResponse struct {
	OK       bool   `json:"ok"`
	Error    string `json:"error,omitempty"`
	Status   string `json:"status"` // connected | disconnected
	Profile  string `json:"profile,omitempty"`
	Endpoint string `json:"endpoint,omitempty"`
	Iface    string `json:"iface,omitempty"`
}

// daemon holds the one active tunnel and serves the control socket.
type daemon struct {
	mu       sync.Mutex
	tn       *tunnel
	label    string
	endpoint string
	iface    string
	since    time.Time
}

// cmdDaemon runs the root helper: it listens on the control socket and manages
// the tunnel. Installed + launched by the LaunchDaemon (see install-helper).
func cmdDaemon(_ []string) error {
	if os.Geteuid() != 0 {
		return errors.New("daemon must run as root (installed via `caravel-mac install-helper`)")
	}
	if err := os.MkdirAll(filepath.Dir(controlSocket), 0o755); err != nil {
		return err
	}
	_ = os.Remove(controlSocket)
	ln, err := net.Listen("unix", controlSocket)
	if err != nil {
		return fmt.Errorf("listen %s: %w", controlSocket, err)
	}
	_ = os.Chmod(controlSocket, 0o666)

	d := &daemon{}
	sigc := make(chan os.Signal, 1)
	signal.Notify(sigc, syscall.SIGTERM, os.Interrupt)
	go func() {
		<-sigc
		d.disconnect()
		_ = ln.Close()
		_ = os.Remove(controlSocket)
		os.Exit(0)
	}()

	go d.statsLoop()
	fmt.Println("caravel-mac daemon: ready on", controlSocket)
	for {
		conn, err := ln.Accept()
		if err != nil {
			return nil
		}
		go d.handle(conn)
	}
}

func (d *daemon) handle(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	var req ctlRequest
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		_ = json.NewEncoder(conn).Encode(ctlResponse{Error: "bad request"})
		return
	}
	var resp ctlResponse
	switch req.Op {
	case "connect":
		full := true
		if req.Full != nil {
			full = *req.Full
		}
		if err := d.connect(req.Profile, req.Password, full); err != nil {
			resp = ctlResponse{Error: err.Error(), Status: "disconnected"}
		} else {
			resp = d.statusResp()
		}
	case "disconnect":
		d.disconnect()
		resp = d.statusResp()
	case "status", "":
		resp = d.statusResp()
	default:
		resp = ctlResponse{Error: "unknown op " + req.Op}
	}
	_ = json.NewEncoder(conn).Encode(resp)
}

func (d *daemon) connect(profilePath, password string, full bool) error {
	if profilePath == "" {
		return errors.New("profile path is required")
	}
	data, err := os.ReadFile(profilePath)
	if err != nil {
		return fmt.Errorf("read profile: %w", err)
	}
	// The daemon/app path uses protocol auto-selection (prefers AmneziaWG, the
	// default daily driver). The XRay/REALITY path is exercised via the CLI
	// `connect --protocol xray` for now.
	spec, err := resolveProfileSpec(data, "", password, "auto")
	if err != nil {
		return err
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.tn != nil { // switch: tear the old tunnel down first
		d.tn.Close()
		d.tn = nil
		clearState()
	}
	tn, err := connect(spec, full)
	if err != nil {
		return err
	}
	d.tn, d.label, d.endpoint, d.iface, d.since = tn, spec.label, spec.endpoint, tn.iface, time.Now()
	rx, tx := tn.stats()
	_ = writeState(State{Profile: spec.label, Iface: tn.iface, Endpoint: spec.endpoint,
		PID: os.Getpid(), Since: d.since, RX: rx, TX: tx})
	return nil
}

// statsLoop refreshes RX/TX in the state file while a tunnel is up, so the app /
// `status` show live throughput.
func (d *daemon) statsLoop() {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		d.mu.Lock()
		if d.tn != nil {
			rx, tx := d.tn.stats()
			_ = writeState(State{Profile: d.label, Iface: d.iface, Endpoint: d.endpoint,
				PID: os.Getpid(), Since: d.since, RX: rx, TX: tx})
		}
		d.mu.Unlock()
	}
}

func (d *daemon) disconnect() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.tn != nil {
		d.tn.Close()
		d.tn = nil
		clearState()
	}
	d.label, d.endpoint, d.iface = "", "", ""
}

func (d *daemon) statusResp() ctlResponse {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.tn == nil {
		return ctlResponse{OK: true, Status: "disconnected"}
	}
	return ctlResponse{OK: true, Status: "connected", Profile: d.label, Endpoint: d.endpoint, Iface: d.iface}
}

// --- control client (used by `caravel-mac ctl …`; the app speaks the same proto) ---

// sendCtl sends one request to the daemon and returns its response.
func sendCtl(req ctlRequest) (ctlResponse, error) {
	conn, err := net.DialTimeout("unix", controlSocket, 3*time.Second)
	if err != nil {
		return ctlResponse{}, fmt.Errorf("daemon not reachable (install it: `caravel-mac install-helper`): %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return ctlResponse{}, err
	}
	var resp ctlResponse
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return ctlResponse{}, err
	}
	return resp, nil
}

// cmdCtl drives the daemon from the CLI: `caravel-mac ctl connect <profile> [pw]`,
// `ctl disconnect`, `ctl status`.
func cmdCtl(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: caravel-mac ctl {connect <profile> [password] | disconnect | status}")
	}
	var req ctlRequest
	switch args[0] {
	case "connect":
		if len(args) < 2 {
			return errors.New("usage: caravel-mac ctl connect <profile-path> [password]")
		}
		req.Op = "connect"
		req.Profile = args[1]
		if len(args) > 2 {
			req.Password = args[2]
		}
	case "disconnect":
		req.Op = "disconnect"
	case "status":
		req.Op = "status"
	default:
		return fmt.Errorf("unknown ctl op %q", args[0])
	}
	resp, err := sendCtl(req)
	if err != nil {
		return err
	}
	if resp.Error != "" {
		return errors.New(resp.Error)
	}
	if resp.Status == "connected" {
		fmt.Printf("connected — %s → %s on %s\n", resp.Profile, resp.Endpoint, resp.Iface)
	} else {
		fmt.Println("disconnected")
	}
	return nil
}
