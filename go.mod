module github.com/PharosVPN/caravel-mac

go 1.25.7

require (
	fyne.io/systray v1.12.1
	github.com/PharosVPN/caravel/core v0.0.0-00010101000000-000000000000
	github.com/amnezia-vpn/amneziawg-go v0.2.18
	golang.org/x/term v0.43.0
)

require (
	github.com/godbus/dbus/v5 v5.1.0 // indirect
	golang.org/x/crypto v0.51.0 // indirect
	golang.org/x/net v0.54.0 // indirect
	golang.org/x/sys v0.44.0 // indirect
	golang.zx2c4.com/wintun v0.0.0-20230126152724-0fa3db229ce2 // indirect
)

replace github.com/PharosVPN/caravel/core => ../caravel/go
