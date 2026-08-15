#!/bin/sh
set -eu

usage() {
    echo "usage: $0 RELEASE_ZIP RELEASE_URL VERSION BUILD CHANNEL" >&2
    exit 64
}

[ "$#" -eq 5 ] || usage
release_zip=$1
release_url=$2
expected_version=$3
expected_build=$4
channel=$5

[ -f "$release_zip" ] || { echo "release ZIP not found" >&2; exit 66; }
case "$release_url" in
    https://*) ;;
    *) echo "release URL must use HTTPS" >&2; exit 64 ;;
esac
case "$release_url" in
    *\?*|*\#*) echo "release URL must not contain a query or fragment" >&2; exit 64 ;;
esac
case "$channel" in
    development) channel_arguments="--channel development" ;;
    stable) channel_arguments="" ;;
    *) echo "channel must be development or stable" >&2; exit 64 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
derived_data_root=${TARGET_DERIVED_DATA_ROOT:-"$HOME/Library/Developer/Xcode/DerivedData"}
if [ -n "${SPARKLE_TOOLS_DIR:-}" ]; then
    sparkle_tools_dir=$SPARKLE_TOOLS_DIR
else
    sparkle_tools_dir=$(find "$derived_data_root" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d -print -quit)
fi
[ -n "$sparkle_tools_dir" ] || { echo "Sparkle tools not found; resolve Swift packages first" >&2; exit 69; }
sign_update="$sparkle_tools_dir/sign_update"
generate_appcast="$sparkle_tools_dir/generate_appcast"
[ -x "$sign_update" ] && [ -x "$generate_appcast" ] || { echo "Sparkle tools are not executable" >&2; exit 69; }

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/target-appcast.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
archive_name=$(basename -- "$release_zip")
case "$release_url" in
    */"$archive_name") ;;
    *) echo "release URL filename must match the ZIP" >&2; exit 64 ;;
esac
download_prefix=${release_url%/"$archive_name"}
cp "$release_zip" "$work_dir/$archive_name"
cp "$repo_root/Updates/appcast.xml" "$work_dir/appcast.xml"

extract_dir="$work_dir/extracted"
mkdir "$extract_dir"
ditto -x -k "$release_zip" "$extract_dir"
app_plist=$(find "$extract_dir" -path '*.app/Contents/Info.plist' -type f -print -quit)
[ -n "$app_plist" ] || { echo "release ZIP does not contain an app bundle" >&2; exit 65; }
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_plist")
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_plist")
[ "$actual_version" = "$expected_version" ] || { echo "release version does not match" >&2; exit 65; }
[ "$actual_build" = "$expected_build" ] || { echo "release build does not match" >&2; exit 65; }

"$sign_update" "$release_zip" >/dev/null
# shellcheck disable=SC2086
"$generate_appcast" --download-url-prefix "$download_prefix" --versions "$expected_build" --maximum-versions 0 $channel_arguments "$work_dir"
"$sign_update" --verify "$work_dir/appcast.xml"
cp "$work_dir/appcast.xml" "$repo_root/Updates/appcast.xml"
