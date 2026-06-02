# Shipping to TestFlight (automated)

One command builds, bumps, and uploads a new TestFlight build:

```sh
fastlane beta
```

It: regenerates the project (XcodeGen) → sets build number to one above the latest on TestFlight → archives & signs → uploads to TestFlight.

## One-time setup on the build machine (the Mac with Xcode + Agrisol signing)
1. Install fastlane: `brew install fastlane` (or `gem install fastlane`).
2. Create an **App Store Connect API key**: App Store Connect → Users and Access → Integrations → App Store Connect API → generate (role: App Manager). Download the `.p8`.
3. Put the `.p8` somewhere **outside the repo**, e.g. `~/.appstoreconnect/AuthKey_<KEYID>.p8`.
4. `cp fastlane/.env.example fastlane/.env` and fill in `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`.
   - `fastlane/.env` and `*.p8` are gitignored — never commit them.

Then `fastlane beta` ships a build with no Xcode GUI needed.
