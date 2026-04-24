#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build-macos-app}"
APP_NAME="gtkterm"
APP_DIR="$SCRIPT_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_BIN="${APP_NAME}-bin"
PKG_DIR="$SCRIPT_DIR/dist"
ZIP_PATH="$PKG_DIR/${APP_NAME}-macos.zip"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./build-macos-app.sh [--keep-build]

Builds and bundles gtkterm as a macOS .app bundle at ./gtkterm.app,
then creates a zip artifact at ./dist/gtkterm-macos.zip.

Options:
  --keep-build   Reuse existing build directory instead of wiping it
EOF
  exit 0
fi

KEEP_BUILD=0
if [[ "${1:-}" == "--keep-build" ]]; then
  KEEP_BUILD=1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' not found" >&2
    exit 1
  fi
}

for cmd in meson ninja otool install_name_tool zip; do
  need_cmd "$cmd"
done

if ! pkg-config --exists gtk+-3.0 vte-2.91; then
  echo "Error: required GTK dependencies missing. Install with Homebrew first." >&2
  exit 1
fi

echo "==> Building gtkterm"
if [[ "$KEEP_BUILD" -eq 0 ]]; then
  meson setup --wipe "$BUILD_DIR" "$SCRIPT_DIR"
else
  if [[ ! -d "$BUILD_DIR" ]]; then
    meson setup "$BUILD_DIR" "$SCRIPT_DIR"
  fi
fi
ninja -C "$BUILD_DIR"

BIN_SRC="$BUILD_DIR/src/gtkterm"
if [[ ! -x "$BIN_SRC" ]]; then
  echo "Error: built binary not found at $BIN_SRC" >&2
  exit 1
fi

echo "==> Assembling app bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
cp "$BIN_SRC" "$MACOS_DIR/$APP_BIN"

SHARE_DIR="$RESOURCES_DIR/share"
PIXBUF_LOADERS_DIR="$RESOURCES_DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders"
BIN_HELPERS_DIR="$RESOURCES_DIR/bin"
mkdir -p "$SHARE_DIR" "$PIXBUF_LOADERS_DIR" "$BIN_HELPERS_DIR"

copy_dir_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -d "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -R "$src" "$dst"
  fi
}

# Bundle GTK runtime shared data used at startup.
for base in /opt/homebrew/share /usr/local/share; do
  copy_dir_if_exists "$base/icons/Adwaita" "$SHARE_DIR/icons/Adwaita"
  copy_dir_if_exists "$base/icons/hicolor" "$SHARE_DIR/icons/hicolor"
  copy_dir_if_exists "$base/glib-2.0/schemas" "$SHARE_DIR/glib-2.0/schemas"
done

if command -v glib-compile-schemas >/dev/null 2>&1 && [[ -d "$SHARE_DIR/glib-2.0/schemas" ]]; then
  glib-compile-schemas "$SHARE_DIR/glib-2.0/schemas" >/dev/null || true
fi

