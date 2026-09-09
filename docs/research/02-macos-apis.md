# macOS APIs and mechanisms for a Swift mount-keeper

## 1. Mounting: NetFS.framework

NetFS is a C framework in the SDK with a module map; `import NetFS` works in Swift. Headers: `NetFS.h`, `NetFSUtil.h`, `NetFSPlugin.h`.

```c
int NetFSMountURLSync(CFURLRef url, CFURLRef mountpath, CFStringRef user, CFStringRef passwd,
    CFMutableDictionaryRef open_options, CFMutableDictionaryRef mount_options, CFArrayRef *mountpoints);
typedef void (^NetFSMountURLBlock)(int status, AsyncRequestID requestID, CFArrayRef mountpoints);
int NetFSMountURLAsync(CFURLRef url, CFURLRef mountpath, CFStringRef user, CFStringRef passwd,
    CFMutableDictionaryRef open_options, CFMutableDictionaryRef mount_options,
    AsyncRequestID *requestID, dispatch_queue_t dispatchq, NetFSMountURLBlock mount_report);
int NetFSMountURLCancel(AsyncRequestID requestID);
```

Return 0 on success; positive = errno; negative = OSStatus (`-128` userCanceledErr, `-5998` no shares, `-6602` kNetAuthErrorMountFailed, `-6600` internal).

**Option keys.** `open_options`: `kNAUIOptionKey` = `kNAUIOptionNoUI` / `AllowUI` / `ForceUI`; `kNetFSUseGuestKey`; `kNetFSForceNewSessionKey`; `kNetFSUseAuthenticationInfoKey`. `mount_options`: `kNetFSSoftMountKey`, `kNetFSMountAtMountDirKey`, `kNetFSAllowSubMountsKey`, `kNetFSMountFlagsKey` (integer `MNT_*` flags, e.g. `MNT_DONTBROWSE`), `kNetFSNoUserPreferencesKey`. Result keys: `kNetFSMountedURLKey`, `kNetFSMountPathKey`.

