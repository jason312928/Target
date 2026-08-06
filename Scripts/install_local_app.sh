#!/usr/bin/env bash

set -euo pipefail

readonly expected_bundle_id='com.jason312928.Target'
readonly canonical_app='/Applications/Target.app'
readonly derived_data_root="$HOME/Library/Developer/Xcode/DerivedData"
readonly derived_data_path="$derived_data_root/Target-Canonical.noindex"
readonly archive_root="$HOME/Library/Application Support/Target/Archived Builds.noindex"
readonly lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

dry_run=false
install_staging_app=''

usage() {
    printf 'Usage: %s [--dry-run]\n' "${0##*/}"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

canonical_directory() {
    [ -d "$1" ] || return 1
    (cd -P -- "$1" && pwd -P)
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

is_target_bundle() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(plist_value "$1" CFBundleIdentifier || true)" = "$expected_bundle_id" ]
}

is_target_app() {
    [ "$(basename -- "$1")" = 'Target.app' ] && is_target_bundle "$1"
}

assert_target_app() {
    is_target_app "$1" || fail "expected a regular $expected_bundle_id Target.app bundle: $1"
}

safe_remove_app() {
    local app="$1"
    case "$app" in
        "$derived_data_root"/Target*/Build/Products/*/Target.app|/Applications/.Target.app.installing-*|/Applications/.Target.app.replaced-*) ;;
        *) fail "refusing to remove unapproved path: $app" ;;
    esac
    is_target_bundle "$app" || fail "expected a regular $expected_bundle_id app bundle: $app"
    if "$dry_run"; then
        printf 'would remove build product: %s\n' "$app"
    else
        rm -rf "$app"
        printf 'removed build product: %s\n' "$app"
    fi
}

cleanup_orphaned_staging() {
    local app
    while IFS= read -r app; do
        [ -L "$app" ] && fail "refusing to remove symlink staging path: $app"
        is_target_bundle "$app" || fail "refusing to remove unrecognized staging path: $app"
        safe_remove_app "$app"
    done < <(find '/Applications' -maxdepth 1 -type d -name '.Target.app.installing-*' -prune -print 2>/dev/null)
}

cleanup_failed_staging() {
    local exit_code=$?
    trap - EXIT
    if [ -n "$install_staging_app" ] && is_target_bundle "$install_staging_app"; then
        rm -rf "$install_staging_app"
    fi
    exit "$exit_code"
}

unregister_app() {
    local app="$1"
    if "$dry_run"; then
        printf 'would unregister LaunchServices path: %s\n' "$app"
        return
    fi
    "$lsregister" -u "$app" >/dev/null 2>&1 || true
}

archive_app() {
    local app="$1"
    local timestamp archive_directory destination stem suffix
    assert_target_app "$app"
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    archive_directory="$archive_root/$timestamp"
    destination="$archive_directory/Target.app"
    suffix=1
    while [ -e "$destination" ] || [ -L "$destination" ]; do
        destination="$archive_directory/Target-$suffix.app"
        suffix=$((suffix + 1))
    done
    if "$dry_run"; then
        printf 'would move old app to archive: %s -> %s\n' "$app" "$destination"
        return
    fi
    mkdir -p "$archive_directory"
    mv "$app" "$destination"
    printf 'archived old app: %s -> %s\n' "$app" "$destination"
}

collect_old_apps() {
    local root app
    local roots=("$HOME/Applications" "$HOME/Desktop" "$HOME/Downloads" "$derived_data_root")
    for root in "${roots[@]}"; do
        [ -d "$root" ] || continue
        while IFS= read -r app; do
            [ "$app" = "$canonical_app" ] && continue
            [ -L "$app" ] && { printf 'skipping symlink app candidate: %s\n' "$app" >&2; continue; }
            is_target_app "$app" || continue
            unregister_app "$app"
            case "$app" in
                "$derived_data_root"/Target*/Build/Products/*/Target.app) safe_remove_app "$app" ;;
                "$derived_data_root"/*) printf 'skipping non-Target DerivedData app: %s\n' "$app" >&2 ;;
                *) archive_app "$app" ;;
            esac
        done < <(find "$root" -type d -name 'Target.app' -prune -print 2>/dev/null)
    done
}

collect_stale_launchservices_paths() {
    local app
    while IFS= read -r app; do
        [ "$app" = "$canonical_app" ] && continue
        [ -n "$app" ] || continue
        unregister_app "$app"
    done < <(
        "$lsregister" -dump | awk '
            /^$/ { path = ""; next }
            /^path:[[:space:]]*/ { sub(/^path:[[:space:]]*/, ""); path = $0; sub(/[[:space:]]+\(0x[[:xdigit:]]+\)$/, "", path); next }
            /^identifier:[[:space:]]*com\.jason312928\.Target$/ { if (path != "") print path; path = "" }
        ' | sort -u
    )
}

verify_built_app() {
    local app="$1" commit="$2" build_number="$3"
    is_target_bundle "$app" || fail "expected a regular $expected_bundle_id app bundle: $app"
    [ -f "$app/Contents/MacOS/Target" ] || fail "missing main executable in $app"
    [ -f "$app/Contents/Resources/Assets.car" ] || fail "missing compiled asset catalog in $app"
    [ ! -e "$app/Contents/PlugIns/TargetTests.xctest" ] || fail "test bundle was mixed into $app"
    [ "$(plist_value "$app" CFBundleVersion)" = "$build_number" ] || fail "unexpected build number in $app"
    [ "$(plist_value "$app" TargetSourceCommit)" = "$commit" ] || fail "unexpected source commit in $app"
    [ "$(plist_value "$app" TargetSourceCommitShort)" = "${commit:0:12}" ] || fail "unexpected short source commit in $app"
    [ "$(plist_value "$app" TargetBuildChannel)" = 'Local' ] || fail "unexpected build channel in $app"
}

