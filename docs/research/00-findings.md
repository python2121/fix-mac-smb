# Findings from building and running this on a real machine

Observed on macOS 27.0 beta (build 26A5406e) against a Samba server with
`vfs_fruit`, over Wi-Fi, with two SMB shares mounted. Hosts, share names and
accounts below are placeholders.

## Baseline

- `smbutil statshares` reported SMB 3.1.1, signing AES-128-GMAC, encryption off,
  and zero session reconnects while healthy.
- Kernel timers, unchanged from the defaults:

| sysctl | Value |
|---|---|
| `net.smb.fs.kern_deadtimer` | 60 |
| `net.smb.fs.kern_soft_deadtimer` | 30 |
| `net.smb.fs.kern_hard_deadtimer` | 600 |

- No `/etc/nsmb.conf` and no custom `auto_master`. Power Nap was on, and the
  machine dark-woke every two to five minutes for "Maintenance Sleep", each one
  another chance for an SMB session to half-reconnect.
- macOS login items listed both volumes for reopening at login, yet one of them
  was not mounted. The built-in mechanism was already failing before any of this
  code ran.
- The unified log carried no SMB client entries at all, under every predicate
  tried. The kernel SMB client logs privately on this build, so the tool's own
  log is the only timeline available.

## A mount can be listed and still be dead

Both mounts stopped answering at the same moment while the server stayed
healthy: ICMP replied in 3 ms, TCP 445 accepted connections, the web interface
returned HTTP 200. During the ten minutes that followed:

- `netstat` showed only one established session to port 445 although two shares
  were mounted, so one session's connection was already gone.
- Every filesystem call into either mount blocked, including `statfs`, `ls` and
  `smbutil statshares`.
- `unmount(2)` with `MNT_FORCE`, called directly with a deadline, hung for 25
  seconds and never returned. `umount -f` and `diskutil unmount force` timed out
  on every attempt.
- Both mounts answered again with no intervention about ten minutes in, matching
  `kern_hard_deadtimer`. On a later occurrence the kernel force-unmounted them
  instead, and the mount points vanished from `/Volumes` entirely.

Three design conclusions followed:

1. A wedged smbfs mount cannot be cleared from user space. Force unmount is not
   a reliable recovery, it is one more call that blocks. Attempts now back off,
   stop after a cap, and report that a restart may be needed.
2. Every probe against a wedged mount parks a thread in the kernel until the
   kernel gives up, so probing on a timer would leak one thread per tick. The
   prober refuses to start a second probe for a path that already has one
   outstanding and reports `hung` immediately.
3. Waiting is a legitimate recovery. `soft=yes` in `/etc/nsmb.conf` is the only
   lever that shortens the window, which is why `doctor` recommends it when no
   `nsmb.conf` exists.

## The tool's own worst bug: privacy gating looks exactly like a hung mount

The mounts wedged twice while the agent ran, each time with the server healthy.
The decisive experiment ran the identical app binary two ways:

| How the app was started | Probe result |
|---|---|
| From a terminal, inheriting the terminal's privacy rights | healthy, 77 and 83 ms |
| By launchd, as its own responsible process | every probe hung |

The bundle declared no usage-description keys. Reading a network volume is gated
by Privacy & Security > Files and Folders, and for a background app that cannot
prompt, the access **blocks** rather than failing fast. The tool read that as a
hung mount and force-unmounted a healthy volume, wedging it for every other
process for the next ten minutes. It was manufacturing the failure it existed to
prevent.

Fixes, all of which are in the code now:

1. The bundle declares `NSNetworkVolumesUsageDescription`,
   `NSRemovableVolumesUsageDescription` and `NSDesktopFolderUsageDescription`.
   With those present, the launchd-started app probes successfully.
2. A mount that has never answered a probe **in this process** is never
   unmounted. Recovery applies only to a volume the process has seen working and
   then seen fail; anything else is reported as a probable permissions problem.
3. The first probe after the privacy check costs about 6 s, and 10.5 s was
   observed once, so the probe timeout moved from 8 s to 15 s and the stale grace
   from 20 s to 240 s.

Ad-hoc signing changes the app's code identity on every rebuild, so the grant
resets and macOS asks again. A stable signing identity avoids that.

## NetFS will crash you if the dispatch queue dies

A test binary calling `NetFSMountURLAsync` crashed with `EXC_BAD_ACCESS` inside
`NetAuth`'s `__NAConnectToServerStart_block_invoke`. The queue had been created
as the argument expression, so it was released as soon as the call returned, and
NetAuth does not retain it. `Mounter` keeps one long-lived static queue, and a
comment there records why.

## Smaller notes

- Mounting through NetFS with the NoUI option and a keychain entry for the host
  took about 0.25 s. Keychain items are keyed by the server name as spelled, so a
  host mounted by Bonjour name has no usable entry when mounted by IP.
- Kernel mount-table notifications (`com.apple.system.kernel.mount` and
  `.unmount`) fire reliably and give a reaction within about 1.5 s.
- A second `mount_smbfs` to a fresh share returned a definite error in well
  under a second while two existing mounts were wedged, which is how a
  per-session failure can be told apart from a wedged client.
- `smbutil view` output puts the share name in a space-padded column and the
  comment column contains single spaces, so rows must be split on runs of two or
  more spaces to survive share names that contain a space.
