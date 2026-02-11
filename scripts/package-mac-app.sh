#!/usr/bin/env bash
set -euo pipefail

# Build and bundle OpenClaw into a minimal .app we can open.
# Outputs to dist/OpenClaw.app

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ROOT="$ROOT_DIR/dist/OpenClaw.app"
BUILD_ROOT="$ROOT_DIR/apps/macos/.build"
PRODUCT="OpenClaw"
BUNDLE_ID="${BUNDLE_ID:-ai.openclaw.mac.debug}"
PKG_VERSION="$(cd "$ROOT_DIR" && node -p "require('./package.json').version" 2>/dev/null || echo "0.0.0")"
BUILD_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BUILD_NUMBER=$(cd "$ROOT_DIR" && git rev-list --count HEAD 2>/dev/null || echo "0")
APP_VERSION="${APP_VERSION:-$PKG_VERSION}"
APP_BUILD="${APP_BUILD:-$GIT_BUILD_NUMBER}"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
BUILD_ARCHS_VALUE="${BUILD_ARCHS:-$(uname -m)}"
if [[ "${BUILD_ARCHS_VALUE}" == "all" ]]; then
  BUILD_ARCHS_VALUE="arm64 x86_64"
fi
IFS=' ' read -r -a BUILD_ARCHS <<< "$BUILD_ARCHS_VALUE"
PRIMARY_ARCH="${BUILD_ARCHS[0]}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-AGCY8w5vHirVfGGDGc8Szc5iuOqupZSh9pMj/Qs67XI=}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/openclaw/openclaw/main/appcast.xml}"
AUTO_CHECKS=true
if [[ "$BUNDLE_ID" == *.debug ]]; then
  SPARKLE_FEED_URL=""
  AUTO_CHECKS=false
