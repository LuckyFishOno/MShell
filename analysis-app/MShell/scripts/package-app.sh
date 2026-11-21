#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_path=${1:-/tmp/mshell-build}
output_dir=${2:-"$project_dir/../build"}
cd "$project_dir"
# Release builds draw and parse terminal output several times faster than debug builds.
swift build -c release --build-path "$build_path" --product CarveApp
bin_dir=$(swift build -c release --build-path "$build_path" --show-bin-path)
app="$output_dir/MShell.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
cp "$bin_dir/CarveApp" "$app/Contents/MacOS/MShell"
ln -sf ../../MacOS/MShell "$app/Contents/Resources/bin/mshell"
for resource in "$bin_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.mshell.desktop</string>
<key>CFBundleName</key><string>MShell</string>
<key>CFBundleDisplayName</key><string>MShell</string>
<key>CFBundleExecutable</key><string>MShell</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.10.0</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf 'Built local application: %s\n' "$app"
