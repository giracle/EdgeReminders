#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
project_root="$PWD"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
build_path="$project_root/build/universal"
dist_path="$project_root/dist"
name="EdgeReminders-$version-macOS-universal.dmg"
identity="${DEVELOPER_ID_APPLICATION:-}"
notary_profile="${NOTARYTOOL_PROFILE:-}"

if [[ -n "$identity" && -z "$notary_profile" || -z "$identity" && -n "$notary_profile" ]]; then
    echo 'Set both DEVELOPER_ID_APPLICATION and NOTARYTOOL_PROFILE for Developer ID distribution.' >&2
    exit 1
fi

xcodebuild -project EdgeReminders.xcodeproj -scheme EdgeReminders \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$build_path" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES -quiet build

mkdir -p "$dist_path"
work_dir="$(mktemp -d "$dist_path/.package.XXXXXX")"
trap 'find "$work_dir" -depth -delete' EXIT
mkdir "$work_dir/volume"
app="$work_dir/volume/EdgeReminders.app"
ditto "$build_path/Build/Products/Release/EdgeReminders.app" "$app"
cp LICENSE "$work_dir/volume/LICENSE.txt"
ln -s /Applications "$work_dir/volume/Applications"

xcrun lipo "$app/Contents/MacOS/EdgeReminders" -verify_arch arm64 x86_64
test -s "$app/Contents/Resources/default.metallib"
if [[ -n "$identity" ]]; then
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"

image="$work_dir/$name"
hdiutil create -quiet -volname 'EdgeReminders' -srcfolder "$work_dir/volume" -format UDZO "$image"
if [[ -n "$identity" ]]; then
    codesign --timestamp --sign "$identity" "$image"
    xcrun notarytool submit "$image" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
fi
hdiutil verify -quiet "$image"
mv -f "$image" "$dist_path/$name"
(
    cd "$dist_path"
    shasum -a 256 "$name" >"$name.sha256"
    shasum -a 256 -c "$name.sha256"
)