fi
if [[ "$AUTO_CHECKS" == "true" && ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "ERROR: APP_BUILD must be numeric for Sparkle compare (CFBundleVersion). Got: $APP_BUILD" >&2
  exit 1
fi

build_path_for_arch() {
  echo "$BUILD_ROOT/$1"
}

bin_for_arch() {
  echo "$(build_path_for_arch "$1")/$BUILD_CONFIG/$PRODUCT"
}

sparkle_framework_for_arch() {
  echo "$(build_path_for_arch "$1")/$BUILD_CONFIG/Sparkle.framework"
}

merge_framework_machos() {
  local primary="$1"
  local dest="$2"
  shift 2
  local others=("$@")

  archs_for() {
    /usr/bin/lipo -info "$1" | /usr/bin/sed -E 's/.*are: //; s/.*architecture: //'
  }

  arch_in_list() {
    local needle="$1"
    shift
    for item in "$@"; do
      if [[ "$item" == "$needle" ]]; then
        return 0
      fi
    done
    return 1
  }

  while IFS= read -r -d '' file; do
    if /usr/bin/file "$file" | /usr/bin/grep -q "Mach-O"; then
      local rel="${file#$primary/}"
      local primary_archs
      primary_archs=$(archs_for "$file")
      IFS=' ' read -r -a primary_arch_array <<< "$primary_archs"

      local missing_files=()
      local tmp_dir
      tmp_dir=$(mktemp -d)
      for fw in "${others[@]}"; do
        local other_file="$fw/$rel"
        if [[ ! -f "$other_file" ]]; then
          echo "ERROR: Missing $rel in $fw" >&2
          rm -rf "$tmp_dir"
          exit 1
        fi
        if /usr/bin/file "$other_file" | /usr/bin/grep -q "Mach-O"; then
          local other_archs
          other_archs=$(archs_for "$other_file")
          IFS=' ' read -r -a other_arch_array <<< "$other_archs"
          for arch in "${other_arch_array[@]}"; do
            if ! arch_in_list "$arch" "${primary_arch_array[@]}"; then
              local thin_file="$tmp_dir/$(echo "$rel" | tr '/' '_')-$arch"
              /usr/bin/lipo -thin "$arch" "$other_file" -output "$thin_file"
              missing_files+=("$thin_file")
              primary_arch_array+=("$arch")
            fi
          done
        fi
      done

      if [[ "${#missing_files[@]}" -gt 0 ]]; then
        /usr/bin/lipo -create "$file" "${missing_files[@]}" -output "$dest/$rel"
      fi
      rm -rf "$tmp_dir"
    fi
  done < <(find "$primary" -type f -print0)
}

echo "📦 Ensuring deps (pnpm install)"
(cd "$ROOT_DIR" && pnpm install --no-frozen-lockfile --config.node-linker=hoisted)
if [[ "${SKIP_TSC:-0}" != "1" ]]; then
  echo "📦 Building JS (pnpm build)"
  (cd "$ROOT_DIR" && pnpm build)
else
  echo "📦 Skipping JS build (SKIP_TSC=1)"
fi

if [[ "${SKIP_UI_BUILD:-0}" != "1" ]]; then
  echo "🖥  Building Control UI (ui:build)"
  (cd "$ROOT_DIR" && node scripts/ui.js build)
else
  echo "🖥  Skipping Control UI build (SKIP_UI_BUILD=1)"
fi

cd "$ROOT_DIR/apps/macos"

echo "🔨 Building $PRODUCT ($BUILD_CONFIG) [${BUILD_ARCHS[*]}]"
for arch in "${BUILD_ARCHS[@]}"; do
  BUILD_PATH="$(build_path_for_arch "$arch")"
  xcrun swift build -c "$BUILD_CONFIG" --product "$PRODUCT" --build-path "$BUILD_PATH" --arch "$arch" -Xlinker -rpath -Xlinker @executable_path/../Frameworks
done

BIN_PRIMARY="$(bin_for_arch "$PRIMARY_ARCH")"
echo "pkg: binary $BIN_PRIMARY" >&2
echo "🧹 Cleaning old app bundle"
rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT/Contents/MacOS"
mkdir -p "$APP_ROOT/Contents/Resources"
mkdir -p "$APP_ROOT/Contents/Frameworks"

echo "📄 Copying Info.plist template"
INFO_PLIST_SRC="$ROOT_DIR/apps/macos/Sources/OpenClaw/Resources/Info.plist"
if [ ! -f "$INFO_PLIST_SRC" ]; then
  echo "ERROR: Info.plist template missing at $INFO_PLIST_SRC" >&2
  exit 1
fi
cp "$INFO_PLIST_SRC" "$APP_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :OpenClawBuildTimestamp ${BUILD_TS}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :OpenClawGitCommit ${GIT_COMMIT}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :SUFeedURL ${SPARKLE_FEED_URL}" "$APP_ROOT/Contents/Info.plist" \
  || /usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${SPARKLE_FEED_URL}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${SPARKLE_PUBLIC_ED_KEY}" "$APP_ROOT/Contents/Info.plist" \
  || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_PUBLIC_ED_KEY}" "$APP_ROOT/Contents/Info.plist" || true
if /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks ${AUTO_CHECKS}" "$APP_ROOT/Contents/Info.plist"; then
  true
else
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool ${AUTO_CHECKS}" "$APP_ROOT/Contents/Info.plist" || true
fi

echo "🚚 Copying binary"
cp "$BIN_PRIMARY" "$APP_ROOT/Contents/MacOS/OpenClaw"
if [[ "${#BUILD_ARCHS[@]}" -gt 1 ]]; then
  BIN_INPUTS=()
  for arch in "${BUILD_ARCHS[@]}"; do
    BIN_INPUTS+=("$(bin_for_arch "$arch")")
  done
  /usr/bin/lipo -create "${BIN_INPUTS[@]}" -output "$APP_ROOT/Contents/MacOS/OpenClaw"
fi
chmod +x "$APP_ROOT/Contents/MacOS/OpenClaw"
# SwiftPM outputs ad-hoc signed binaries; strip the signature before install_name_tool to avoid warnings.
/usr/bin/codesign --remove-signature "$APP_ROOT/Contents/MacOS/OpenClaw" 2>/dev/null || true

SPARKLE_FRAMEWORK_PRIMARY="$(sparkle_framework_for_arch "$PRIMARY_ARCH")"
if [ -d "$SPARKLE_FRAMEWORK_PRIMARY" ]; then
  echo "✨ Embedding Sparkle.framework"
  cp -R "$SPARKLE_FRAMEWORK_PRIMARY" "$APP_ROOT/Contents/Frameworks/"
  if [[ "${#BUILD_ARCHS[@]}" -gt 1 ]]; then
    OTHER_FRAMEWORKS=()
    for arch in "${BUILD_ARCHS[@]}"; do
      if [[ "$arch" == "$PRIMARY_ARCH" ]]; then
        continue
      fi
      OTHER_FRAMEWORKS+=("$(sparkle_framework_for_arch "$arch")")
    done
    merge_framework_machos "$SPARKLE_FRAMEWORK_PRIMARY" "$APP_ROOT/Contents/Frameworks/Sparkle.framework" "${OTHER_FRAMEWORKS[@]}"
  fi
  chmod -R a+rX "$APP_ROOT/Contents/Frameworks/Sparkle.framework"
fi

echo "📦 Copying Swift 6.2 compatibility libraries"
SWIFT_COMPAT_LIB="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib"
if [ -f "$SWIFT_COMPAT_LIB" ]; then
  cp "$SWIFT_COMPAT_LIB" "$APP_ROOT/Contents/Frameworks/"
  chmod +x "$APP_ROOT/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
else
  echo "WARN: Swift compatibility library not found at $SWIFT_COMPAT_LIB (continuing)" >&2
fi

echo "🖼  Copying app icon"
cp "$ROOT_DIR/apps/macos/Sources/OpenClaw/Resources/OpenClaw.icns" "$APP_ROOT/Contents/Resources/OpenClaw.icns"

echo "📦 Copying device model resources"
rm -rf "$APP_ROOT/Contents/Resources/DeviceModels"
cp -R "$ROOT_DIR/apps/macos/Sources/OpenClaw/Resources/DeviceModels" "$APP_ROOT/Contents/Resources/DeviceModels"

echo "📦 Copying model catalog"
MODEL_CATALOG_SRC="$ROOT_DIR/node_modules/@mariozechner/pi-ai/dist/models.generated.js"
MODEL_CATALOG_DEST="$APP_ROOT/Contents/Resources/models.generated.js"
if [ -f "$MODEL_CATALOG_SRC" ]; then
  cp "$MODEL_CATALOG_SRC" "$MODEL_CATALOG_DEST"
else
  echo "WARN: model catalog missing at $MODEL_CATALOG_SRC (continuing)" >&2
fi

echo "📦 Copying OpenClawKit resources"
OPENCLAWKIT_BUNDLE="$(build_path_for_arch "$PRIMARY_ARCH")/$BUILD_CONFIG/OpenClawKit_OpenClawKit.bundle"
if [ -d "$OPENCLAWKIT_BUNDLE" ]; then
  rm -rf "$APP_ROOT/Contents/Resources/OpenClawKit_OpenClawKit.bundle"
  cp -R "$OPENCLAWKIT_BUNDLE" "$APP_ROOT/Contents/Resources/OpenClawKit_OpenClawKit.bundle"
else
  echo "WARN: OpenClawKit resource bundle not found at $OPENCLAWKIT_BUNDLE (continuing)" >&2
fi

echo "📦 Copying Textual resources"
TEXTUAL_BUNDLE_DIR="$(build_path_for_arch "$PRIMARY_ARCH")/$BUILD_CONFIG"
TEXTUAL_BUNDLE=""
for candidate in \
  "$TEXTUAL_BUNDLE_DIR/textual_Textual.bundle" \
  "$TEXTUAL_BUNDLE_DIR/Textual_Textual.bundle"
do
  if [ -d "$candidate" ]; then
    TEXTUAL_BUNDLE="$candidate"
    break
  fi
done
if [ -z "$TEXTUAL_BUNDLE" ]; then
  TEXTUAL_BUNDLE="$(find "$BUILD_ROOT" -type d \( -name "textual_Textual.bundle" -o -name "Textual_Textual.bundle" \) -print -quit)"
fi
if [ -n "$TEXTUAL_BUNDLE" ] && [ -d "$TEXTUAL_BUNDLE" ]; then
  rm -rf "$APP_ROOT/Contents/Resources/$(basename "$TEXTUAL_BUNDLE")"
  cp -R "$TEXTUAL_BUNDLE" "$APP_ROOT/Contents/Resources/"
else
  if [[ "${ALLOW_MISSING_TEXTUAL_BUNDLE:-0}" == "1" ]]; then
    echo "WARN: Textual resource bundle not found (continuing due to ALLOW_MISSING_TEXTUAL_BUNDLE=1)" >&2
  else
    echo "ERROR: Textual resource bundle not found. Set ALLOW_MISSING_TEXTUAL_BUNDLE=1 to bypass." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Bundle Node.js binary
# ---------------------------------------------------------------------------
NODE_VERSION="${BUNDLED_NODE_VERSION:-22.14.0}"
NODE_CACHE="$ROOT_DIR/.cache/node"
mkdir -p "$NODE_CACHE"

node_arch_name() {
  case "$1" in
    arm64) echo "arm64" ;;
    x86_64) echo "x64" ;;
    *) echo "$1" ;;
  esac
}

