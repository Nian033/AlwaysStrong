<div align="center">

<img src="banner.png" alt="AlwaysStrong" width="700">

<br>
<br>

[![Release](https://img.shields.io/github/v/release/evoker0/AlwaysStrong?color=2ea043&label=release)](https://github.com/evoker0/AlwaysStrong/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/evoker0/AlwaysStrong/total?color=2ea043)](https://github.com/evoker0/AlwaysStrong/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-orange)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-keyboxstrong-26A5E4?logo=telegram&logoColor=white)](https://t.me/keyboxstrong)

<img src="screenshots/webui.jpg" width="44%" alt="WebUI"> &nbsp; <img src="screenshots/languages.jpg" width="44%" alt="Translated into 15 languages">

<sub>Built-in WebUI on KernelSU / APatch — hourly auto-update toggles, translated into 15 languages.</sub>

</div>

# AlwaysStrong

One-flash `STRONG` Play Integrity for Magisk / KernelSU / APatch. It bundles [TEESimulator-RS](https://github.com/Enginex0/TEESimulator-RS) and [PlayIntegrityFork](https://github.com/osm0sis/PlayIntegrityFork) into a single module so you don't have to stack and wire them up yourself.

To use this module you need one of the following (latest versions), with a Zygisk implementation installed:

- [Magisk](https://github.com/topjohnwu/Magisk) with Zygisk enabled  a standalone [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) / [ReZygisk](https://github.com/PerformanC/ReZygisk) / [NeoZygisk](https://github.com/JingMatrix/NeoZygisk) is recommended over Magisk's built-in Zygisk, which is more easily detected
- [KernelSU](https://github.com/tiann/KernelSU) or [KernelSU Next](https://github.com/KernelSU-Next/KernelSU-Next) with [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) or [ReZygisk](https://github.com/PerformanC/ReZygisk) or [NeoZygisk](https://github.com/JingMatrix/NeoZygisk) module installed
- [APatch](https://github.com/bmax121/APatch) with [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) or [ReZygisk](https://github.com/PerformanC/ReZygisk) or [NeoZygisk](https://github.com/JingMatrix/NeoZygisk) module installed

Android 10+ (SDK 29) is required.

## Join group / channel

- Channel: [t.me/keyboxstrong](https://t.me/keyboxstrong)
- Root community: [t.me/evokeroot](https://t.me/evokeroot)
- Chat / support group: [t.me/keyboxstrongchat](https://t.me/keyboxstrongchat)

## Support

If AlwaysStrong is useful to you, you can tip at [coindrop.to/evokerrr](https://coindrop.to/evokerrr).

<a href="https://www.buymeacoffee.com/evokerr" target="_blank">
  <img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=%E2%98%95&slug=evokerr&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff" alt="Buy Me A Coffee" />
</a>

## Features

- **One flash, `STRONG`.** TEESimulator-RS + PlayIntegrityFork in a single module. No stacking, no manual wiring.
- **Keybox on tap.** The first **Action** fetches a working keybox automatically. No hunting, no manual placement.
- **A fingerprint that never goes stale.** Every Action pulls a fresh Pixel fingerprint and matching security patch — and a background service does the same **automatically every hour** (interval configurable, each toggle-able from the WebUI), so your spoof keeps up with Google's rotations even if you never open the module.
- **Hands-off keybox too.** The same hourly service re-checks your keybox and only swaps it in when a newer one is available, restarting Play Integrity only when something actually changed.
- **Auto target.** A native watcher follows package changes via inotify, with a full rebuild on every Action tap and hourly — **install a new app and it's added to the attestation target instantly, with no need to reopen the module or tap Action again.**
- **Xposed-aware.** The same watcher drops Xposed / LSPosed managers from the target list, since attesting through a hooked process breaks `STRONG`.
- **Conflict resolution.** Detects known conflicting modules (TrickyStore, other PIF / TEE forks, SafetyNet Fix, MagiskHidePropsConf, and more) and disables and removes them at install and on every boot, so a leftover module can't silently fight AlwaysStrong.
- **GMS kill.** Force-stops DroidGuard (`com.google.android.gms.unstable`) and clears the Play Store on each refresh, so a new fingerprint or keybox takes effect without a reboot.
- **Security-patch sync.** Keeps the OS / vendor / boot security-patch levels reported in attestation aligned with the spoofed fingerprint.
- **One clean module.** PIF is binary-patched to run inside `tricky_store` — it never litters a separate `playintegrityfix` folder under `/data/adb/modules`.

## About module

AlwaysStrong is two parts glued into one module:

- **TEESimulator-RS** intercepts Binder IPC inside the `keystore2` process and builds full attestation certificate chains from your keybox, so apps that verify hardware key attestation see a legitimate TEE. It is not a fork of TrickyStore; it reuses the same `/data/adb/tricky_store` config layout for drop-in compatibility, but the internals (native Rust certgen, `lsplt` interception, key persistence) are different.
- **PlayIntegrityFork** injects a `classes.dex` to modify `android.os.Build` fields and hooks native code to spoof system properties, only to Google Play Services' DroidGuard (Play Integrity).

The two are merged so they coexist in one module: TEESimulator's `classes.dex` is renamed to `tee_classes.dex` so it doesn't collide with PIF's, and PIF's hardcoded module paths are binary-patched to point at `/data/adb/modules/tricky_store` — it never creates a separate `playintegrityfix` folder. The module id stays `tricky_store` so existing tooling and tutorials keep working unchanged.

## Installation

1. Install a Zygisk implementation (Zygisk Next / ReZygisk / NeoZygisk).
2. Download the latest ZIP from [Releases](https://github.com/evoker0/AlwaysStrong/releases/latest).
3. Flash it in your root manager and reboot.
4. Open the module and tap **Action**.
5. Check your verdict with a checker (Play Integrity API Checker, YASNAC, Simple PIC).

The first Action tap fetches a working keybox and a fresh Pixel fingerprint and restarts Play Integrity, so there is no manual keybox step. The installer also removes conflicting standalone modules at install time (TrickyStore, PlayIntegrityFix/Fork, TEESimulator, playcurl/playcurlNEXT, SafetyNet Fix, MagiskHidePropsConf, Tricky Addon, Yurikey, and a few others).

### Which build to download

Each release ships two builds:

- **`AlwaysStrong-<version>.zip`** — the default, and what [Releases](https://github.com/evoker0/AlwaysStrong/releases/latest) points to. Built on PlayIntegrityFork; covers arm64-v8a, armeabi-v7a, x86 and x86_64.
- **`AlwaysStrong-<version>-inject.zip`** — built on PlayIntegrityFix (inject-s). A different spoof engine; try it if the default doesn't reach `STRONG` on your device.

Both install on all four ABIs. On x86 / x86_64 prefer the default build: PlayIntegrityFix inject-s builds no x86 zygisk, so the inject zip installs and runs its attestation half there but cannot spoof Play Integrity (it tells you at install time). Each build updates within its own line, so switching between them means flashing the other zip.


## Configuration

All config files live at `/data/adb/tricky_store/` and are reloaded automatically when changed. The Action button keeps them current, so most users never need to touch these.

### keybox.xml

The attestation keybox. Fetched automatically on the first Action tap. To use your own, place it here and it won't be overwritten. To point the auto-refresh at a different mirror, set `KEYBOX_URL` (any raw HTTPS URL that returns a valid keybox) at the top of `keybox_fetch.sh`; the script validates the payload before replacing the current file, so a bad download can't break attestation.

## The Action button

Triggered from your root manager, or by running `sh action.sh` in a root shell. Each tap:

- rebuilds `target.txt`
- refreshes the keybox
- pulls a fresh Pixel fingerprint and security patch
- restarts DroidGuard and the Play Store

The verdict updates a few seconds later. No reboot is needed. The same fingerprint, security-patch and keybox refresh also runs on its own in the background every hour (interval configurable from the WebUI), so the module keeps passing with zero manual upkeep.

## Building

The repo ships no upstream binaries. `build.sh` downloads the pinned upstream release ZIPs, overlays the glue scripts in `module/`, and produces the installable ZIPs. On Windows run it from WSL or Git Bash (7-Zip is used automatically when Info-ZIP `zip` is missing).

```bash
./build.sh                              # both release lines
./build.sh --variant fork               # only the default build
./build.sh --variant inject             # only the -inject build
./build.sh --clean                      # wipe build/ and rebuild
./build.sh --tee v6.0.1-307             # override the TEESimulator-RS tag
```

Every run produces both lines:

- `out/AlwaysStrong-<version>.zip` — the default build (PlayIntegrityFork)
- `out/AlwaysStrong-<version>-inject.zip` — the PlayIntegrityFix inject-s build

### Other keystore engines (self-build only)

Releases only ever ship the TEESimulator-RS build. The keystore layer can instead be swapped for the open-source [TrickyStoreOSS](https://github.com/beakthoven/TrickyStoreOSS) — never published, so build it yourself by pointing `build.sh` at the upstream release ZIP:

```bash
./build.sh --engine trickystoreoss --tsoss-file Tricky-Store-OSS-v3.0.0-...-Release.zip
```

The output ZIP gets a `-TSOSS` suffix; drop `--tsoss-file` to auto-download the pinned release. Both engines read the same `/data/adb/tricky_store/` config, so the scripts and WebUI are unchanged.

Both default lines are built from this one tree — there is no second branch:

```
module/                                 everything the two lines share
module-variants/<line>/build.conf       upstream pin + which files to lift
module-variants/<line>/module.prop.override
module-variants/<line>/ship/engine.sh   the only engine-specific module script
```

`engine.sh` is the whole seam. It answers three questions the rest of the module never has to care about: which prop file this engine's zygisk reads, what its STRONG spoof flags are called, and how upstream's own fingerprint fetcher is invoked. Adding a third engine means adding one directory, not a branch.

`version` / `versionCode` live only in `module/module.prop` — a line may not override them, so the two builds can never disagree about which release they are.

To pull upstream and repackage in one go:

```bash
scripts/update-upstream.sh --apply --build
```

That bumps TEESimulator-RS in `build.sh` and each line's Play Integrity engine in its own `build.conf`, to the newest upstream release — **prereleases included**, which is where TEESimulator-RS publishes its freshest builds — and rebuilds both zips. Drop `--build` to only bump, add `--stable-only` to ignore prereleases. A weekly GitHub Action runs the same check and opens one PR.

## Credits

<div align="center">
<img src="screenshots/built-on.png" alt="AlwaysStrong stands on the shoulders of TEESimulator-RS and PlayIntegrityFork" width="600">
</div>

AlwaysStrong is combine of TEE-Simulator-RS + Play Integrity Fork

- [JingMatrix](https://github.com/JingMatrix/TEESimulator) — original TEESimulator and keystore2 interception
- [Enginex0](https://github.com/Enginex0/TEESimulator-RS) — TEESimulator-RS (Rust port, native certgen, AOSP-spec attestation)
- [5ec1cff](https://github.com/5ec1cff/TrickyStore) — TrickyStore, which pioneered keystore interception and the config-dir layout reused here
- [beakthoven](https://github.com/beakthoven/TrickyStoreOSS) — TrickyStoreOSS, the open-source keystore engine offered as a self-build option
- [chiteroman](https://github.com/chiteroman) — original Play Integrity Fix
- [osm0sis](https://github.com/osm0sis/PlayIntegrityFork) — PlayIntegrityFork, the maintained fork bundled here
- [Displax](https://github.com/Displax/safetynet-fix) — module boot scripts forked into PIF
- [daboynb](https://github.com/daboynb/playcurlNEXT) — fingerprint auto-refresh approach
- [LSPlt](https://github.com/LSPosed/LSPlt) (PLT hooks) and [ring](https://github.com/briansmith/ring) (Rust crypto)
- [KOWX712](https://github.com/KOWX712) — PlayIntegrityFix (inject-s), used by the `-inject` build, and KsuWebUIStandalone

Packaging by [@evokerr](https://t.me/evokerr).



## License

GPL-3.0. AlwaysStrong bundles TEESimulator-RS (GPL-3.0), which makes the combined distribution GPL-3.0. See [LICENSE](LICENSE) and the upstream repos for full terms. Provided as-is, with no warranty; `STRONG` depends on a non-revoked hardware keybox, which the module cannot mint for you.
