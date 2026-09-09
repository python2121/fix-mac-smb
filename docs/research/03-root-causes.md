# macOS SMB fragility: root causes

[F] = well-established (Apple docs, Apple source, DTS/vendor engineers). [A] = anecdotal.

## 1. What happens to an smbfs mount on sleep

[F] macOS cannot keep a TCP session alive through sleep; DTS: "on sleep the CPU stops, meaning there's nothing available to run the networking stack" ([thread 699275](https://developer.apple.com/forums/thread/699275)). The server sees silence, then keepalive failure, idle scavenger, or an RST when the Mac wakes with new state.

[F] The kernel does try to reconnect. From Apple's last open-source smbfs ([aosm/smb](https://github.com/aosm/smb)), same sysctls exist today (`kern_deadtimer=60`, `kern_hard_deadtimer=600`, `kern_soft_deadtimer=30`):
- Echo after 10 s of no I/O; a request with no reply for 30 s (`max_resp_timeout`) or 120 s on send triggers reconnect.
- After 5 s in reconnect the share is marked not responding → "Server connections interrupted" dialog.
- Reconnect loops with backoff for `reconnect_wait_time` (600 s). The iod detects wake and restarts the timer once, then declares dead → `VQ_DEAD` → forced unmount. Pending requests are replayed after reconnect, or fail with `ETIMEDOUT` on soft mounts.

[F] DTS on current macOS: default response timeout 35–45 s depending on server, cap 600 s; durable-handle support on the server *raises* the negotiated timeout; Finder uses **soft** mounts, `mount_smbfs` defaults to **hard** ([thread 798216](https://developer.apple.com/forums/thread/798216)).

[F] Why Finder beachballs: Finder, Spotlight, QuickLook, FinderSync make synchronous VFS calls that block until timeout or reconnect. A reconnect that succeeds at transport but fails durable-handle re-open leaves calls stuck. TrueNAS SMB lead: "failed durable reconnects can cause the MacOS SMB client to hang… we had to remove the SMB session dead timer from FreeNAS because Finder would hang/crash if its session got scavenged while the Mac was sleeping" ([TrueNAS](https://www.truenas.com/community/threads/m1-mac-connected-to-truenas-over-smb-keeps-crashing-workarounds.102465/)).

## 2. Network-layer interactions

- [F] Multichannel (`mc_on` default since 11.3) picks the interface *advertising* the highest speed; Wi-Fi can win over 1 GbE and then drop on sleep ([Apple 102010](https://support.apple.com/en-us/102010)). [A] Tahoe mounts login volumes over Wi-Fi despite Ethernet priority.
- [F] Private/rotating Wi-Fi MAC can force a new DHCP lease at wake; [A] a new IP defeats durable-handle reconnect.
- [F] `.local` names always go to mDNS; records go stale across sleep/interface changes. [A] Mounting by IP or unicast DNS avoids a class of post-wake "server may not exist" errors.
- [A] IPv6 "Link-local only" is a recurring band-aid.
- [F] Sequoia 15.0 firewall bug dropped SMB sessions; fixed by 15.1.
- [F] Network Extension content filters / VPNs tear down existing connections on start/stop; VPN drop on lid-close leaves zombie mounts blocking Finder ~5 min.
- [A] Kerberos: ~10 h disconnects traced to ticket lifetime.

## 3. Multichannel, signing, encryption

- [F] `mc_on=no`, `mc_prefer_wired=yes`, verify with `smbutil multichannel -a`.
- [F] `signing_required` defaults no; SMB3 still requires validate-negotiate and signed non-guest sessions ([Apple 101956](https://support.apple.com/en-us/101956)). [A] Forced server-side signing/encryption is the top throughput complaint, not a stability cause.

## 4. Server side

- [F] Samba `deadtime` only closes sessions with no open files; TCP keepalive default is hours; use `socket options = TCP_NODELAY TCP_KEEPIDLE=… TCP_KEEPINTVL=… TCP_KEEPCNT=…` or `keepalive = 60`. Aggressive scavenging kills durable handles the Mac expects to resume.
- [F] Durable handles let the client "restore lost SMB2 connection after temporary disconnection" (Synology) but disable cross-protocol locking. `fruit:time machine = yes` forces `durable handles = yes`. Samba bug 15022 (durable reconnect fails after SetFileInfo) was found by Apple's client team.
- [A] Toggling durable handles fixes it for some, breaks it for others; `smb2 leases = no` resolved Finder-held locks on `AFP_Resource` streams.
- [F] Samba wiki baseline: `min protocol = SMB2`, `vfs objects = fruit streams_xattr`, `fruit:metadata = stream`, `fruit:nfs_aces = no`, `fruit:veto_appledouble = no` ([Samba wiki](https://wiki.samba.org/index.php/Configure_Samba_to_Work_Better_with_Mac_OS_X)).
- [F] Windows `autodisconnect` default 15 min.

## 5. Bugs by macOS version

- **Sonoma 14.0**: DFS subfolders empty; fixed 14.1.
- **Sequoia 15.0–15.2**: firewall bug; Finder freezes on large copies to DSM 7.2.2. **15.5**: large-share enumeration fix, AFP client deprecated.
- **Tahoe 26.0–26.3**: sidebar/login-item remount broken; restored 26.4. SMBClient-593 deadlocks at >10 Gbps (FB21249476, partly fixed 26.3). DFS referral regression 26.2–26.5. **26.4** [A]: kernel panics mounting a second share from the same server; **26.5**: "Resolved an issue where Mac computers restarted unexpectedly while mounting SMB shares" ([Apple 124963](https://support.apple.com/en-us/124963)). [A] Sleep disconnects "almost every wakeup" ([TrueNAS forum](https://forums.truenas.com/t/macos-tahoe-sleep-and-disconnected-smb-connections-truenas/57413)).
- **macOS 27 beta**: no SMB client rewrite documented; AFP removed ([Eclectic Light](https://eclecticlight.co/2026/04/23/networking-changes-coming-in-macos-27/)). [A] Beta 3 file-system corruption reports involving Time Machine/NAS.
- Apple's public design talks: SNIA SDC 2022 and 2024 "What's New in the macOS SMB Client".
- Finder knobs: `dir_cache_max_cnt=0`, `DSDontWriteNetworkStores`, `mdutil -d` for Spotlight on network volumes.

## 6. "Mounted but hangs" and the dead state

[F] `mount` lists the vnode until the dead timer fires: 60 s soft, 600 s hard, counted from the *end* of the reconnect window (itself up to 10 min). A hard mount can look alive for ~20 min. `umount -f` sends `ENXIO` to outstanding requests; fails when FinderSync, Spotlight, or an app holds a vnode. Soft mounts fail calls after ~12 s and unmount after 60 s; helps scripts more than Finder. [A] Zeroing the deadtimer sysctls is a common undocumented tweak.

## 7. Time Machine, Photos, open handles

- [F] TM over SMB requires durable handles; an interrupted backup leaves the sparsebundle handle open ("already in use") until timeout.
- [F] Photos libraries on network volumes unsupported.
- [A] Apps holding handles (Lightroom, git, Docker/OrbStack) hang hardest post-wake because queued requests are replayed against handles the server may have dropped.

## Bottom line

The fragility is structural: sleep kills the TCP session; recovery depends on server-side durable handles surviving the sleep and the Mac coming back with the same IP/interface; Finder's synchronous VFS calls turn any reconnect delay into a beachball; dead-timer defaults keep zombie mounts visible for up to ~20 minutes. Version-specific regressions stack on top.
