# Witness 0.6.30 (33)

The Secure Input warning refreshes automatically and points to a password field
that may be active in an open tab or window. The menu uses single-line labels for
Dictation, Notetaker, and Files. Notetaker is labeled Beta and its shorter
summary still asks the user to verify speaker labels.

The native suite finished with 1,282 passed, 11 skipped, and zero failures. It
rendered all three tabs in light and dark appearances.

## Published artifact verification

- Published as the latest stable GitHub release on 25 November 2026 at 19:37
  Europe/Prague. Tag `v0.6.30` points to the build source at
  `ce6253e1d5d191cfbaae8ad3337d03aa38b52315`.
- Apple accepted notarization for the app
  (`4e39f361-e66e-424b-99f7-3171fa405097`) and the disk image
  (`bc99c232-aa66-44eb-8753-46ec76f4a5ea`). Both tickets were stapled and
  validated. Gatekeeper accepted both as Notarized Developer ID.
- The public 0.6.29 disk image matched its published digest. Its signed app
  supplied the public key that verified the 0.6.30 disk image and signed
  appcast. The appcast offers build 33 for macOS 14.4 and later.
- The latest appcast and the 102,023,092-byte website download returned HTTP 200
  and matched the local signed assets byte for byte.
- `Witness.dmg` SHA-256 is
  `89fc3daa6c062040c524d75792f55a0b2363971a3facf80271c1d61f455c30a5`.
- `appcast.xml` SHA-256 is
  `0a6112c8e10a7b5f382827ecade527620f28401cc60b692c18faf0bfa87ef395`.

[GitHub release](https://github.com/igskak/localdictation/releases/tag/v0.6.30)