NODE_BINS=()
for arch in "${BUILD_ARCHS[@]}"; do
  NARCH="$(node_arch_name "$arch")"
  TARBALL="node-v${NODE_VERSION}-darwin-${NARCH}.tar.gz"
  TARBALL_PATH="$NODE_CACHE/$TARBALL"
  NODE_BIN="$NODE_CACHE/node-v${NODE_VERSION}-darwin-${NARCH}/bin/node"

  if [ ! -f "$NODE_BIN" ]; then
    if [ ! -f "$TARBALL_PATH" ]; then
      echo "📥 Downloading Node.js $NODE_VERSION ($NARCH)"
      curl -fSL "https://nodejs.org/dist/v${NODE_VERSION}/${TARBALL}" -o "$TARBALL_PATH"
    fi
    echo "📦 Extracting Node.js ($NARCH)"
    tar -xzf "$TARBALL_PATH" -C "$NODE_CACHE" "node-v${NODE_VERSION}-darwin-${NARCH}/bin/node"
  fi
  NODE_BINS+=("$NODE_BIN")
done

mkdir -p "$APP_ROOT/Contents/Resources/node/bin"
if [[ "${#NODE_BINS[@]}" -gt 1 ]]; then
  echo "🔗 Creating universal Node.js binary"
  /usr/bin/lipo -create "${NODE_BINS[@]}" -output "$APP_ROOT/Contents/Resources/node/bin/node"
