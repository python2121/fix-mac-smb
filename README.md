# SMB Keeper

Keeps SMB network volumes mounted and answering on macOS: after login, after
sleep and wake, after Wi-Fi drops and returns, and when a mount is listed but
hangs every program that touches it.

It is a small Swift package with three parts that share one engine:

- `smbkeeper`, a command line tool for setup, diagnostics, and control.
- `SMB Keeper.app`, a menu bar app that runs the engine and shows each share's state.
- A launchd agent so the app starts at login and is restarted if it ever exits.

No Xcode project is required. It builds with `swift build` and the tests are a
plain executable, not XCTest.

## Why macOS needs this

The research behind the design is in `docs/research/`. The short version:

- Sleep kills the TCP session. On wake the kernel SMB client tries to reconnect
  for up to ten minutes, and during that time the volume is still listed but
  every filesystem call blocks. That is the "connected but hangs" state.
- Finder's login items and sidebar remount a volume once, with no retry and no
  reconnect after sleep. On Tahoe 26.0 through 26.3 even that was broken.
- Bonjour names go stale across sleep; an IP or unicast DNS name does not.
- Power Nap dark-wakes the Mac every few minutes, each time giving the session a
  chance to half-reconnect and lose its server-side handles.

## How it works

For every configured share, a controller runs this loop on its own queue:

1. Look at the kernel mount table with `getfsstat(MNT_NOWAIT)`, which never
   contacts the server.
2. If the share is mounted, probe it with `statfs` and a short directory read on
   a throwaway thread with a hard deadline. A probe that does not return in time
   means the mount is hung. Healthy probes double as the keepalive touch.
3. If the mount has been hung longer than the grace period, force-unmount it
   with `umount -f` and then `diskutil unmount force`, each in a subprocess with
   its own deadline. The grace period is long on purpose. On a dead session even
   `umount -f` blocks in the kernel, while the kernel's own dead timer unmounts
   the volume reliably after about ten minutes, so waiting is usually the better
   recovery. Attempts back off and stop after a cap rather than piling up.
4. If the share is not mounted, first try a TCP connection to port 445. No
   connection, no mount attempt, so credentials are never sprayed at a foreign
   network and nothing fires before Wi-Fi is back.
5. Mount through `NetFSMountURLAsync`, the same path Finder uses, with the NoUI
   option so the login keychain supplies the password or the attempt fails
   silently. Mounts are always soft. Failed mounts back off exponentially.

The loop runs on a timer (every 60 seconds by default), immediately after a
real wake (dark wakes are ignored), after a network path change, and whenever
the kernel reports the mount table changed.

## Build and test

```
make            # debug build
make test       # run the test harness (76 tests, no XCTest)
make app        # build/SMB Keeper.app, ad-hoc signed
make install    # copy to ~/Applications, link CLI into ~/bin, start at login
make uninstall  # remove the agent, app, and CLI link (config and logs stay)
```

## Setup

```
smbkeeper shares 10.0.0.20 --user you       # what does the server export?
smbkeeper add --server 10.0.0.20 --share Projects --user you
smbkeeper add --server 10.0.0.20 --share Archive --user you --eject-on-sleep
smbkeeper doctor
```

`add` prompts for the password once and stores it in the login keychain as an
Internet Password item trusted for NetAuthAgent, exactly the shape Finder
writes. If Finder already saved a password for that server name, `add` skips
the prompt.

Prefer an IP address or a unicast DNS name for `--server`. If your Mac already
has a keychain entry for a short host name that your router resolves, use that
name and no password entry is needed at all.

Then either `make install`, or run the pieces by hand:

```
smbkeeper daemon --verbose         # engine in the foreground
open "build/SMB Keeper.app"        # menu bar app (also runs the engine)
smbkeeper install-agent            # launchd runs the CLI daemon at login
smbkeeper install-agent --app "$HOME/Applications/SMB Keeper.app"
```

Only one engine should run at a time. The second one notices the first and exits.

## Day-to-day

```
smbkeeper status                   # what the daemon sees
smbkeeper log --follow             # tail the log
smbkeeper check                    # re-check everything now
smbkeeper mount Projects           # mount one share now
smbkeeper unmount Projects --force # force-unmount one share
smbkeeper pause / resume
smbkeeper probe [name]             # one-shot evaluation without a daemon
smbkeeper shares <server>          # list what a server exports
smbkeeper doctor                   # mounts, reachability, keychain, knobs
```

Left-clicking the menu bar icon opens a panel; right-clicking gives a plain
menu as a fallback. The icon itself shows a checkmark when every share is
healthy, an exclamation mark when one is stale or failing, and an X when one is
unmounted.

The panel lists every share worst first: anything needing attention is at the
top, healthy shares below, paused ones last. Each row carries a state badge, the
share's name, how full the volume is, a bar showing the same, an Eject button, a
Reveal in Finder button, and a chevron. Opening a row adds unmount, force
unmount and stop-monitoring buttons plus a six-field detail grid. The footer
sums up the shares and free space and holds check-now, open-log, add-share and a
settings menu.

