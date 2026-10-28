# Hesper Remote

**Hesper Remote** is the owned, Hesper-branded remote-control engine for Hesper OS
(https://hesper.work) — a fork of RustDesk (https://github.com/rustdesk/rustdesk,
AGPL-3.0), rebranded and pointed at Spout Technologies' self-hosted relay.

It is the standalone engine that the Hesper Local Agent supervises **at arm's
length** (fork/exec — zero linkage) for governed remote-support sessions.

## Rebrand vs upstream RustDesk 1.4.8
- Name "Hesper Remote" (APP_NAME, macOS PRODUCT_NAME, window title, tray).
- Bundle `dev.spout.hesperremote`; URL scheme `hesperremote://`.
- Hesper icon (brand green #7460ff).
- Relay baked into `libs/hbb_common/src/config.rs`: `159.195.16.230`
  (hbbs 21116 / hbbr 21117), key `XU1zOo6SpZYfNGlsb3iMNRaEHEDYLsgEirPgI6VNt8c=`.
- Internal crate/bin names (`rustdesk`, `librustdesk`, `service`, `naming`)
  unchanged on purpose (build scripts + Dart imports depend on them).

Forked from RustDesk tag **1.4.8** (`3c574a41`), hbb_common (`387603f4`).

## Build
macOS is built + Developer-ID-signed + notarized in CI
(`.github/workflows/hesper-remote-macos.yml`), reusing RustDesk's `bridge.yml`.
Trigger: `gh workflow run hesper-remote-macos.yml`, or push a `v*` tag.
Windows: unsigned + HELD until `WINDOWS_CODE_SIGN_PFX_BASE64` is added.

## Licence
AGPL-3.0-or-later — see `LICENCE` (inherited from RustDesk) and `NOTICE`.
