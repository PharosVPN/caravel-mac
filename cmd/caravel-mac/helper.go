// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	// helperBin is a stable copy of the worker the LaunchDaemon points at (so the
	// daemon path doesn't break when the .app moves).
	helperBin   = "/Library/Application Support/PharosVPN/caravel-mac"
	daemonLabel = "org.pharosvpn.caravel.helper"
	daemonPlist = "/Library/LaunchDaemons/org.pharosvpn.caravel.helper.plist"
)

// cmdInstallHelper installs the root LaunchDaemon: it copies this binary to a
// stable location and registers the daemon with launchd. This is the ONE step
// that needs authorization — afterwards connect/disconnect go over the control
// socket with no prompt. The app runs this once via the system auth prompt.
func cmdInstallHelper(_ []string) error {
	if os.Geteuid() != 0 {
		return errors.New("install-helper must run as root (the app authorizes this once; or use sudo)")
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(helperBin), 0o755); err != nil {
		return err
	}
	if err := copyFile(self, helperBin); err != nil {
		return fmt.Errorf("copy helper: %w", err)
	}
	if err := os.Chmod(helperBin, 0o755); err != nil {
		return err
	}
	plist := fmt.Sprintf(plistTemplate, daemonLabel, helperBin)
	if err := os.WriteFile(daemonPlist, []byte(plist), 0o644); err != nil {
		return fmt.Errorf("write plist: %w", err)
	}
	_ = exec.Command("launchctl", "unload", daemonPlist).Run() // reload if already present
	if out, err := exec.Command("launchctl", "load", "-w", daemonPlist).CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl load: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	fmt.Println("caravel-mac helper installed and running — connect/disconnect no longer prompt")
	return nil
}

// cmdUninstallHelper removes the LaunchDaemon and its files.
func cmdUninstallHelper(_ []string) error {
	if os.Geteuid() != 0 {
		return errors.New("uninstall-helper must run as root")
	}
	_ = exec.Command("launchctl", "unload", daemonPlist).Run()
	_ = os.Remove(daemonPlist)
	_ = os.Remove(helperBin)
	_ = os.Remove(controlSocket)
	fmt.Println("caravel-mac helper removed")
	return nil
}

// helperInstalled reports whether the LaunchDaemon plist is present.
func helperInstalled() bool {
	_, err := os.Stat(daemonPlist)
	return err == nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}

const plistTemplate = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>%s</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
		<string>daemon</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardErrorPath</key><string>/var/log/caravel-mac-helper.log</string>
	<key>StandardOutPath</key><string>/var/log/caravel-mac-helper.log</string>
</dict>
</plist>
`