install_canonical_app() {
    local built_app="$1" commit="$2" build_number="$3"
    local staging_app replaced_app applications_directory
    applications_directory="$(canonical_directory '/Applications')" || fail 'cannot resolve /Applications'
    [ "$applications_directory" = '/Applications' ] || fail 'unexpected /Applications canonical path'
    [ -w "$applications_directory" ] || fail '/Applications is not safely writable by the current user'
    [ ! -L "$canonical_app" ] || fail 'refusing to replace symlink canonical path'
    if [ -e "$canonical_app" ]; then
        assert_target_app "$canonical_app"
        [ ! -d "$canonical_app/Contents/Application Support" ] || fail 'canonical app contains a user data directory'
        [ ! -d "$canonical_app/Contents/Preferences" ] || fail 'canonical app contains a user data directory'
    fi
    staging_app="/Applications/.Target.app.installing-$$"
    replaced_app="/Applications/.Target.app.replaced-$$"
    [ ! -e "$staging_app" ] && [ ! -L "$staging_app" ] || fail "staging path already exists: $staging_app"
    [ ! -e "$replaced_app" ] && [ ! -L "$replaced_app" ] || fail "replacement path already exists: $replaced_app"
    if "$dry_run"; then
        printf 'would copy validated build: %s -> %s\n' "$built_app" "$staging_app"
        printf 'would rename canonical app through: %s\n' "$replaced_app"
        printf 'would install canonical app: %s\n' "$canonical_app"
        return
    fi
    install_staging_app="$staging_app"
    ditto "$built_app" "$staging_app"
    verify_built_app "$staging_app" "$commit" "$build_number"
    if [ -e "$canonical_app" ]; then
        mv "$canonical_app" "$replaced_app"
    fi
    mv "$staging_app" "$canonical_app"
    install_staging_app=''
    verify_built_app "$canonical_app" "$commit" "$build_number"
    if [ -d "$replaced_app" ]; then
        safe_remove_app "$replaced_app"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fail "unknown argument: $1" ;;
    esac
    shift
done

command -v git >/dev/null 2>&1 || fail 'git is required'
command -v xcodebuild >/dev/null 2>&1 || fail 'xcodebuild is required'
command -v ditto >/dev/null 2>&1 || fail 'ditto is required'
[ -x "$lsregister" ] || fail 'LaunchServices lsregister is unavailable'
trap cleanup_failed_staging EXIT

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail 'not inside a Git repository'
repo_root="$(canonical_directory "$repo_root")" || fail 'cannot resolve repository root'
cd -- "$repo_root"
[ -f 'Target.xcodeproj/project.pbxproj' ] || fail 'Target.xcodeproj is missing'
[ -d 'Target' ] || fail 'Target source directory is missing'
[ "$(git remote get-url origin 2>/dev/null || true)" = 'https://github.com/jason312928/Target.git' ] || fail 'not the Target public repository'
[ -z "$(git status --porcelain)" ] || fail 'working tree is not clean'
git rev-parse --verify HEAD >/dev/null 2>&1 || fail 'cannot resolve current commit'
[ "$(git branch --show-current)" = 'main' ] || fail 'main branch is required'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -list -project 'Target.xcodeproj' | awk '
    /^    Schemes:$/ { in_schemes = 1; next }
    in_schemes && /^        Target$/ { found = 1 }
    END { exit found ? 0 : 1 }
' || fail 'Target scheme is missing'

commit="$(git rev-parse HEAD)"
build_number="$(git rev-list --count HEAD)"
[ "$build_number" -gt 0 ] || fail 'invalid Git commit count'

printf 'repository: %s\ncommit: %s\nderived data: %s\ncanonical path: %s\n' "$repo_root" "$commit" "$derived_data_path" "$canonical_app"

if "$dry_run"; then
    printf 'would build unsigned Debug Target with isolated .noindex DerivedData\n'
    collect_old_apps
    collect_stale_launchservices_paths
    printf 'would locally import Spotlight metadata: %s\n' "$canonical_app"
    printf 'would register only canonical LaunchServices path: %s\n' "$canonical_app"
    exit 0
fi

cleanup_orphaned_staging
mkdir -p "$derived_data_path"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project 'Target.xcodeproj' \
    -scheme 'Target' \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    TARGET_SOURCE_COMMIT="$commit" \
    TARGET_SOURCE_COMMIT_SHORT="${commit:0:12}" \
    TARGET_BUILD_CHANNEL='Local' \
    CURRENT_PROJECT_VERSION="$build_number" \
    build

built_app="$derived_data_path/Build/Products/Debug/Target.app"
verify_built_app "$built_app" "$commit" "$build_number"
install_canonical_app "$built_app" "$commit" "$build_number"
collect_old_apps
collect_stale_launchservices_paths
"$lsregister" -f "$canonical_app" >/dev/null
mdimport "$canonical_app"
verify_built_app "$canonical_app" "$commit" "$build_number"
printf 'installed canonical Target.app at %s\n' "$canonical_app"
