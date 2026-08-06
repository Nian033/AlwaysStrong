# AlwaysStrong changelog

## v1.0.3

Newer TEE engine, a quieter installer, and both builds shipped from one release.

**Attestation engine**
- TEESimulator-RS bumped to `v6.0.1-307`. Upstream ships its newest builds as GitHub *prereleases*, which the update checker's `/releases/latest` lookup silently skipped — so the module sat on `v6.0.1-282` (19 Jun) while `-307` (11 Jul) was out. The checker now scans every non-draft release.

**Install output**
- Trimmed the noise: no more "default keybox installed", no "WebUI ready" (the WebUI is right there in your manager), and Zygisk just reports `zygisk found`. The KernelSU-without-Zygisk warning stays — that one silently costs you STRONG.

**Per-app keybox in the default build**
- The default build gains what had only shipped in the `-inject` one: the multi-keybox WebUI (assign a keybox per app), the target-list rebuild behind it, native fingerprint fetch via `asfetch autopif` (~2–5s, against ~24s for the shell crawl), and logcat / ANR / tombstone sanitisation. None of it was engine-specific.

**One tree, two builds**
- The two lines were separate branches, which meant writing every fix twice. They share one tree now: `module/` for everything common, `module-variants/<line>/` for what differs — chiefly an `engine.sh` adapter naming the prop file that engine's zygisk reads, its spoof-flag names, and how its fetcher runs. One `./build.sh` emits both zips, and `version` is defined once.

**Architectures**
- The `-inject` build installs on x86 / x86_64 instead of aborting, and now carries x86 TEE libraries and watcher. Its Play Integrity spoof is still ARM-only — PlayIntegrityFix inject-s builds no x86 zygisk — so on x86 the installer says so and points at the default build.

**Credits**
- Added KOWX712 (PlayIntegrityFix inject-s, KsuWebUIStandalone).

## v1.0.2

New keybox mirror, a far more reliable fetcher, a custom-keybox file picker in the WebUI, strong-integrity fixes, and a faster, steadier Action.

**Strong integrity**
- **The fingerprint reaches PlayIntegrityFork.** PIF's zygisk reads `custom.pif.prop` from the module dir; every fetch path — native, autopif4, and the shipped fallback — now runs `migrate.sh` to produce that file and enforces the STRONG spoof settings (`spoofProvider=0`, `spoofVendingFinger=1`), so STRONG holds with a valid keybox (3 green).
- **Strong survives the hourly refresh.** The hourly fingerprint refresh regenerated `custom.pif.prop` but skipped re-applying the STRONG spoof settings, so ~1 h after boot the fingerprint silently reverted to a weak config (`spoofProvider=1`, `spoofVendingFinger=0`) and STRONG dropped even though the WebUI still showed 3 green. The native fetch now enforces the STRONG settings itself, and the hourly loop re-enforces them, so every refresh stays strong.
- **Faster fingerprint.** The fast native crawl (~10s) is primary; autopif4 — whose crawl stalls up to ~1 min on some devices — is the fallback.

**ROM spoof**
- The disable list now matches PlayIntegrityFork's current engines (adds `persist.sys.pp.*`, plus AOSPA / PixelOS / Afterlife detection). Uninstalling AlwaysStrong now restores the ROM's own spoof engines — the persist props it set are cleared on uninstall (only if still unchanged), so removing the module frees PixelProps / pihooks / entryhooks again.

**Keybox & status**
- Moved to the new mirror: keybox from `http://evoker.qzz.io/key`, status from `/status`.
- The WebUI status now shows which keybox is in use (e.g. `evokerrkey27`) alongside the health.

**Custom keybox (WebUI)**
- New "Custom keybox" toggle — use your own keybox instead of the auto one.
- Built-in file manager to pick a keybox from storage: breadcrumb path, folder navigation, file size + date, and sort (name / newest / oldest).
- While custom keybox is on, the module stops auto-fetching (Action shows "custom keybox — skip fetch").

**Fingerprint**
- The fingerprint is now fetched by a native crawl of the same Google servers PlayIntegrityFork uses — fast and reliable on devices where autopif4's busybox-wget crawl used to hang. autopif4 is kept as a bounded fallback, and shipped static fingerprints guarantee one always lands.
- The Action never shows a bare "offline": a failed primary is shown once as "trying with fallback", and it drops through quickly (bounded timeouts).

**Fetcher (asfetch)**
- Rewritten to connect IPv4-first — fixes "keybox missing" and stuck downloads on networks that advertise IPv6 in DNS but have no working IPv6 route.
- Handles http + https, redirects, chunked responses, and custom request headers.
- Every download (keybox, status, fingerprint crawl, WebUI) falls back across asfetch → busybox wget → curl → wget, so it works on every device.

**Misc**
- Removed the "recheck in ~1 min" line from the Action output.

## v1.0.1

Hotfix, same upstream as v1.0.0.

- Added a native fetcher (Rust/rustls) so the keybox downloads on every device — busybox's TLS was stalling on the mirror.
- Action button no longer hangs, and it stops force-enabling Magisk's Enforce DenyList.
- Smaller banner / lighter zip.

## v1.0.0

Initial release.

- Bundles TEESimulator-RS v6.0.1-282 (Rust TEE simulator, hardware attestation injection)
- Bundles PlayIntegrityFork v17 (zygisk Build/property spoofing for GMS DroidGuard)
- Installer removes conflicting standalone modules (TrickyStore, PIF, USNF, MHPC, etc.)
- Bootloader / verified-boot prop spoofing in `post-fs-data.sh`
- Late OEM-specific prop spoofing in `service.sh` (Samsung, Realme, OnePlus, Xiaomi, Oppo)
- Action button refreshes fingerprint via `autopif4` and restarts PI processes via `killpi`
- Optional keybox auto-fetch (`keybox_fetch.sh`) — set `KEYBOX_URL` to any raw HTTPS URL
- Daemon classpath renamed to `tee_classes.dex` so PIF zygisk's `classes.dex` lookup doesn't collide
- `build.sh` / `build.ps1` download pinned upstream release ZIPs and repackage — rebuild on any upstream release by bumping the version variables
