// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"syscall"
	"time"
)

// sharedStatePath is a fixed, system-wide location the root tunnel worker writes
// and the unprivileged menu-bar / `status` read. It must not depend on which
// user is running (connect runs as root via sudo or the osascript auth prompt,
// where the per-user config dir would resolve to root's). It holds no secrets.
const sharedStateFile = "/Library/Application Support/PharosVPN/state.json"

// pharosBase returns the Application Support base for the profile store. When
// running as root via sudo, it targets the *invoking* user's home (SUDO_USER),
// so `sudo caravel-mac connect --profile NAME` finds the user's store rather
// than root's empty one. (The menu-bar passes absolute paths, so this only
// matters for the sudo-from-a-terminal case.)
func pharosBase() (string, error) {
	if su := os.Getenv("SUDO_USER"); su != "" && os.Geteuid() == 0 {
		if u, err := user.Lookup(su); err == nil && u.HomeDir != "" {
			return filepath.Join(u.HomeDir, "Library", "Application Support"), nil
		}
	}
	return os.UserConfigDir()
}

// State is the running-tunnel state caravel-mac writes while connected, so other
// processes (the menu-bar UI, `caravel-mac status`) can see what's up and find
// the worker to stop it. It lives next to the profile store.
type State struct {
	Profile  string    `json:"profile"`
	Iface    string    `json:"iface"`
	Endpoint string    `json:"endpoint"`
	PID      int       `json:"pid"`
	Since    time.Time `json:"since"`
}

// writeState records the running tunnel at the shared path (world-readable so a
// non-root menu-bar can see it; it holds no secrets). The worker runs as root,
// so it can create the system directory.
func writeState(s State) error {
	if err := os.MkdirAll(filepath.Dir(sharedStateFile), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(sharedStateFile, data, 0o644)
}

// clearState removes the running-tunnel record.
func clearState() {
	_ = os.Remove(sharedStateFile)
}

// readState returns the recorded tunnel state, or (zero, false) if none is
// recorded or the recorded worker is no longer alive (a stale record).
func readState() (State, bool) {
	data, err := os.ReadFile(sharedStateFile)
	if err != nil {
		return State{}, false
	}
	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return State{}, false
	}
	if s.PID > 0 && !processAlive(s.PID) {
		return State{}, false
	}
	return s, true
}

// processAlive reports whether a PID names a live process (signal 0 probe).
func processAlive(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}

func cmdStatus(_ []string) error {
	s, ok := readState()
	if !ok {
		fmt.Println("disconnected")
		return nil
	}
	fmt.Printf("connected — profile %q on %s → %s (since %s)\n",
		s.Profile, s.Iface, s.Endpoint, s.Since.Format(time.Kitchen))
	return nil
}
