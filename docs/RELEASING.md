# Releasing Markzzy

The `Release` workflow at `.github/workflows/release.yml` fires on any tag
matching `v*`. On success it produces a signed + notarized `.dmg`, publishes
a GitHub Release, and inserts a row into the Supabase `app_releases` table so
that `https://markzzy.tech/api/releases/appcast.xml` picks it up for Sparkle.

## One-time setup

### 1. Sparkle EdDSA keys

Install Sparkle's key tools and generate a key pair:

```bash
brew install --cask sparkle
generate_keys
# prints Public key: <BASE64>
# prints a keychain item with the private key
```

`generate_keys` stores the private key in your macOS Keychain. Export it:

```bash
# Copy the private key (base64) to clipboard:
generate_keys -x ~/markzzy_sparkle_private.pem   # export private key
```

Keep the `.pem` somewhere safe (you'll paste its contents into
`SPARKLE_ED_PRIVATE_KEY`). The public key goes into `SPARKLE_ED_PUBLIC_KEY`.

### 2. Apple Developer ID certificate

From Keychain Access on a machine where you have the cert:

1. Find **Developer ID Application: <your name / team>** under "My Certificates"
2. Right-click → Export → save as `DeveloperID.p12` with a password
3. Base64 encode it:
   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```
   → that's the value for `APPLE_CERTIFICATE_BASE64`.
4. Copy the cert's common name (e.g. `Developer ID Application: Cristian X (ABC123)`)
   → that's `APPLE_SIGNING_IDENTITY`.

### 3. Apple notarization credentials

1. Apple ID email → `APPLE_ID`
2. App-specific password (appleid.apple.com → Sign-In & Security → App-Specific Passwords)
   → `APPLE_APP_PASSWORD`
3. Team ID (Apple Developer → Membership) → `APPLE_TEAM_ID`

### 4. Supabase service role

The `.env.production` of the web project has it:

```
SUPABASE_SERVICE_ROLE_KEY=<copy>
```

### 5. Set GitHub Secrets

In `Crisodevelop/Markzzy` → Settings → Secrets and variables → Actions → New
repository secret. Add all nine:

| Name | Value |
|---|---|
| `SPARKLE_ED_PUBLIC_KEY` | public key from step 1 |
| `SPARKLE_ED_PRIVATE_KEY` | private key (full PEM / base64 contents) from step 1 |
| `APPLE_CERTIFICATE_BASE64` | step 2 |
| `APPLE_CERTIFICATE_PASSWORD` | the password you set when exporting the p12 |
| `APPLE_SIGNING_IDENTITY` | cert common name, step 2 |
| `APPLE_ID` | step 3 |
| `APPLE_APP_PASSWORD` | step 3 |
| `APPLE_TEAM_ID` | step 3 |
| `SUPABASE_SERVICE_ROLE_KEY` | step 4 |

## Cutting a release

```bash
# Bump the version you want to ship (this gets written into Info.plist +
# Sparkle sees it as the new available version).
git tag v0.1.1
git push origin v0.1.1
```

Watch the `Release` workflow in the Actions tab. On success:

- A GitHub Release appears with the `.dmg` attached.
- The Supabase `app_releases` row is inserted.
- Installed copies of Markzzy hit the appcast on their next periodic check
  and prompt the user to update.

## Troubleshooting

- **`sign_update not found`** — the Sparkle SPM package ships `sign_update` as
  an executable target; if `find .build -name sign_update` returns empty in
  CI, add an explicit `swift build -c release --product sign_update` step
  before that stage.
- **Notarization "Invalid"** — check `xcrun notarytool log <submission-id>
  --apple-id ... --team-id ...` locally; common causes are missing hardened
  runtime flag or unsigned nested binaries.
- **Update prompt never fires** — verify the appcast XML renders correctly at
  `https://markzzy.tech/api/releases/appcast.xml` and that the installed
  version is strictly older than what's in the feed.
