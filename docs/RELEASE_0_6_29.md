# Witness 0.6.29 (32)

Witness transcribes selected audio and video files locally with the active
speech model. The Files tab opens file selection, progress, and saved
transcripts. The transcript library lets users replay passages from the original
file, check marked text, and export copies. Setup points to Files after the
practice dictation.

The native suite completed with 1,281 passed, 11 opt-in tests skipped, and
zero failures. A local MP4 passed through Parakeet Ultra, the file library, and
subtitle export. The signed distribution uses the same Developer ID and Sparkle
public key as 0.6.28.

## Published artifact verification

- Published on 22 November 2026 at 21:16 Europe/Prague as the latest stable
  release. Tag `v0.6.29` points to the build source at
  `22792888b45b0715e3070910ec741d1fbd24de65`.
- Apple accepted notarization for the app
  (`c8d1b34c-4610-45b7-a0b6-12011c6c6cc1`) and the disk image
  (`0800d3cb-e9fa-4014-97b9-8df02510f8cd`). Both tickets were stapled and
  validated. Gatekeeper accepted both as Notarized Developer ID.
- The public 0.6.28 image matched its published digest. Its app was
  signature-verified and supplied the public key for verifying both 0.6.29
  update signatures. The signed feed offers build 32 for macOS 14.4 and later.
- Both uploaded digests matched the local assets. The public latest feed and
  the 102,017,333-byte website download matched the signed assets byte for
  byte. The download returned HTTP 200.
- The German and English privacy and trial pages were verified live before
  publication. The website test suite passed all 73 tests.
- `Witness.dmg` SHA-256 is
  `a9d23330dc1d73d644277972960b52d4ad438e950223ec4b41d2123da61d2efd`.
- `appcast.xml` SHA-256 is
  `7186c6b76c6348921a870227fddafe607c84369d20338f4977ada561bf656b66`.

[GitHub release](https://github.com/igskak/localdictation/releases/tag/v0.6.29)
