#!/usr/bin/env bash

set -euo pipefail

dry_run=false
script_directory="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=install_local_app_transaction.sh
source "$script_directory/install_local_app_transaction.sh"

usage() {
    printf 'Usage: %s [--dry-run]\n' "${0##*/}"
}

unregister_app() {
    local app="$1"
    if [ "$dry_run" = true ]; then
        printf 'would unregister LaunchServices path: %s\n' "$app"
        return
    fi
    "$installer_lsregister" -u "$app" >/dev/null 2>&1 || true
}

archive_app() {
    local app="$1"
    local timestamp archive_directory destination suffix
    assert_target_app "$app"
    validate_test_mode_paths || return 1
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    archive_directory="$archive_root/$timestamp"
    destination="$archive_directory/Target.app"
    suffix=1
    while [ -e "$destination" ] || [ -L "$destination" ]; do
        destination="$archive_directory/Target-$suffix.app"
        suffix=$((suffix + 1))
    done
    if [ "$dry_run" = true ]; then
        printf 'would move old app to archive: %s -> %s\n' "$app" "$destination"
        return
    fi
    mkdir -p "$archive_directory"
    mv -- "$app" "$destination"
    printf 'archived old app: %s -> %s\n' "$app" "$destination"
}

collect_old_apps() {
    local root app
    local roots
    validate_test_mode_paths || return 1
    if [ "$installer_test_mode" = true ]; then
        roots=("$test_home_root/Applications" "$test_home_root/Desktop" "$test_home_root/Downloads" "$derived_data_root")
    else
        roots=("$HOME/Applications" "$HOME/Desktop" "$HOME/Downloads" "$derived_data_root")
    fi
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
    validate_test_mode_paths || return 1
    while IFS= read -r app; do
        [ "$app" = "$canonical_app" ] && continue
        [ -n "$app" ] || continue
        unregister_app "$app"
    done < <(
        "$installer_lsregister" -dump | awk '
            /^$/ { path = ""; next }
            /^path:[[:space:]]*/ { sub(/^path:[[:space:]]*/, ""); path = $0; sub(/[[:space:]]+\(0x[[:xdigit:]]+\)$/, "", path); next }
            /^identifier:[[:space:]]*com\.jason312928\.Target$/ { if (path != "") print path; path = "" }
        ' | sort -u
    )
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; installer_error "unknown argument: $1"; exit 1 ;;
    esac
    shift
done

configure_installer_paths
command -v git >/dev/null 2>&1 || { installer_error 'git is required'; exit 1; }
if [ "$installer_test_mode" = false ]; then
    command -v "$installer_xcodebuild" >/dev/null 2>&1 || { installer_error 'xcodebuild is required'; exit 1; }
    command -v "$installer_ditto" >/dev/null 2>&1 || { installer_error 'ditto is required'; exit 1; }
    command -v "$installer_mdimport" >/dev/null 2>&1 || { installer_error 'mdimport is required'; exit 1; }
    [ -x "$installer_lsregister" ] || { installer_error 'LaunchServices lsregister is unavailable'; exit 1; }
else
    validate_test_mode_paths || exit 1
fi
trap cleanup_failed_install_transaction EXIT

repo_root="$(validate_target_repository)" || exit 1
cd -- "$repo_root"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "$installer_xcodebuild" -list -project 'Target.xcodeproj' | awk '
    /^    Schemes:$/ { in_schemes = 1; next }
    in_schemes && /^        Target$/ { found = 1 }
    END { exit found ? 0 : 1 }
' || { installer_error 'Target scheme is missing'; exit 1; }

commit="$(git rev-parse HEAD)"
build_number="$(git rev-list --count HEAD)"
[ "$build_number" -gt 0 ] || { installer_error 'invalid Git commit count'; exit 1; }

printf 'repository: %s\ncommit: %s\nderived data: %s\ncanonical path: %s\n' "$repo_root" "$commit" "$derived_data_path" "$canonical_app"

if [ "$dry_run" = true ]; then
    printf 'would build unsigned Release Target with isolated .noindex DerivedData\n'
    collect_old_apps
    collect_stale_launchservices_paths
    printf 'would locally import Spotlight metadata: %s\n' "$canonical_app"
    printf 'would register only canonical LaunchServices path: %s\n' "$canonical_app"
    exit 0
fi

recover_interrupted_installation
validate_test_mode_paths || exit 1
mkdir -p "$derived_data_path"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "$installer_xcodebuild" \
    -project 'Target.xcodeproj' \
    -scheme 'Target' \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    TARGET_SOURCE_COMMIT="$commit" \
    TARGET_SOURCE_COMMIT_SHORT="${commit:0:12}" \
    TARGET_BUILD_CHANNEL='Local' \
    CONFIGURATION_BUILD_DIR="$derived_data_path/Build/Products/Release" \
    CURRENT_PROJECT_VERSION="$build_number" \
    build

built_app="$derived_data_path/Build/Products/Release/Target.app"
verify_built_app "$built_app" "$commit" "$build_number"
install_canonical_app "$built_app" "$commit" "$build_number"
collect_old_apps
collect_stale_launchservices_paths
"$installer_lsregister" -f "$canonical_app" >/dev/null
"$installer_mdimport" "$canonical_app"
verify_built_app "$canonical_app" "$commit" "$build_number"
printf 'installed canonical Target.app at %s\n' "$canonical_app"
