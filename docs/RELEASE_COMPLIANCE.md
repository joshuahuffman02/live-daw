# Release Compliance Gate

This is an engineering release checklist, not legal advice. Record the chosen basis
and owner for each item before distributing a binary or installing the production
venue image.

## AutoMix Native

`AutoMix Native.app` uses Apple's Core Audio APIs and the repository's independent
C++ DSP/control core. It does **not** link the JUCE framework. Its production release
still requires:

- an Apple Developer ID Application identity, Hardened Runtime, notarization, and a
  stapled ticket, enforced by `scripts/build-notarized-release.sh`;
- a licensed and activated Dante Virtual Soundcard installation on each venue Mac
  when DVS is the selected Core Audio route;
- the venue's permission and operational ownership for Planning Center credentials,
  recordings, retention, and remote-monitor network access;
- retention of applicable third-party notices for anything later added to the app.

Dante Virtual Soundcard is an external dependency and is not bundled in this
repository or its release archive. Its current licensing and activation requirements
are maintained in the
[official DVS documentation](https://dev.audinate.com/GA/dvs/userguide/webhelp/content/licensing_tab.htm).

## Optional JUCE portability appliance

The separate CMake target `BroadcastMixer` links JUCE 8. Do not distribute that
binary until the owner has documented either:

1. an applicable JUCE commercial licence, or
2. release under and compliance with the AGPLv3 terms.

JUCE states that version 8 is dual-licensed under its commercial licence and AGPLv3;
the current terms and eligibility limits belong to JUCE, not this repository. Review
the [official JUCE licensing page](https://juce.com/get-juce/) and
[JUCE 8 EULA](https://juce.com/legal/juce-8-licence/) for the actual decision.

The JUCE shell is a portability/validation target. It is not required to sign,
notarize, install, or run `AutoMix Native.app`.

## Evidence to retain

- `build-metadata.json`, `notary-result.json`, `signed-entitlements.plist`, ZIP
  SHA-256, and the stapled app;
- the exact source commit and CI run used for the build;
- Apple, DVS, and any JUCE licence/account records that apply;
- the venue profile and signed sermon/worship acceptance bundles, with secrets
  excluded.
