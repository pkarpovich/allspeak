# Release / TestFlight CI

Allspeak ships to TestFlight via GitHub Actions. Every push to `main`
triggers `.github/workflows/deploy-testflight.yml` which signs, archives,
and uploads the build using App Store Connect API authentication.

## Apple Developer setup (one-time)

### 1. Apple Distribution certificate

Reuse the same Apple Distribution certificate that the other apps in
the `karpovich` team (e.g. `tuclaw-app`) use, or create a new one:

1. https://developer.apple.com/account/resources/certificates/list →
   `+` → **Apple Distribution**
2. Generate a CSR in Keychain Access (Certificate Assistant → Request
   a Certificate From a Certificate Authority → save to disk)
3. Upload the CSR, download the `.cer`, double-click to install in
   the login keychain
4. In Keychain Access, find "Apple Distribution: <Your Name>",
   right-click → Export, choose `.p12` format, set a strong password.
   Keep that password — it becomes the `CERTIFICATE_PASSWORD` secret

```bash
# Encode the .p12 for GitHub:
base64 -i Certificate.p12 -o cert.b64
# Then paste cert.b64's contents into the CERTIFICATE_P12 secret.
```

### 2. App ID and provisioning profile

1. https://developer.apple.com/account/resources/identifiers/list →
   register App ID `dev.karpovich.allspeak` if it doesn't exist.
   Capabilities: enable **Background Modes** (Audio).
2. https://developer.apple.com/account/resources/profiles/list →
   `+` → **App Store** → select the `dev.karpovich.allspeak` App ID →
   pick the Apple Distribution certificate → name it
   `Allspeak App Store`, download the `.mobileprovision`

```bash
base64 -i Allspeak_App_Store.mobileprovision -o profile.b64
# Paste profile.b64's contents into PROVISIONING_PROFILE_IOS.
```

### 3. App Store Connect API key

1. https://appstoreconnect.apple.com/access/integrations/api → `+` →
   role **App Manager** → download the `.p8` (one-time only)
2. Note the **Key ID** and the team **Issuer ID** shown next to the
   key list

The `.p8` file contents go into `ASC_KEY_CONTENT` as plain text (not
base64), the Key ID into `ASC_KEY_ID`, the Issuer ID into
`ASC_ISSUER_ID`.

### 4. App Store Connect app record

https://appstoreconnect.apple.com/apps → `+` → New App → bundle ID
`dev.karpovich.allspeak`, platform iOS. Without this record TestFlight
processing fails.

## GitHub secrets to add

Settings → Secrets and variables → Actions → New repository secret:

| Secret                       | Value                                              |
| ---------------------------- | -------------------------------------------------- |
| `CERTIFICATE_P12`            | base64 of the `.p12` from step 1                   |
| `CERTIFICATE_PASSWORD`       | the password you set when exporting the `.p12`     |
| `PROVISIONING_PROFILE_IOS`   | base64 of the `.mobileprovision` from step 2       |
| `ASC_KEY_ID`                 | App Store Connect API key ID                       |
| `ASC_ISSUER_ID`              | App Store Connect API issuer ID                    |
| `ASC_KEY_CONTENT`            | full text of the `.p8` (including `-----BEGIN…`)   |

The certificate, ASC key ID, ASC issuer ID, and ASC key content can be
reused across all apps that ship to the same Apple Developer team.
Only the provisioning profile is app-specific.

## How the workflows work

### `verify.yml` (pull requests)

Builds and runs the full Swift Testing suite against an iOS 26
Simulator with code signing disabled. No secrets needed. Catches
compile errors and test regressions before merge.

### `deploy-testflight.yml` (push to main, or manual trigger)

1. Decodes the certificate and provisioning profile into a temporary
   keychain
2. Writes `Allspeak/Signing.xcconfig` with **Manual** signing,
   `Apple Distribution` identity, and `PROVISIONING_PROFILE_SPECIFIER`
   pinned to the profile's UUID
3. Runs `xcodegen generate`
4. Sets the build number from `git rev-list --count HEAD` (monotonic,
   unique per commit on main)
5. `xcodebuild archive` produces the `.xcarchive`
6. `xcodebuild -exportArchive` exports with `app-store-connect`
   method and uploads using App Store Connect API key authentication
   (no Apple ID prompt, no per-release "choose profile" dialog)

## Why no prompts during release

The "select certificate / select profile / sign in to Apple ID"
prompts that the user typically hits in Xcode go away because:

- Signing is **manual** with `PROVISIONING_PROFILE_SPECIFIER` pinned
  to a UUID in `Signing.xcconfig` → Xcode / xcodebuild has nothing to
  choose
- Authentication for the upload is via App Store Connect API key
  (`-authenticationKeyID` / `-authenticationKeyIssuerID` /
  `-authenticationKeyPath`) → no Apple ID 2FA dance
- The certificate lives in a temporary keychain created on the runner
  and torn down after the job → no manual keychain unlock

## Local development

Locally you don't need any of the above. `Allspeak/Signing.xcconfig`
ships with `CODE_SIGN_STYLE = Automatic` so Xcode signs Debug builds
with your personal Apple ID. The CI workflow overwrites that file
in-place during the deploy job, so don't worry about it conflicting.

If `Signing.xcconfig` is missing locally (it's git-ignored), copy
`Signing.xcconfig.example` to `Signing.xcconfig`.

## Manual deploy

You can trigger a deploy without pushing to main:

GitHub → Actions → "Deploy to TestFlight" → Run workflow → pick the
branch → Run.
