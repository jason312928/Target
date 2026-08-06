#!/usr/bin/env bash

# This file is sourced by the canonical installer and its isolated shell tests.

expected_bundle_id='com.jason312928.Target'
installer_test_mode=false
installer_test_root=''
applications_directory='/Applications'
canonical_app='/Applications/Target.app'
derived_data_root="$HOME/Library/Developer/Xcode/DerivedData"
derived_data_path="$derived_data_root/Target-Canonical.noindex"
archive_root="$HOME/Library/Application Support/Target/Archived Builds.noindex"
lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
test_home_root=''
install_staging_app=''
install_replaced_app=''
install_transaction_active=false

installer_error() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

canonical_directory() {
    [ -d "$1" ] || return 1
    (cd -P -- "$1" && pwd -P)
}

configure_installer_paths() {
    if [ "${TARGET_INSTALLER_TEST_MODE:-}" = '1' ]; then
        installer_test_mode=true
        installer_test_root="${TARGET_INSTALLER_TEST_ROOT:-}"
        [ -n "$installer_test_root" ] || installer_error 'test mode requires TARGET_INSTALLER_TEST_ROOT'
        installer_test_root="$(canonical_directory "$installer_test_root")" || installer_error 'cannot resolve test root'
        [[ "${installer_test_root##*/}" =~ ^TargetInstallerTests\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || installer_error 'test root must be a UUID temporary directory'
        case "$installer_test_root" in
            /|/Applications|/Applications/*) installer_error 'test root must not contain the real Applications directory' ;;
        esac
        applications_directory="$installer_test_root/Applications"
        [ -d "$applications_directory" ] || installer_error 'test root Applications directory is missing'
        canonical_app="$applications_directory/Target.app"
        derived_data_root="$installer_test_root/DerivedData"
        derived_data_path="$derived_data_root/Target-Canonical.noindex"
        archive_root="$installer_test_root/Archived Builds.noindex"
        test_home_root="$installer_test_root/Home"
        lsregister="$installer_test_root/tools/lsregister"
        [ -x "$lsregister" ] || installer_error 'test mode requires an isolated lsregister fixture'
        return
    fi

    [ -z "${TARGET_INSTALLER_TEST_ROOT:-}" ] || installer_error 'TARGET_INSTALLER_TEST_ROOT requires TARGET_INSTALLER_TEST_MODE=1'
    applications_directory='/Applications'
    canonical_app='/Applications/Target.app'
    derived_data_root="$HOME/Library/Developer/Xcode/DerivedData"
    derived_data_path="$derived_data_root/Target-Canonical.noindex"
    archive_root="$HOME/Library/Application Support/Target/Archived Builds.noindex"
    lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
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
    is_target_app "$1" || installer_error "expected a regular $expected_bundle_id Target.app bundle: $1"
}

test_failpoint() {
    [ "$installer_test_mode" = true ] && [ "${TARGET_INSTALLER_TEST_FAILPOINT:-}" = "$1" ]
}

safe_remove_app() {
    local app="$1" parent_directory
    case "$app" in
        "$derived_data_root"/Target*/Build/Products/*/Target.app) ;;
        "$applications_directory"/.Target.app.installing-*|"$applications_directory"/.Target.app.replaced-*)
            parent_directory="$(dirname -- "$app")"
            [ "$parent_directory" = "$applications_directory" ] || {
                installer_error "refusing to remove nested transaction path: $app"
                return 1
            }
            ;;
        *) installer_error "refusing to remove unapproved path: $app"; return 1 ;;
    esac
    is_target_bundle "$app" || { installer_error "expected a regular $expected_bundle_id app bundle: $app"; return 1; }
    if [ "${dry_run:-false}" = true ]; then
        printf 'would remove app: %s\n' "$app"
        return
    fi
    if test_failpoint 'remove_replaced' && [[ "$app" == "$applications_directory"/.Target.app.replaced-* ]]; then
        printf 'error: injected replacement cleanup failure: %s\n' "$app" >&2
        return 1
    fi
    rm -rf -- "$app" && [ ! -e "$app" ] && [ ! -L "$app" ] || {
        installer_error "could not remove validated app: $app"
        return 1
    }
    printf 'removed app: %s\n' "$app"
}

transaction_candidates=()

find_transaction_candidates() {
    local pattern="$1" app
    transaction_candidates=()
    while IFS= read -r app; do
        transaction_candidates+=("$app")
    done < <(find "$applications_directory" -mindepth 1 -maxdepth 1 -name "$pattern" -print 2>/dev/null | sort)
}

validate_transaction_candidates() {
    local kind="$1" app
    for app in "${transaction_candidates[@]:-}"; do
        [ -n "$app" ] || continue
        [ ! -L "$app" ] || { installer_error "refusing $kind recovery for symlink path: $app"; return 1; }
        is_target_bundle "$app" || { installer_error "refusing $kind recovery for unrecognized path: $app"; return 1; }
    done
}

cleanup_orphaned_staging() {
    local app
    find_transaction_candidates '.Target.app.installing-*'
    validate_transaction_candidates 'staging' || return 1
    for app in "${transaction_candidates[@]:-}"; do
        [ -n "$app" ] || continue
        safe_remove_app "$app" || return 1
    done
}

recover_orphaned_replacements() {
    local app
    find_transaction_candidates '.Target.app.replaced-*'
    validate_transaction_candidates 'replacement' || return 1
    [ "${#transaction_candidates[@]}" -le 1 ] || {
        installer_error 'multiple validated replacement bundles make recovery ambiguous; preserving all evidence'
        return 1
    }
    [ ! -L "$canonical_app" ] || { installer_error 'refusing recovery for symlink canonical path'; return 1; }
    if [ -e "$canonical_app" ]; then
        assert_target_app "$canonical_app" || return 1
        if [ "${#transaction_candidates[@]}" -eq 1 ]; then
            safe_remove_app "${transaction_candidates[0]}" || {
                installer_error 'could not clean the validated replacement bundle; canonical app remains installed'
                return 1
            }
        fi
        return
    fi
    [ "${#transaction_candidates[@]}" -eq 0 ] && return
    app="${transaction_candidates[0]}"
    mv -- "$app" "$canonical_app" || {
        installer_error "could not restore replacement bundle to canonical path: $app"
        return 1
    }
    assert_target_app "$canonical_app" || {
        installer_error 'restored canonical bundle did not pass ordinary Target App validation'
        return 1
    }
    printf 'restored canonical app: %s\n' "$canonical_app"
}

recover_interrupted_installation() {
    cleanup_orphaned_staging || return 1
    recover_orphaned_replacements
}

verify_built_app() {
    local app="$1" commit="$2" build_number="$3"
    if test_failpoint 'verify_canonical' && [ "$app" = "$canonical_app" ]; then
        printf 'error: injected canonical verification failure: %s\n' "$app" >&2
        return 1
    fi
    is_target_bundle "$app" || { installer_error "expected a regular $expected_bundle_id app bundle: $app"; return 1; }
    [ -f "$app/Contents/MacOS/Target" ] || { installer_error "missing main executable in $app"; return 1; }
    [ -f "$app/Contents/Resources/Assets.car" ] || { installer_error "missing compiled asset catalog in $app"; return 1; }
    [ ! -e "$app/Contents/PlugIns/TargetTests.xctest" ] || { installer_error "test bundle was mixed into $app"; return 1; }
    [ "$(plist_value "$app" CFBundleVersion)" = "$build_number" ] || { installer_error "unexpected build number in $app"; return 1; }
    [ "$(plist_value "$app" TargetSourceCommit)" = "$commit" ] || { installer_error "unexpected source commit in $app"; return 1; }
    [ "$(plist_value "$app" TargetSourceCommitShort)" = "${commit:0:12}" ] || { installer_error "unexpected short source commit in $app"; return 1; }
    [ "$(plist_value "$app" TargetBuildChannel)" = 'Local' ] || { installer_error "unexpected build channel in $app"; return 1; }
}

remove_controlled_staging() {
    local app="$1"
    [ -e "$app" ] || [ -L "$app" ] || return
    [ ! -L "$app" ] || { installer_error "preserving symlink staging evidence: $app"; return 1; }
    is_target_bundle "$app" || { installer_error "preserving unrecognized staging evidence: $app"; return 1; }
    safe_remove_app "$app"
}

restore_replaced_app() {
    local replaced_app="$1"
    [ -e "$replaced_app" ] || [ -L "$replaced_app" ] || return
    [ ! -L "$replaced_app" ] || { installer_error "cannot restore symlink replacement evidence: $replaced_app"; return 1; }
    is_target_bundle "$replaced_app" || { installer_error "cannot restore unrecognized replacement evidence: $replaced_app"; return 1; }
    [ ! -e "$canonical_app" ] || { installer_error "cannot restore replacement while canonical path is occupied"; return 1; }
    mv -- "$replaced_app" "$canonical_app" || {
        installer_error "could not restore old canonical app from $replaced_app"
        return 1
    }
    assert_target_app "$canonical_app" || {
        installer_error 'restored canonical bundle did not pass ordinary Target App validation'
        return 1
    }
    printf 'restored old canonical app: %s\n' "$canonical_app"
}

rollback_install_transaction() {
    local rollback_failed=false
    if [ -n "$install_staging_app" ]; then
        remove_controlled_staging "$install_staging_app" || rollback_failed=true
    fi
    if [ -n "$install_replaced_app" ] && [ ! -e "$canonical_app" ] && [ ! -L "$canonical_app" ]; then
        restore_replaced_app "$install_replaced_app" || rollback_failed=true
    fi
    "$rollback_failed" && return 1
}

cleanup_failed_install_transaction() {
    local exit_code=$?
    trap - EXIT
    if [ "$install_transaction_active" = true ]; then
        rollback_install_transaction || printf 'error: installation rollback left recoverable evidence\n' >&2
    fi
    exit "$exit_code"
}

quarantine_failed_canonical() {
    local failed_app="$1"
    [ ! -L "$canonical_app" ] || { installer_error 'cannot quarantine a symlink canonical path'; return 1; }
    [ -e "$canonical_app" ] || return
    [ ! -e "$failed_app" ] && [ ! -L "$failed_app" ] || {
        installer_error "cannot quarantine failed canonical app; evidence path exists: $failed_app"
        return 1
    }
    mv -- "$canonical_app" "$failed_app" || {
        installer_error 'could not quarantine failed canonical app before rollback'
        return 1
    }
    if is_target_bundle "$failed_app"; then
        safe_remove_app "$failed_app" || printf 'error: retained validated failed canonical evidence: %s\n' "$failed_app" >&2
    else
        printf 'error: retained unrecognized failed canonical evidence: %s\n' "$failed_app" >&2
    fi
}

install_canonical_app() {
    local built_app="$1" commit="$2" build_number="$3"
    local staging_app replaced_app failed_app transaction_id
    applications_directory="$(canonical_directory "$applications_directory")" || { installer_error 'cannot resolve Applications directory'; return 1; }
    if [ "$installer_test_mode" = false ]; then
        [ "$applications_directory" = '/Applications' ] || { installer_error 'unexpected /Applications canonical path'; return 1; }
    fi
    [ -w "$applications_directory" ] || { installer_error 'Applications directory is not safely writable by the current user'; return 1; }
    [ ! -L "$canonical_app" ] || { installer_error 'refusing to replace symlink canonical path'; return 1; }
    if [ -e "$canonical_app" ]; then
        assert_target_app "$canonical_app" || return 1
        [ ! -d "$canonical_app/Contents/Application Support" ] || { installer_error 'canonical app contains a user data directory'; return 1; }
        [ ! -d "$canonical_app/Contents/Preferences" ] || { installer_error 'canonical app contains a user data directory'; return 1; }
    fi
    transaction_id="${BASHPID:-$$}.${RANDOM}"
    staging_app="$applications_directory/.Target.app.installing-$transaction_id"
    replaced_app="$applications_directory/.Target.app.replaced-$transaction_id"
    failed_app="$applications_directory/.Target.app.installing-$transaction_id.failed"
    [ ! -e "$staging_app" ] && [ ! -L "$staging_app" ] || { installer_error "staging path already exists: $staging_app"; return 1; }
    [ ! -e "$replaced_app" ] && [ ! -L "$replaced_app" ] || { installer_error "replacement path already exists: $replaced_app"; return 1; }
    if [ "${dry_run:-false}" = true ]; then
        printf 'would copy validated build: %s -> %s\n' "$built_app" "$staging_app"
        printf 'would rename canonical app through: %s\n' "$replaced_app"
        printf 'would install canonical app: %s\n' "$canonical_app"
        return
    fi

    install_staging_app="$staging_app"
    install_replaced_app=''
    install_transaction_active=true
    if test_failpoint 'copy' || ! ditto "$built_app" "$staging_app"; then
        installer_error 'could not copy validated build into staging'
        rollback_install_transaction || true
        return 1
    fi
    verify_built_app "$staging_app" "$commit" "$build_number" || {
        rollback_install_transaction || true
        return 1
    }
    if [ -e "$canonical_app" ]; then
        mv -- "$canonical_app" "$replaced_app" || {
            installer_error 'could not move canonical app to replacement path'
            rollback_install_transaction || true
            return 1
        }
        install_replaced_app="$replaced_app"
    fi
    if test_failpoint 'staging_rename' || ! mv -- "$staging_app" "$canonical_app"; then
        installer_error 'could not move staging app to canonical path'
        rollback_install_transaction || true
        return 1
    fi
    install_staging_app=''
    if ! verify_built_app "$canonical_app" "$commit" "$build_number"; then
        quarantine_failed_canonical "$failed_app" || true
        restore_replaced_app "$replaced_app" || true
        return 1
    fi
    if [ -n "$install_replaced_app" ] && ! safe_remove_app "$install_replaced_app"; then
        installer_error 'could not remove validated old canonical app; recovery will retry on the next run'
        return 1
    fi
    install_replaced_app=''
    install_transaction_active=false
}

validate_target_repository() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || { installer_error 'not inside a Git repository'; return 1; }
    repo_root="$(canonical_directory "$repo_root")" || { installer_error 'cannot resolve repository root'; return 1; }
    cd -- "$repo_root" || return 1
    [ -f 'Target.xcodeproj/project.pbxproj' ] || { installer_error 'Target.xcodeproj is missing'; return 1; }
    [ -d 'Target' ] || { installer_error 'Target source directory is missing'; return 1; }
    [ "$(git remote get-url origin 2>/dev/null || true)" = 'https://github.com/jason312928/Target.git' ] || { installer_error 'not the Target public repository'; return 1; }
    [ -z "$(git status --porcelain)" ] || { installer_error 'working tree is not clean'; return 1; }
    git rev-parse --verify HEAD >/dev/null 2>&1 || { installer_error 'cannot resolve current commit'; return 1; }
    [ "$(git branch --show-current)" = 'main' ] || { installer_error 'main branch is required'; return 1; }
    printf '%s\n' "$repo_root"
}
