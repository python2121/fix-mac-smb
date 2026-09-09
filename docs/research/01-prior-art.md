# Keeping SMB/NFS/AFP volumes mounted on macOS — survey of tools and fixes

## Framing: what macOS actually does

Apple's smbfs client does not auto-reconnect. Once a session dies (sleep, link change, server idle-timeout), the mount stays in `mount` output but I/O either errors or hangs until the kernel deadtimer trips; Finder often still shows a cached mount point ([IMD writeup](https://industrialmonitordirect.com/blogs/knowledgebase/fixing-macos-smb-mount-dropping-on-network-loss)). Every tool below is a workaround for that one gap. Three mechanisms recur: (a) Finder/NetFS mount via `osascript -e 'mount volume "smb://…"'` or `NetFSMountURLSync`, credentials from the login keychain; (b) `mount_smbfs` directly (needs a plaintext or keychain-supplied password, mounts outside `/Volumes` unless privileged); (c) autofs on-demand mounts.

## 1. Commercial / indie apps

**AutoMounter (Pixeleyes)** — [pixeleyes.co.nz/automounter](https://www.pixeleyes.co.nz/automounter/), [App Store](https://apps.apple.com/us/app/automounter/id1160435653?mt=12). Menu-bar app; mounts SMB/AFP/NFS/WebDAV at login, on wake, and on network change (SSID/VPN/interface rules), with Wake-on-LAN. Because of MAS sandboxing it can't mount into `/Volumes` — that needs the "Pro Settings" IAP plus a helper app; the direct-download build includes Pro and a 7-day trial. Price ~US$9.99 + ~US$4 IAP. Complaints: cumulative price ([MacRumors thread](https://forums.macrumors.com/threads/automounter-your-nas-shares-native-macos-app.2007808/)), slow mount at boot, "mount into" creating `share-1` folders on remount, and ctrl.blog's note that it doesn't retry if a share vanishes and will spray credentials at any network unless rules are set ([ctrl.blog](https://www.ctrl.blog/entry/automount-netshare-macos/)). It is the most-recommended fix in the Tahoe threads.

**ConnectMeNow v4 (Tweaking4All)** — free/donationware, `brew install --cask connectmenow` ([site](https://www.tweaking4all.com/software/macosx-software/connectmenow-v4/)). SMB/AFP/NFS/FTP/WebDAV/SSHFS. Triggers on network-change notifications and optional periodic ping of the server IP. Optional periodic reconnect of unavailable shares; WoL. Same untrusted-network leak concern as AutoMounter.

**Mountain (appgineers)** — ~US$6 ([site](https://appgineers.de/mountain/)). Eject-all-on-sleep, then mount "Favorite Servers" on wake; retries unmount after quitting blocking apps. Last release ~1.6.6 (~2018) — legacy.

**Jettison (St. Clair Software)** — ~US$5 ([release notes](https://www.stclairsoft.com/Jettison/release_notes.html), [TidBITS](https://tidbits.com/2025/05/28/appbits-jettison-solves-macos-disk-ejection-annoyances/)). Eject before sleep, remount on wake; supports network volumes. Changelog note: **macOS 26.4 "aggressively remounts disks on wake"**, and Jettison added a "Don't remount these disks" list to suppress it.

**NetMounter (context-tech / jasine)** — free, open source ([GitHub](https://github.com/jasine/net-mounter)). SMB/AFP/WebDAV, mounts per SSID/wired, Bonjour discovery, Keychain.

**Ejectify** — free, MIT ([GitHub](https://github.com/nielsmouthaan/ejectify-macos)): unmount on sleep/display-off, remount on wake, optional privileged helper.

## 2. Open-source projects

| Project | Mechanism |
|---|---|
| [dzombak SMB keepalive v1](https://www.dzombak.com/blog/2024/03/keeping-a-smb-share-mounted-on-macos-and-alerting-when-it-does-down/) / [v2](https://www.dzombak.com/blog/2024/05/Keeping-a-SMB-share-mounted-on-macOS-version-2.html) | LaunchAgent `StartInterval=60`; checks `mount \| grep user@host/share` to find the real mount dir (handles `/Volumes/general-1`), tests `-f $DIR/.liveness.txt`, else `osascript -e 'mount volume "smb://…"'`; wrapped in `runner` with 10 s timeout + pings Uptime Kuma. Password saved once via Finder. |
| [IsraChido gist](https://gist.github.com/IsraChido/f00ecb01854607872d31705979fa0313) | Same pattern for WebDAV; LaunchAgent (not Daemon) because keychain is locked pre-login; `StartInterval` doesn't fire during sleep. |
| [KeepCoolCH/SMBMounter](https://github.com/KeepCoolCH/SMBMounter) | Swift/SwiftUI, macOS 14.6+, MIT. Finder-style mount with hard timeout, sequential queue, sleep/wake + network-loss detection, retry passes, Keychain. |
| [punchdrunktux/MacMount](https://github.com/punchdrunktux/MacMount) | Swift, MIT. AFP/SMB/NFS; `Network.framework` path monitor, sleep/wake handling, VPN-aware, circuit-breaker retry, Keychain. |
| [brendanbirch/SMBMounter](https://github.com/brendanbirch/SMBMounter), [wangxso/LanMount](https://github.com/wangxso/LanMount) | Similar menu-bar Swift tools. |
| [FAU Network Share Mounter](https://www.nsm.faumac.rrze.de/docs/) ([GitLab](https://gitlab.rrze.fau.de/faumac/networkShareMounter)) | Enterprise SwiftUI app: mounts on login and network-state change, Kerberos/SSO, MDM config. Successor of [systemheld/networkShareMounter](https://github.com/systemheld/networkShareMounter). |
| [rudelm autofs gist](https://gist.github.com/rudelm/7bcc905ab748ab9879ea) | Canonical autofs recipe; Python `smb-mount` script whose `--keep` option was needed "or the mounts would go stale". |
| SleepWatcher | `brew install sleepwatcher`; `~/.wakeup` runs `osascript mount volume` on wake. |
| Hammerspoon | `hs.caffeinate.watcher` on `systemDidWake` + `hs.timer.doAfter(5–10s)` + `hs.osascript` mount. Known: watcher sometimes doesn't fire after long sleeps ([issue #2222](https://github.com/Hammerspoon/hammerspoon/issues/2222)). |
| Keyboard Maestro | "System Wake"/"Wireless Network" trigger + Pause + AppleScript mount. |

## 3. Apple built-ins

**autofs** — `/etc/auto_master`: `/- auto_smb -nosuid,noowners`; map line `/System/Volumes/Data/mnt/x -fstype=smbfs,soft,noowners,rw ://user:pass@host/share`; `sudo automount -cv`. Works for on-demand reconnect, but: plaintext credentials, `auto_master` overwritten by OS updates, root-only ownership bug after idle, and on Tahoe users report the mount "present but inaccessible" until `umount` ([Apple thread](https://discussions.apple.com/thread/256195572)).

**Login Items** — mounts once; no retry if network isn't up, no reconnect after sleep, opens a Finder window per share. **Finder sidebar remount** broke in Tahoe 26.0–26.3, restored in 26.4 ([SynoForum](https://www.synoforum.com/threads/smb-mappings-on-macos-tahoe-26-do-not-yet-autoconnect.15298/)). **Wake for network access / Power Nap** serve inbound connections; reports say they do not keep outbound mounts alive.

**`/etc/nsmb.conf`** knobs seen in the wild: `signing_required=no` ([HT205926](https://support.apple.com/HT205926)), `soft=yes`, `dir_cache_max_cnt=0` ([Apple 101918](https://support.apple.com/en-eg/101918)), `protocol_vers_map=4`, `validate_neg_off=yes`, `notify_off=yes`, `port445=no_netbios`. Kernel timers: `sysctl net.smb.fs.kern_deadtimer / kern_soft_deadtimer / kern_hard_deadtimer`.

## 4. What people report actually working

- **Polling remount script** (dzombak-style) — most consistently reported as working; Sequoia 15.5 NFS thread found an `ls` every 5 min prevents idle lockup, 6 min doesn't ([dev forums](https://developer.apple.com/forums/thread/786323)).
- **Keep a Finder window open on the share** — anecdotal.
- **nsmb.conf tweaks** improve throughput/stalls; nobody confirms they fix post-sleep drops. One user's real fix was **Kerberos ticket expiry** (10 h) ([MacRumors](https://forums.macrumors.com/threads/macos-disconnects-from-smb-share.2250090/)).
- **IP instead of `.local`** — recurring advice; pair with DHCP reservation.
- **Server side**: Samba `keepalive = 60`, `deadtime = 300`, `smb2 leases = yes`, Samba wiki "work better with macOS" settings.
- **Stale/hung mounts**: `umount -f` or `diskutil unmountDisk force`; `killall Finder`; FinderSync extensions can pin a volume ([dev forums](https://developer.apple.com/forums/thread/681314)).
- **Tahoe (26)**: sidebar auto-remount broken 26.0–26.3, fixed 26.4; drops "almost every wake" reported 26.0–26.2; 26.4 remounts aggressively on wake and prompts for approval on mounts outside `/Volumes` ([thread](https://developer.apple.com/forums/thread/821197)). TrueNAS forum concludes only reconnect-on-wake tooling helps ([TrueNAS](https://forums.truenas.com/t/macos-tahoe-sleep-and-disconnected-smb-connections-truenas/57413)).

**Takeaway**: the robust design used by everything that works is: LaunchAgent (keychain access) + wake/network-change trigger + delayed retry + liveness probe with a timeout (sentinel file read, not `mount` output) + force-unmount of hung mounts + NetFS remount, resolved to an IP, with network gating so credentials aren't offered on foreign networks.
