---
name: release
description: Release a new version of OpenClaw macOS app from the o6w.ai monorepo. Builds, signs, notarizes, creates DMG, and publishes to GitHub Releases.
allowed-tools: Bash, Read, Edit, Grep
---

# OpenClaw Release Skill

Release the OpenClaw bundled macOS app from the `o6w.ai` monorepo.

## Repo Structure

```
o6w.ai/
├── website/          # Landing page (Vercel)
├── openclaw/         # OpenClaw source (build from here)
│   ├── apps/macos/   # Swift menu bar app
│   ├── scripts/      # package-mac-app.sh, codesign-mac-app.sh
│   ├── dist/         # Build output (gitignored)
│   ├── .cache/node/  # Cached Node.js binary (gitignored)
│   └── ...
└── vercel.json
```

## Credentials

| Credential | Value/Source |
|-----------|-------------|
| SIGN_IDENTITY | `Developer ID Application: Matthew Diakonov (S6DP5HF77G)` |
| TEAM_ID | `S6DP5HF77G` |
| APPLE_ID | `matthew.heartful@gmail.com` |
| NOTARIZE_PASSWORD | From omi-desktop `.env`: `***REDACTED***` |
| GitHub repo | `m13v/o6w.ai` |

## Release Process

### Step 1: Get commits since last release

```bash
cd /Users/matthewdi/o6w.ai/openclaw
LAST_TAG=$(gh release list --repo m13v/o6w.ai --limit 1 --json tagName -q '.[0].tagName')
echo "Last release: $LAST_TAG"
```

### Step 2: Build the app

```bash
cd /Users/matthewdi/o6w.ai/openclaw
rm -rf dist/OpenClaw.app
SIGN_IDENTITY="Developer ID Application: Matthew Diakonov (S6DP5HF77G)" scripts/package-mac-app.sh
```

This runs the full pipeline:
1. Builds JS gateway (`pnpm build`)
2. Builds Swift app (`swift build`)
3. Downloads/caches Node.js 22 binary
4. Copies gateway files + node_modules into app bundle
5. Prunes node_modules (removes dev deps, non-darwin platforms, broken symlinks)
6. Signs everything with Developer ID (JIT entitlements for Node.js, all Mach-O binaries)

### Step 3: Verify signing

```bash
spctl --assess --type exec --verbose dist/OpenClaw.app
# Should say: "rejected, source=Unnotarized Developer ID" (expected before notarization)
# If it says anything else, signing is broken — investigate before proceeding
```

### Step 4: Notarize with Apple

```bash
cd /Users/matthewdi/o6w.ai/openclaw

# Create ZIP for submission
ditto -c -k --keepParent dist/OpenClaw.app dist/OpenClaw.zip

# Submit and wait (typically 5-15 minutes)
xcrun notarytool submit dist/OpenClaw.zip \
  --apple-id "matthew.heartful@gmail.com" \
  --password "***REDACTED***" \
  --team-id "S6DP5HF77G" \
  --wait

# Staple the ticket
xcrun stapler staple dist/OpenClaw.app
```

### Step 5: Verify Gatekeeper

```bash
spctl --assess --type exec --verbose dist/OpenClaw.app
# MUST say: "accepted, source=Notarized Developer ID"
```

If it says "rejected (invalid destination for symbolic link in bundle)" — there are broken symlinks in node_modules. The packaging script should clean these, but if not:
```bash
find dist/OpenClaw.app -type l ! -exec test -e {} \; -print  # find them
find dist/OpenClaw.app -type l ! -exec test -e {} \; -delete  # remove them
# Then re-sign and re-notarize
```

### Step 6: Create DMG

```bash
cd /Users/matthewdi/o6w.ai/openclaw
DMG_DIR=$(mktemp -d)
cp -R dist/OpenClaw.app "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "OpenClaw" -srcfolder "$DMG_DIR" -ov -format UDZO dist/OpenClaw.dmg
rm -rf "$DMG_DIR"

# Notarize the DMG too
xcrun notarytool submit dist/OpenClaw.dmg \
  --apple-id "matthew.heartful@gmail.com" \
  --password "***REDACTED***" \
  --team-id "S6DP5HF77G" \
  --wait
xcrun stapler staple dist/OpenClaw.dmg
```

### Step 7: Create GitHub Release

```bash
cd /Users/matthewdi/o6w.ai/openclaw
gh release create vX.Y.Z \
  --repo m13v/o6w.ai \
  --title "OpenClaw vX.Y.Z" \
  --notes "$(cat <<'EOF'
## Changes
- ...

Signed and notarized with Apple Developer ID.
EOF
)" \
  dist/OpenClaw.dmg
```

## Troubleshooting

### Notarization fails
```bash
# Get the submission log
xcrun notarytool log <submission-id> \
  --apple-id "matthew.heartful@gmail.com" \
  --password "***REDACTED***" \
  --team-id "S6DP5HF77G"
```
Common cause: unsigned Mach-O binary in gateway. Fix in `scripts/codesign-mac-app.sh` by adding the binary name to the find pattern.

### Team ID mismatch
The codesign script has a `verify_team_ids` step. If it fails:
- A pre-signed binary (from npm) has a different team ID
- Fix: ensure ALL Mach-O binaries are re-signed with our identity
- The codesign script signs: `.node`, `.so`, `.dylib`, `spawn-helper`, `esbuild`, `tsgo`, `tsgolint`
- If a new binary type appears, add it to the find pattern in `scripts/codesign-mac-app.sh`

### Recursive app nesting in dist/
The packaging script uses `rsync --exclude='*.app'` when copying `dist/` to prevent the built `.app` from being copied into itself. If this breaks, the Team ID check will catch it.

### Stapling fails
Apple CDN propagation delay. Wait a few minutes and retry `xcrun stapler staple`.

## Key Files

| File | Purpose |
|------|---------|
| `openclaw/scripts/package-mac-app.sh` | Build + bundle + sign pipeline |
| `openclaw/scripts/codesign-mac-app.sh` | Code signing (identities, entitlements, Team ID audit) |
| `openclaw/apps/macos/` | Swift source for menu bar app |
| `openclaw/dist/` | Build output (gitignored) |
