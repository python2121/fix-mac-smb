# SMB Keeper

Menu bar app that keeps SMB volumes mounted. Built with SwiftPM and the
Command Line Tools only; there is no Xcode on the development machine and it
is not to be installed. See README.md for layout, build, and design notes.

- Build with `make`, test with `make test`, bundle with `make app`.
- Never use `@State`. The macOS 27 SDK implements it as a Swift macro whose
  plugin (`libSwiftUIMacros.dylib`) ships only with Xcode, so it fails under
  the Command Line Tools with "plugin for module 'SwiftUIMacros' not found".
  Use `@ViewState` from `Sources/SMBKeeperApp/ViewState.swift` instead; it is
  a drop-in and `$binding` keeps working. `@Binding`, `@ObservedObject`,
  `@StateObject`, `@Environment`, and friends are unaffected. The Makefile and
  `scripts/make-app.sh` reject any `@State` under `Sources/`.
- Do not pin `SDKROOT` to an older SDK to work around this; it breaks when a
  Command Line Tools update prunes the old SDK.