"Add share" opens a panel: type a server and account, optionally a password,
then press "Find Shares" to ask the server what it exports and pick one from
the list. Shares already being monitored are left out of that list, and you can
type a share name directly if the server is not answering. A typed password is
written to the login keychain through the same kind of item Finder creates, so
macOS can mount silently afterwards; the secret is passed to `security` over a
pipe rather than on a command line where other processes could read it.

Stop monitoring forgets a share and leaves the volume exactly as it is, mounted
or not. Ejecting before sleep is a per-share setting the CLI can toggle with
`smbkeeper set <name> eject-on-sleep on|off`.

The configuration file is edited by the app and the CLI, so there is no menu
item for opening or reloading it. `smbkeeper` changes take effect immediately
because the CLI tells the running app to re-read the file.

## Files

| Path | Purpose |
|---|---|
| `~/Library/Application Support/SMBKeeper/config.json` | shares and settings |
| `~/Library/Application Support/SMBKeeper/status.json` | written by the daemon, read by `status` |
| `~/Library/Application Support/SMBKeeper/commands/` | CLI to daemon commands |
| `~/Library/Logs/SMBKeeper/smbkeeper.log` | rotating log (5 MB x 3) |
| `~/Library/LaunchAgents/io.github.smbkeeper.plist` | launch agent |

Every setting in `config.json` is optional and documented in
`Sources/SMBKeeperCore/Config.swift`. The ones worth knowing:

| Setting | Default | Meaning |
|---|---|---|
| `tickSeconds` | 60 | health check and keepalive interval |
| `probeTimeoutSeconds` | 15 | how long a probe may block before the mount is hung |
| `staleGraceSeconds` | 240 | how long a hung mount is tolerated before force unmount |
| `maxForceUnmountAttempts` | 5 | after this many failed force unmounts, stop retrying and report |
| `settleAfterWakeSeconds` | 4 | delay after wake before checking |
| `mountTimeoutSeconds` | 45 | deadline for NetFS |
| `backoffMinSeconds` / `backoffMaxSeconds` | 5 / 300 | retry delays after failed mounts |

## Recommended system changes

These are outside the tool and optional; `smbkeeper doctor` reports them.

- Remove the network volumes from System Settings > General > Login Items so
  Finder and SMB Keeper do not race each other at login.
- `sudo pmset -a powernap 0` if you find dark wakes are what kill your sessions.
- An `/etc/nsmb.conf` with `soft=yes`, `port445=no_netbios`, and
  `protocol_vers_map=6` makes the kernel give up on a dead server in about a
  minute instead of ten.

## Design notes

- Nothing that can block on a dead mount runs on a thread the engine needs
  back. Probes use a fresh `Thread` per call; unmounts are subprocesses.
- Mounts are serialised process-wide. Mounting two shares from the same server
  at once has been reported to panic recent kernels.
- The daemon ignores its timer while flagged asleep, but clears the flag if the
  user is typing, so a missed wake notification cannot strand it.
- The CLI talks to the daemon with JSON files plus a Darwin notification. No
  XPC, no sockets, and commands survive a daemon restart.
- IOKit's power message constants do not import into Swift; they are spelled
  out in `PowerMonitor.swift` from the `iokit_common_msg` formula.

## First run

After `make install`, macOS asks once whether SMB Keeper may access files on
network volumes. Approve it. Until you do, every probe blocks and the menu
shows each share as `stale` with "never answered since startup"; the tool
deliberately does nothing else in that state, so nothing is unmounted. The
`smbkeeper` command run from a terminal is unaffected, because it inherits the
terminal's permissions, so `smbkeeper doctor` and `smbkeeper probe` work either
way.

## Privacy permissions

macOS gates access to network volumes behind Privacy & Security > Files and
Folders. A background app that has not been granted it does not get a quick
error: the access **blocks**, which looks exactly like a hung mount. The app
bundle therefore declares `NSNetworkVolumesUsageDescription`, and SMB Keeper
never unmounts a volume it has not seen working in the current process, so a
permissions problem can never be mistaken for a dead mount and "recovered" by
unmounting a healthy volume.

If a share sits in the `stale` state saying it has never answered since
startup, while the volume works fine in Finder, allow SMB Keeper under
System Settings > Privacy & Security > Files and Folders, or give it Full Disk
Access. Because `make app` signs ad hoc, the app's identity changes on every
rebuild and the permission may need to be granted again; use a Developer ID
identity via `CODESIGN_IDENTITY` to keep it stable.

## Local Network privacy

On macOS 15 and later, a process that is denied under System Settings >
Privacy & Security > Local Network cannot open sockets to LAN hosts, and the
error it gets looks like "Network is down" or "No route to host". The kernel
SMB client is not subject to that setting, so mounts still work. SMB Keeper's
reachability gate recognises the pattern, falls back to `ping`, and proceeds
with the mount attempt anyway, logging one warning. If you see that warning,
allow SMB Keeper (or the terminal you run `smbkeeper` from) in that panel.