**DTS guidance** ([forum 94733](https://developer.apple.com/forums/thread/94733)): never call the Sync variant; build the URL with `URLComponents`; pass nil `mountpath` and let NetFS choose `/Volumes/<share>`. With `kNAUIOptionNoUI` and a Keychain entry, NetAuthAgent authenticates silently; if it can't, it fails rather than prompting ([forum 69144](https://developer.apple.com/forums/thread/69144)). Sync reported to hang on Apple Silicon ([forum 716729](https://developer.apple.com/forums/thread/716729)); use Async with your own timeout and `NetFSMountURLCancel`.

**App Sandbox.** Mounting under `/Volumes` returns `EPERM` in a sandboxed app ([forum 15729](https://developer.apple.com/forums/thread/15729)). Ship non-sandboxed (Developer ID + notarized, or ad hoc for personal use).

**CLI fallbacks.** `mount_smbfs [-N] [-o soft,nobrowse,...] //user@server/share path`; `smbutil view //server` (cheap "is SMB answering" probe); `smbutil statshares -m /Volumes/X` (`-f Json`), `smbutil multichannel -a`. All can hang; run via `Process` with a kill timer.

## 2. Sleep/wake/boot detection

**NSWorkspace** (`NSWorkspace.shared.notificationCenter`, GUI session only): `willSleepNotification`, `didWakeNotification`, `screensDidWakeNotification`, `sessionDidBecomeActiveNotification`. A LaunchAgent with `LimitLoadToSessionType = Aqua` receives them; a LaunchDaemon does not. DTS says they're inconsistent across hardware ([forum 796109](https://developer.apple.com/forums/thread/796109)).

**IOKit** (`IOPMLib.h`): `IORegisterForSystemPower`. Messages: `kIOMessageCanSystemSleep` (must Allow/Cancel), `kIOMessageSystemWillSleep` (must `IOAllowPowerChange`; place to unmount cleanly), `kIOMessageSystemWillPowerOn`, `kIOMessageSystemHasPoweredOn` (1–5 s after wake). **Dark wake:** `kIOMessageSystemHasPoweredOn` is not delivered for dark wake, so reacting to it naturally ignores Power Nap wakes ([forum 770517](https://developer.apple.com/forums/thread/770517)). Keep machine awake during a remount with `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep, ...)`.

**launchd.** `RunAtLoad` + `KeepAlive: true` (respecting `ThrottleInterval`). `KeepAlive.NetworkState` is "no longer implemented". Wake is not a launchd event. After wake, Wi-Fi/DHCP/VPN come up several seconds after `SystemHasPoweredOn`; gate remounts on a network-path event plus backoff.

## 3. Network change detection

- **`NWPathMonitor`**: `path.status == .satisfied`, `path.availableInterfaces`, `path.usesInterfaceType(.wifi/.wiredEthernet/.other)`. VPN tunnels appear as `utunN` type `.other`; macOS has several utun by default ([forum 671678](https://developer.apple.com/forums/thread/671678)).
- **`SCDynamicStore`**: watch `State:/Network/Global/IPv4` (PrimaryInterface), pattern `State:/Network/Interface/.*/IPv4`, `State:/Network/Interface/en0/AirPort`.
- **SSID**: `CWWiFiClient` returns nil on macOS 14+ without Location authorization in a bundled app ([forum 737455](https://developer.apple.com/forums/thread/737455)). Prefer subnet/router MAC or "path satisfied on interface X" gating, or simply a TCP probe to the server.

## 4. Health-checking and force-unmounting

DTS ([forum 798216](https://developer.apple.com/forums/thread/798216)): each VFS driver controls blocking; client timeout is `max_resp_timeout` (35–45 s effective, cap 600 s); a **hard** mount (`mount_smbfs` default) can block syscalls ~10 min, `-o soft` fails after ~1 min. Any path-based syscall on a dead mount blocks in-kernel and cannot be cancelled.

**Pattern:** never touch the mount path on the main thread or a shared serial queue. Probe from a dedicated thread/global queue with `DispatchSemaphore.wait(timeout:)` or a task race; timeout = hung. Probe with `statfs()`/`getattrlist()` on the mount point. Non-blocking enumeration: `getfsstat(buf, size, MNT_NOWAIT)` returns cached statfs for all mounts without contacting the server; check `f_fstypename == "smbfs"` and `f_mntfromname`. Budget for leaked probe threads.

**Force unmount.** `umount -f`, `diskutil unmount force`, or `DADiskUnmount(disk, kDADiskUnmountOptionForce, ...)` all end in `unmount(2)`; can spin for minutes on a dead smbfs; no lazy unmount on macOS. Run from a subprocess with a timeout. Fails when FinderSync/Spotlight/an app holds a vnode.

## 5. Mount/unmount notifications

- **NSWorkspace**: `didMountNotification` / `didUnmountNotification` / `willUnmountNotification` (`volumeURLUserInfoKey`). Works in practice for /Volumes SMB mounts; DTS says it excludes network volumes in principle and misses submounts ([forum 118537](https://developer.apple.com/forums/thread/118537)).
- **Darwin notify** (DTS-recommended): `notify_register_dispatch(kNotifyVFSMount, ...)` / `kNotifyVFSUnmount`, then diff `getfsstat(MNT_NOWAIT)` snapshots.
- **DiskArbitration**: `DARegisterDiskAppearedCallback` / `DisappearedCallback` with match `{kDADiskDescriptionVolumeNetworkKey: true}`; `kDADiskDescriptionVolumeKindKey == "smbfs"`.

## 6. Keychain

Finder/NetAuthAgent stores passwords as `kSecClassInternetPassword` with `kSecAttrProtocol = kSecAttrProtocolSMB`, `kSecAttrServer`, optional `kSecAttrPath`, `kSecAttrAccount`. A third-party binary reading them triggers an allow dialog per item, and re-signing re-prompts. Cleaner: call `NetFSMountURLAsync` with nil user/password and `kNAUIOptionNoUI` and let NetAuthAgent consult the keychain. If storing your own, write SMB internet-password items so Finder can use them too. Note: keychain lookup is by server name, so mounting by IP needs a keychain item for the IP (or explicit credentials).

## 7. Packaging

Mounts belong to a user session and Keychain is per user; `SMAppService` says LaunchAgents cannot be registered outside a user context. Use a **LaunchAgent**, not a LaunchDaemon. Standard pattern: menu-bar app (`NSStatusItem`, `LSUIElement`) registered via `SMAppService.mainApp.register()` (macOS 13+), or embed `Contents/Library/LaunchAgents/<label>.plist` with `RunAtLoad`, `KeepAlive`, `LimitLoadToSessionType = Aqua` and use `SMAppService.agent(plistName:)`. For a personal tool a plain `~/Library/LaunchAgents` plist pointing at a SwiftPM binary is simplest.

## 8. nsmb.conf effects (current man page)

- `soft=yes` — syscalls fail after ~1 min instead of ~10; kernel force-unmounts after persistent errors. Best single knob.
- `max_resp_timeout` — per-request wait.
- `dir_cache_off` is not in the current man page; only `dir_cache_max/min/async_cnt`. Apple's article uses `dir_cache_max_cnt=0`.
- `signing_required` default no. Disabling signing is a security trade-off, not a stability fix.
- `mc_on`, `mc_prefer_wired=yes` ([Apple 102010](https://support.apple.com/en-ca/102010)).
- `port445=no_netbios` — faster failure when the server is down.
- `protocol_vers_map=6` (SMB2/3) or `4` (SMB3 only) ([Apple 102050](https://support.apple.com/en-us/102050)).
- `notify_off=yes`, `submounts_off`, `validate_neg_off` (only for specific broken servers).

Other: [Emory Dunn Swift NetFS sample](https://emorydunn.com/blog/2017/05/20/swift-network-shares/), [Disk Arbitration guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ArbitrationBasics/ArbitrationBasics.html).
