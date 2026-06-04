// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

// Command caravel-menubar is the PharosVPN macOS menu-bar UI. It is a thin,
// unprivileged front-end over the caravel-mac CLI: it lists the stored profiles,
// shows whether a tunnel is up (from the worker's state file), and connects /
// disconnects by driving caravel-mac with administrator privileges via the
// system's standard authorization prompt (osascript) — so there is no separate
// privileged daemon to install. The root tunnel worker is caravel-mac itself.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"fyne.io/systray"
)

func main() {
	systray.Run(onReady, func() {})
}

func onReady() {
	systray.SetTitle("Pharos ○")
	systray.SetTooltip("PharosVPN")

	mStatus := systray.AddMenuItem("Disconnected", "Current tunnel status")
	mStatus.Disable()
	systray.AddSeparator()

	// One Connect entry per stored profile (read once at launch).
	mConnect := systray.AddMenuItem("Connect", "Bring a profile up")
	for _, name := range listProfiles() {
		item := mConnect.AddSubMenuItem(name, "Connect "+name)
		go func(profile string, clicked <-chan struct{}) {
			for range clicked {
				connectProfile(profile)
			}
		}(name, item.ClickedCh)
	}
	if len(listProfiles()) == 0 {
		empty := mConnect.AddSubMenuItem("(no profiles — import one with caravel-mac)", "")
		empty.Disable()
	}

	mDisconnect := systray.AddMenuItem("Disconnect", "Tear the tunnel down")
	systray.AddSeparator()
	mRefresh := systray.AddMenuItem("Refresh", "Re-read status")
	mQuit := systray.AddMenuItem("Quit", "Quit the menu bar (does not disconnect)")

	refresh := func() {
		if s, ok := readState(); ok {
			mStatus.SetTitle(fmt.Sprintf("Connected: %s", s.Profile))
			systray.SetTitle("Pharos ●")
			systray.SetTooltip(fmt.Sprintf("PharosVPN — %s on %s → %s", s.Profile, s.Iface, s.Endpoint))
			mDisconnect.Enable()
		} else {
			mStatus.SetTitle("Disconnected")
			systray.SetTitle("Pharos ○")
			systray.SetTooltip("PharosVPN — disconnected")
			mDisconnect.Disable()
		}
	}
	refresh()

	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				refresh()
			case <-mRefresh.ClickedCh:
				refresh()
			case <-mDisconnect.ClickedCh:
				disconnect()
				time.Sleep(500 * time.Millisecond)
				refresh()
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

// ───────── helpers (mirror caravel-mac's paths/state; no secrets) ─────────

type tunnelState struct {
	Profile  string    `json:"profile"`
	Iface    string    `json:"iface"`
	Endpoint string    `json:"endpoint"`
	PID      int       `json:"pid"`
	Since    time.Time `json:"since"`
}

func pharosDir() string {
	base, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(base, "PharosVPN")
}

func listProfiles() []string {
	matches, _ := filepath.Glob(filepath.Join(pharosDir(), "profiles", "*.pharos"))
	var names []string
	for _, m := range matches {
		names = append(names, strings.TrimSuffix(filepath.Base(m), ".pharos"))
	}
	sort.Strings(names)
	return names
}

func readState() (tunnelState, bool) {
	data, err := os.ReadFile(filepath.Join(pharosDir(), "state.json"))
	if err != nil {
		return tunnelState{}, false
	}
	var s tunnelState
	if err := json.Unmarshal(data, &s); err != nil {
		return tunnelState{}, false
	}
	if s.PID > 0 && !processAlive(s.PID) {
		return tunnelState{}, false
	}
	return s, true
}

func processAlive(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}

// connectProfile runs `caravel-mac connect --profile <name>` as root via the
// macOS authorization prompt, backgrounded so the worker keeps running.
func connectProfile(name string) {
	bin := caravelBin()
	// Single-quote the shell args; the whole shell command is then a
	// double-quoted AppleScript string (no embedded double quotes to escape).
	shellCmd := fmt.Sprintf("'%s' connect --profile '%s' >/tmp/caravel-mac.log 2>&1 &",
		strings.ReplaceAll(bin, "'", ""), strings.ReplaceAll(name, "'", ""))
	osa := fmt.Sprintf("do shell script %q with administrator privileges", shellCmd)
	_ = exec.Command("osascript", "-e", osa).Run()
}

// disconnect signals the recorded worker (root → via the auth prompt), letting
// it tear down its routes and clear the state.
func disconnect() {
	s, ok := readState()
	if !ok || s.PID <= 0 {
		return
	}
	shellCmd := fmt.Sprintf("kill %d", s.PID)
	osa := fmt.Sprintf("do shell script %q with administrator privileges", shellCmd)
	_ = exec.Command("osascript", "-e", osa).Run()
}

// caravelBin locates the caravel-mac worker: $CARAVEL_MAC_BIN, then next to this
// executable, then PATH.
func caravelBin() string {
	if v := os.Getenv("CARAVEL_MAC_BIN"); v != "" {
		return v
	}
	if exe, err := os.Executable(); err == nil {
		cand := filepath.Join(filepath.Dir(exe), "caravel-mac")
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	if p, err := exec.LookPath("caravel-mac"); err == nil {
		return p
	}
	return "caravel-mac"
}