# Bundle gdk-pixbuf loader modules for image/icon decoding (PNG/SVG/etc).
PIXBUF_MOD_DIR="$(pkg-config --variable=gdk_pixbuf_moduledir gdk-pixbuf-2.0 2>/dev/null || true)"
if [[ -n "$PIXBUF_MOD_DIR" && -d "$PIXBUF_MOD_DIR" ]]; then
  cp "$PIXBUF_MOD_DIR"/*.so "$PIXBUF_LOADERS_DIR"/ 2>/dev/null || true
fi

# Bundle query utility to build loader cache at runtime with correct paths.
if command -v gdk-pixbuf-query-loaders >/dev/null 2>&1; then
  cp "$(command -v gdk-pixbuf-query-loaders)" "$BIN_HELPERS_DIR/gdk-pixbuf-query-loaders"
  chmod +x "$BIN_HELPERS_DIR/gdk-pixbuf-query-loaders"
fi

cat > "$MACOS_DIR/$APP_NAME" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES_DIR="$APP_ROOT/Resources"
LOADERS_DIR="$RES_DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders"
LOADERS_CACHE="$RES_DIR/gdk-pixbuf-loaders.cache"

export XDG_DATA_DIRS="$RES_DIR/share"
export DYLD_FALLBACK_LIBRARY_PATH="$APP_ROOT/Frameworks${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"

if [[ -d "$LOADERS_DIR" ]]; then
  export GDK_PIXBUF_MODULEDIR="$LOADERS_DIR"
  if [[ -x "$RES_DIR/bin/gdk-pixbuf-query-loaders" ]]; then
    "$RES_DIR/bin/gdk-pixbuf-query-loaders" "$LOADERS_DIR"/*.so > "$LOADERS_CACHE" 2>/dev/null || true
  fi
  if [[ -f "$LOADERS_CACHE" ]]; then
    export GDK_PIXBUF_MODULE_FILE="$LOADERS_CACHE"
  fi
fi

exec "$APP_ROOT/MacOS/gtkterm-bin" "$@"
EOF
chmod +x "$MACOS_DIR/$APP_NAME"

if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/data/gtkterm_256x256.png" ]]; then
  ICONSET_DIR="$SCRIPT_DIR/.gtkterm.iconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$SCRIPT_DIR/data/gtkterm_256x256.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$SCRIPT_DIR/data/gtkterm_256x256.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$SCRIPT_DIR/data/gtkterm_256x256.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$SCRIPT_DIR/data/gtkterm_256x256.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$SCRIPT_DIR/data/gtkterm_256x256.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$SCRIPT_DIR/data/gtkterm_256x256.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$SCRIPT_DIR/data/gtkterm_256x256.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$SCRIPT_DIR/data/gtkterm_256x256.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$SCRIPT_DIR/data/gtkterm_256x256.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/gtkterm.icns"
  rm -rf "$ICONSET_DIR"
  ICON_NAME="gtkterm"
else
  ICON_NAME=""
fi

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>gtkterm</string>
  <key>CFBundleDisplayName</key>
  <string>gtkterm</string>
  <key>CFBundleExecutable</key>
  <string>gtkterm</string>
  <key>CFBundleIdentifier</key>
  <string>org.gtkterm.app</string>
  <key>CFBundleVersion</key>
  <string>1.3.1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.3.1</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>LSMultipleInstancesProhibited</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
EOF

if [[ -n "$ICON_NAME" ]]; then
  cat >> "$CONTENTS_DIR/Info.plist" <<EOF
  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>
EOF
fi

cat >> "$CONTENTS_DIR/Info.plist" <<'EOF'
</dict>
</plist>
EOF

bundle_binary() {
  local target="$1"
  local dep
  local target_dir
  target_dir="$(cd "$(dirname "$target")" && pwd)"

  find_dep_by_basename() {
    local base="$1"
    local cand

    for cand in \
      "/opt/homebrew/lib/$base" \
      "/usr/local/lib/$base" \
      /opt/homebrew/opt/*/lib/"$base" \
      /usr/local/opt/*/lib/"$base" \
      /opt/homebrew/Cellar/*/*/lib/"$base" \
      /usr/local/Cellar/*/*/lib/"$base"
    do
      if [[ -f "$cand" ]]; then
        printf '%s\n' "$cand"
        return 0
      fi
    done

    return 1
  }

  while IFS= read -r dep; do
    local orig_dep
    orig_dep="$dep"
    [[ -z "$dep" ]] && continue

    # Skip system frameworks/libs that should not be bundled.
    if [[ "$dep" == /System/* || "$dep" == /usr/lib/* ]]; then
      continue
    fi

    # Resolve loader-relative paths against the current target.
    if [[ "$dep" == @loader_path/* ]]; then
      dep="$target_dir/${dep#@loader_path/}"
    elif [[ "$dep" == @executable_path/* ]]; then
      dep="$MACOS_DIR/${dep#@executable_path/}"
    fi

    # Resolve @rpath entries against common Homebrew prefixes.
    if [[ "$dep" == @rpath/* ]]; then
      local rp="${dep#@rpath/}"
      if [[ -f "/opt/homebrew/lib/$rp" ]]; then
        dep="/opt/homebrew/lib/$rp"
      elif [[ -f "/usr/local/lib/$rp" ]]; then
        dep="/usr/local/lib/$rp"
      else
        # Keep unresolved for basename fallback below (e.g. Cellar/opt libs).
        dep="$rp"
      fi
    fi

    local base
    base="$(basename "$dep")"

    if [[ ! -f "$dep" ]]; then
      local resolved
      if resolved="$(find_dep_by_basename "$base")"; then
        dep="$resolved"
      else
        continue
      fi
    fi

    local dest="$FRAMEWORKS_DIR/$base"

    if [[ ! -f "$dest" ]]; then
      cp "$dep" "$dest"
      chmod u+w "$dest"
      install_name_tool -id "@executable_path/../Frameworks/$base" "$dest"
      bundle_binary "$dest"
    fi

    install_name_tool -change "$orig_dep" "@executable_path/../Frameworks/$base" "$target" || true
  done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
}

echo "==> Bundling dynamic libraries"
chmod u+w "$MACOS_DIR/$APP_BIN"
bundle_binary "$MACOS_DIR/$APP_BIN"

if [[ -x "$BIN_HELPERS_DIR/gdk-pixbuf-query-loaders" ]]; then
  bundle_binary "$BIN_HELPERS_DIR/gdk-pixbuf-query-loaders"
fi

if compgen -G "$PIXBUF_LOADERS_DIR/*.so" >/dev/null; then
  for so in "$PIXBUF_LOADERS_DIR"/*.so; do
    bundle_binary "$so"
  done
fi

if command -v codesign >/dev/null 2>&1; then
  echo "==> Applying ad-hoc code signatures"
  find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' f; do
    codesign --force --sign - "$f" >/dev/null
  done
  find "$PIXBUF_LOADERS_DIR" -type f -name '*.so' -print0 | while IFS= read -r -d '' f; do
    codesign --force --sign - "$f" >/dev/null
  done
  if [[ -x "$BIN_HELPERS_DIR/gdk-pixbuf-query-loaders" ]]; then
    codesign --force --sign - "$BIN_HELPERS_DIR/gdk-pixbuf-query-loaders" >/dev/null
  fi
  codesign --force --sign - "$MACOS_DIR/$APP_BIN" >/dev/null
  codesign --force --sign - --deep "$APP_DIR" >/dev/null
fi

mkdir -p "$PKG_DIR"
rm -f "$ZIP_PATH"

echo "==> Creating distributable zip"
(
  cd "$SCRIPT_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_PATH"
)

echo "Done"
echo "App: $APP_DIR"
echo "Zip: $ZIP_PATH"
echo "Launch a new instance with: open -n '$APP_DIR'"
