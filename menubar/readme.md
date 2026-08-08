# Cove Menu Bar (macOS)

A native, dependency-free macOS menu bar companion for Cove. Originally created
by [Robby McCullough](https://github.com/RobbyMcCullough/cove-menubar) (MIT) and
folded into the official Cove project with his blessing.

The menu bar icon shows Cove at a glance:

- **Full color** — Caddy, MariaDB, and Mailpit are all running
- **Light grayscale** — some services are running
- **Dark grayscale** — all services are stopped

The menu can start/stop Cove, refresh status, open the Dashboard / Adminer /
Mailpit, open the logs folder, and register itself to launch at login.

## How it ships

There is no separate download. `compile.sh` embeds these sources into `cove.sh`
(`Sources/main.m` and `Resources/Info.plist` as heredocs, the icon as base64),
and `cove menubar enable` compiles the app locally with `clang`, assembles
`~/Applications/Cove Menu Bar.app`, ad-hoc signs it, and launches it. Building
on the user's machine avoids notarization entirely; anyone with Homebrew
already has the Command Line Tools this needs.

- `cove menubar enable` — install (or update/overwrite) and launch the app
- `cove menubar disable` — quit and remove the app
- `cove upgrade` — refreshes the app only if it is already installed and
  `MENUBAR_VERSION` (in `main`) changed. Strictly opt-in: upgrading Cove never
  installs the menu bar on its own.

When changing anything under `menubar/`, bump `MENUBAR_VERSION` in `main` so
enabled installs pick up the change on their next `cove upgrade`.