else
  cp "${NODE_BINS[0]}" "$APP_ROOT/Contents/Resources/node/bin/node"
fi
chmod +x "$APP_ROOT/Contents/Resources/node/bin/node"
# Strip any existing ad-hoc signature (will be re-signed later with JIT entitlements).
/usr/bin/codesign --remove-signature "$APP_ROOT/Contents/Resources/node/bin/node" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Bundle Gateway (JS)
# ---------------------------------------------------------------------------
echo "📦 Copying gateway files"
GATEWAY_DEST="$APP_ROOT/Contents/Resources/gateway"
mkdir -p "$GATEWAY_DEST"

for item in openclaw.mjs package.json; do
  if [ -f "$ROOT_DIR/$item" ]; then
    cp "$ROOT_DIR/$item" "$GATEWAY_DEST/"
  fi
done

for dir in dist node_modules skills extensions docs; do
  if [ -d "$ROOT_DIR/$dir" ]; then
    cp -R "$ROOT_DIR/$dir" "$GATEWAY_DEST/"
  fi
done

# ---------------------------------------------------------------------------
# Prune node_modules for size
# ---------------------------------------------------------------------------
if [ -d "$GATEWAY_DEST/node_modules" ]; then
  echo "🧹 Pruning bundled node_modules"
  NM="$GATEWAY_DEST/node_modules"

  # Remove dev-only / type-only packages
  rm -rf "$NM/@types" "$NM/typescript" "$NM/vitest"

  # Remove non-darwin platform directories (native addons ship per-platform)
  find "$NM" -type d \( \
    -name "linux-*" -o -name "win32-*" -o -name "android-*" \
    -o -name "freebsd-*" -o -name "sunos-*" \
  \) -exec rm -rf {} + 2>/dev/null || true

  # Remove test/spec directories, TypeScript declarations, changelogs, READMEs
  find "$NM" -type d \( -name "test" -o -name "tests" -o -name "__tests__" -o -name "spec" -o -name ".github" \) -exec rm -rf {} + 2>/dev/null || true
  find "$NM" -type f \( \
    -name "*.d.ts" -o -name "*.d.ts.map" -o -name "*.d.mts" \
    -o -name "CHANGELOG.md" -o -name "CHANGELOG" -o -name "changelog.md" \
    -o -name "README.md" -o -name "readme.md" \
    -o -name "HISTORY.md" -o -name "LICENSE.md" -o -name "LICENSE" \
    -o -name ".npmignore" -o -name ".eslintrc*" -o -name ".prettierrc*" \
    -o -name "tsconfig.json" -o -name "tsconfig.*.json" \
    -o -name "*.ts" ! -name "*.d.ts" \
  \) -delete 2>/dev/null || true

  # Remove Playwright browser binaries (large, not needed at runtime)
  find "$NM" -type d -name ".local-browsers" -exec rm -rf {} + 2>/dev/null || true
  find "$NM" -path "*/playwright-core/browsers*" -exec rm -rf {} + 2>/dev/null || true
fi

echo "⏹  Stopping any running OpenClaw"
killall -q OpenClaw 2>/dev/null || true

echo "🔏 Signing bundle (auto-selects signing identity if SIGN_IDENTITY is unset)"
"$ROOT_DIR/scripts/codesign-mac-app.sh" "$APP_ROOT"

echo "✅ Bundle ready at $APP_ROOT"
