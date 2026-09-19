# SMB Keeper

Keeps SMB network volumes mounted and answering on macOS: after login, after
sleep and wake, after Wi-Fi drops and returns, and when a mount is listed but
hangs every program that touches it.

It is one menu bar app, `SMB Keeper.app`, plus a launchd agent so it starts at
login and is restarted if it ever exits. Everything happens in the menu bar:
there is no command line tool and nothing to configure by hand.

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
make test       # run the test harness (65 tests, no XCTest)
make app        # build/SMB Keeper.app, ad-hoc signed
make install    # copy to ~/Applications and start at login
make uninstall  # remove the agent and the app (config and logs stay)
```

## Setup

Open the app, press + at the bottom of the panel, and fill in the server and
your account. Press "Find Shares" to ask the server what it exports and pick
one from the list, or type a share name if the server is not answering. Shares
already being monitored are left out of the list.

A password is only needed the first time for a given server, and only if Finder
has not already saved one. It is written to the login keychain as an Internet
Password item trusted for NetAuthAgent, exactly the shape Finder writes, so
macOS can mount silently from then on. The secret goes to `security` over a pipe
rather than on a command line where other processes could read it.

Prefer an IP address or a unicast DNS name for the server. Bonjour names go
stale across sleep, which is one of the failure modes this app exists to fix.

## Day-to-day

There is nothing to do. The panel exists for when something looks wrong.

Left-clicking the menu bar icon opens it; right-clicking gives a plain menu with
the same essentials. The icon shows a checkmark when every share is healthy, an
exclamation mark when one is stale or failing, and an X when one is unmounted.

Shares are listed worst first: anything needing attention is at the top, healthy
ones below, paused ones last. A row is a state badge, the share's name, where it
is mounted or what is wrong with it, and three buttons. The first follows the
volume: mount when nothing is attached, unmount when something is, and force
once an unmount has been asked for and the volume is still there. Then reveal in
Finder, and stop monitoring, which forgets the share and leaves the volume
exactly as it is. The footer holds check-now, open-log, add-share and a settings
menu.

Ejecting cleanly before sleep is a per-share setting, `ejectOnSleep` in
`config.json`, off by default.

## Files

| Path | Purpose |
|---|---|
| `~/Library/Application Support/SMBKeeper/config.json` | shares and settings |
| `~/Library/Application Support/SMBKeeper/status.json` | what the panel is showing, and the single-instance guard |
| `~/Library/Logs/SMBKeeper/smbkeeper.log` | rotating log (5 MB x 3) |
| `~/Library/LaunchAgents/io.github.smbkeeper.plist` | launch agent |

The app writes `config.json` itself. Every setting in it is optional and
documented in `Sources/SMBKeeperCore/Config.swift`; edit it by hand only for one
of the tunables below, and relaunch the app afterwards.

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

These are outside the app and optional.

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
- IOKit's power message constants do not import into Swift; they are spelled
  out in `PowerMonitor.swift` from the `iokit_common_msg` formula.
- Never use `@State`. The macOS 27 SDK implements it as a macro whose plugin
  ships only with Xcode, so it does not build with the Command Line Tools.
  Use `@ViewState` (`Sources/SMBKeeperApp/ViewState.swift`), a drop-in with the
  same `$binding` behaviour. `make` and `make app` refuse to build if `@State`
  appears anywhere under `Sources/`.

## First run

After `make install`, macOS asks once whether SMB Keeper may access files on
network volumes. Approve it. Until you do, every probe blocks and every share
reads `stale` with "never answered since startup". The app deliberately does
nothing else in that state, so nothing is unmounted.

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
allow SMB Keeper in that panel.
