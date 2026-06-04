// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

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

// stateDir is ~/Library/Application Support/PharosVPN.
func stateDir() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(base, "PharosVPN")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

func statePath() (string, error) {
	dir, err := stateDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "state.json"), nil
}

// writeState records the running tunnel (world-readable so a non-root menu-bar
// can read it; it holds no secrets).
func writeState(s State) error {
	p, err := statePath()
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o644)
}

// clearState removes the running-tunnel record.
func clearState() {
	if p, err := statePath(); err == nil {
		_ = os.Remove(p)
	}
}

// readState returns the recorded tunnel state, or (zero, false) if none is
// recorded or the recorded worker is no longer alive (a stale record).
func readState() (State, bool) {
	p, err := statePath()
	if err != nil {
		return State{}, false
	}
	data, err := os.ReadFile(p)
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
