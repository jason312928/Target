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
installer_xcodebuild='xcodebuild'
installer_ditto='ditto'
installer_lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
installer_mdimport='mdimport'
test_home_root=''
test_tools_root=''
install_staging_app=''
install_replaced_app=''
install_transaction_active=false
install_transaction_phase='closed'

installer_error() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

canonical_directory() {
    [ -d "$1" ] || return 1
    (cd -P -- "$1" && pwd -P)
}

path_is_strictly_within() {
    local root="$1" path="$2"
    [ "$path" != "$root" ] || return 1
    case "$path" in
        "$root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_test_directory_path() {
    local path="$1" label="$2" relative component current
    local -a components
    [ "$installer_test_mode" = true ] || return 0
    case "$path" in
        /*/../*|/*/./*|*/..|*/.) installer_error "$label contains a non-canonical path component"; return 1 ;;
    esac
    path_is_strictly_within "$installer_test_root" "$path" || {
        installer_error "$label must remain inside the isolated test root"
        return 1
    }
    relative="${path#"$installer_test_root"/}"
    IFS='/' read -r -a components <<< "$relative"
    current="$installer_test_root"
    for component in "${components[@]}"; do
        [ -n "$component" ] || { installer_error "$label contains an empty path component"; return 1; }
        current="$current/$component"
        [ ! -L "$current" ] || { installer_error "$label contains a symlink component: $current"; return 1; }
        if [ -e "$current" ]; then
            [ -d "$current" ] || { installer_error "$label contains a non-directory component: $current"; return 1; }
            [ "$(canonical_directory "$current")" = "$current" ] || {
                installer_error "$label resolves outside its canonical test path: $current"
                return 1
            }
        fi
    done
}

validate_test_command_fixture() {
    local command_path="$1" label="$2" command_parent canonical_parent
    [ "$installer_test_mode" = true ] || return 0
    validate_test_directory_path "$test_tools_root" 'test tools directory' || return 1
    path_is_strictly_within "$test_tools_root" "$command_path" || {
        installer_error "$label fixture must be inside the isolated tools directory"
        return 1
    }
    [ -f "$command_path" ] && [ ! -L "$command_path" ] && [ -x "$command_path" ] || {
        installer_error "test mode requires a regular executable $label fixture"
        return 1
    }
    command_parent="$(dirname -- "$command_path")"
    canonical_parent="$(canonical_directory "$command_parent")" || {
        installer_error "cannot resolve the $label fixture directory"
        return 1
    }
    [ "$canonical_parent/${command_path##*/}" = "$command_path" ] || {
        installer_error "$label fixture does not have a canonical test path"
        return 1
    }
}

validate_test_mode_paths() {
    [ "$installer_test_mode" = true ] || return 0
    [ -d "$installer_test_root" ] && [ ! -L "$installer_test_root" ] || {
        installer_error 'test root must be a regular directory and not a symlink'
        return 1
    }
    [ "$(canonical_directory "$installer_test_root")" = "$installer_test_root" ] || {
        installer_error 'test root must remain a canonical absolute path'
        return 1
    }
    validate_test_directory_path "$applications_directory" 'test Applications directory' || return 1
    validate_test_directory_path "$test_home_root" 'test Home directory' || return 1
    validate_test_directory_path "$test_home_root/Applications" 'test Home Applications directory' || return 1
    validate_test_directory_path "$test_home_root/Desktop" 'test Home Desktop directory' || return 1
    validate_test_directory_path "$test_home_root/Downloads" 'test Home Downloads directory' || return 1
    validate_test_directory_path "$derived_data_root" 'test DerivedData directory' || return 1
    validate_test_directory_path "$derived_data_path" 'test canonical DerivedData directory' || return 1
    validate_test_directory_path "$archive_root" 'test archive directory' || return 1
    validate_test_directory_path "$test_tools_root" 'test tools directory' || return 1
    validate_test_command_fixture "$installer_xcodebuild" 'xcodebuild' || return 1
    validate_test_command_fixture "$installer_ditto" 'ditto' || return 1
    validate_test_command_fixture "$installer_lsregister" 'lsregister' || return 1
    validate_test_command_fixture "$installer_mdimport" 'mdimport' || return 1
}

configure_installer_paths() {
    if [ "${TARGET_INSTALLER_TEST_MODE:-}" = '1' ]; then
        local requested_test_root
        installer_test_mode=true
        requested_test_root="${TARGET_INSTALLER_TEST_ROOT:-}"
        [ -n "$requested_test_root" ] || { installer_error 'test mode requires TARGET_INSTALLER_TEST_ROOT'; return 1; }
        case "$requested_test_root" in
            /*) ;;
            *) installer_error 'test root must be an absolute path'; return 1 ;;
        esac
        [ -d "$requested_test_root" ] && [ ! -L "$requested_test_root" ] || {
            installer_error 'test root must be a regular directory and not a symlink'
            return 1
        }
        installer_test_root="$(canonical_directory "$requested_test_root")" || { installer_error 'cannot resolve test root'; return 1; }
        [ "$installer_test_root" = "$requested_test_root" ] || { installer_error 'test root must be a canonical absolute path'; return 1; }
        [[ "${installer_test_root##*/}" =~ ^TargetInstallerTests\.[[:alnum:]]{8}$ ]] || {
            installer_error 'test root must be an isolated mktemp directory'
            return 1
        }
        case "$installer_test_root" in
            /|/Applications|/Applications/*) installer_error 'test root must not contain the real Applications directory'; return 1 ;;
        esac
        applications_directory="$installer_test_root/Applications"
        [ -d "$applications_directory" ] || { installer_error 'test root Applications directory is missing'; return 1; }
        canonical_app="$applications_directory/Target.app"
        derived_data_root="$installer_test_root/DerivedData"
        derived_data_path="$derived_data_root/Target-Canonical.noindex"
        archive_root="$installer_test_root/Archived Builds.noindex"
        test_home_root="$installer_test_root/Home"
        test_tools_root="$installer_test_root/tools"
        installer_xcodebuild="$test_tools_root/xcodebuild"
        installer_ditto="$test_tools_root/ditto"
        installer_lsregister="$test_tools_root/lsregister"
        installer_mdimport="$test_tools_root/mdimport"
        validate_test_mode_paths || return 1
        return
    fi

    [ -z "${TARGET_INSTALLER_TEST_ROOT:-}" ] || {
        installer_error 'TARGET_INSTALLER_TEST_ROOT requires TARGET_INSTALLER_TEST_MODE=1'
        return 1
    }
    applications_directory='/Applications'
    canonical_app='/Applications/Target.app'
    derived_data_root="$HOME/Library/Developer/Xcode/DerivedData"
    derived_data_path="$derived_data_root/Target-Canonical.noindex"
    archive_root="$HOME/Library/Application Support/Target/Archived Builds.noindex"
    installer_xcodebuild='xcodebuild'
    installer_ditto='ditto'
    installer_lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    installer_mdimport='mdimport'
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

has_target_bundle_identity() {
    local app="$1"
    [ -d "$app" ] && [ ! -L "$app" ] && \
        [ -d "$app/Contents" ] && [ ! -L "$app/Contents" ] && \
        [ -f "$app/Contents/Info.plist" ] && [ ! -L "$app/Contents/Info.plist" ] && \
        [ "$(plist_value "$app" CFBundleIdentifier || true)" = "$expected_bundle_id" ]
}

is_allowed_controlled_app_path() {
    local app="$1" parent_directory
    case "$app" in
        /*/../*|/*/./*|*/..|*/.) return 1 ;;
    esac
    if [ "$app" = "$canonical_app" ]; then
        return 0
    fi
    case "$app" in
        "$applications_directory"/.Target.app.installing-*|"$applications_directory"/.Target.app.replaced-*)
            parent_directory="$(dirname -- "$app")"
            [ "$parent_directory" = "$applications_directory" ]
            ;;
        "$derived_data_root"/Target*/Build/Products/*/Target.app) return 0 ;;
        *) return 1 ;;
    esac
}

has_recoverable_target_structure() {
    local app="$1"
    has_target_bundle_identity "$app" && \
        [ -d "$app/Contents/MacOS" ] && [ ! -L "$app/Contents/MacOS" ] && \
        [ -f "$app/Contents/MacOS/Target" ] && [ ! -L "$app/Contents/MacOS/Target" ] && [ -x "$app/Contents/MacOS/Target" ] && \
        [ ! -e "$app/Contents/PlugIns/TargetTests.xctest" ] && [ ! -L "$app/Contents/PlugIns/TargetTests.xctest" ]
}

is_recoverable_historical_app() {
    is_allowed_controlled_app_path "$1" && has_recoverable_target_structure "$1"
}

is_target_app() {
    [ "$(basename -- "$1")" = 'Target.app' ] && has_recoverable_target_structure "$1"
}

assert_target_app() {
    is_target_app "$1" || installer_error "expected a recoverable $expected_bundle_id Target.app bundle: $1"
}

assert_recoverable_historical_app() {
    is_recoverable_historical_app "$1" || installer_error "expected a recoverable controlled $expected_bundle_id app bundle: $1"
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
    is_recoverable_historical_app "$app" || { installer_error "expected a recoverable $expected_bundle_id app bundle: $app"; return 1; }
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
        is_recoverable_historical_app "$app" || { installer_error "refusing $kind recovery for unrecognized path: $app"; return 1; }
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
        assert_recoverable_historical_app "$canonical_app" || return 1
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
    assert_recoverable_historical_app "$canonical_app" || {
        installer_error 'restored canonical bundle did not pass ordinary Target App validation'
        return 1
    }
    printf 'restored canonical app: %s\n' "$canonical_app"
}

recover_interrupted_installation() {
    validate_test_mode_paths || return 1
    cleanup_orphaned_staging || return 1
    recover_orphaned_replacements
}

verify_built_app() {
    local app="$1" commit="$2" build_number="$3"
    if test_failpoint 'verify_canonical' && [ "$app" = "$canonical_app" ]; then
        printf 'error: injected canonical verification failure: %s\n' "$app" >&2
        return 1
    fi
    is_allowed_controlled_app_path "$app" || { installer_error "expected a controlled Target app path: $app"; return 1; }
    has_recoverable_target_structure "$app" || { installer_error "expected a recoverable $expected_bundle_id app bundle: $app"; return 1; }
    [ -d "$app/Contents/Resources" ] && [ ! -L "$app/Contents/Resources" ] || { installer_error "missing regular Resources directory in $app"; return 1; }
    [ -f "$app/Contents/MacOS/Target" ] || { installer_error "missing main executable in $app"; return 1; }
    [ -f "$app/Contents/Resources/Assets.car" ] && [ ! -L "$app/Contents/Resources/Assets.car" ] || { installer_error "missing regular compiled asset catalog in $app"; return 1; }
    [ ! -e "$app/Contents/PlugIns/TargetTests.xctest" ] || { installer_error "test bundle was mixed into $app"; return 1; }
    [ "$(plist_value "$app" CFBundleVersion)" = "$build_number" ] || { installer_error "unexpected build number in $app"; return 1; }
    [ "$(plist_value "$app" TargetSourceCommit)" = "$commit" ] || { installer_error "unexpected source commit in $app"; return 1; }
    [ "$(plist_value "$app" TargetSourceCommitShort)" = "${commit:0:12}" ] || { installer_error "unexpected short source commit in $app"; return 1; }
    [ "$(plist_value "$app" TargetBuildChannel)" = 'Local' ] || { installer_error "unexpected build channel in $app"; return 1; }
}

remove_controlled_staging() {
    local app="$1"
    [ -e "$app" ] || [ -L "$app" ] || return 0
    [ ! -L "$app" ] || { installer_error "preserving symlink staging evidence: $app"; return 1; }
    is_recoverable_historical_app "$app" || { installer_error "preserving unrecognized staging evidence: $app"; return 1; }
    safe_remove_app "$app"
}

restore_replaced_app() {
    local replaced_app="$1"
    [ -e "$replaced_app" ] || [ -L "$replaced_app" ] || return 0
    [ ! -L "$replaced_app" ] || { installer_error "cannot restore symlink replacement evidence: $replaced_app"; return 1; }
    is_recoverable_historical_app "$replaced_app" || { installer_error "cannot restore unrecognized replacement evidence: $replaced_app"; return 1; }
    [ ! -e "$canonical_app" ] || { installer_error "cannot restore replacement while canonical path is occupied"; return 1; }
    mv -- "$replaced_app" "$canonical_app" || {
        installer_error "could not restore old canonical app from $replaced_app"
        return 1
    }
    assert_recoverable_historical_app "$canonical_app" || {
        installer_error 'restored canonical bundle did not pass ordinary Target App validation'
        return 1
    }
    printf 'restored old canonical app: %s\n' "$canonical_app"
}

rollback_install_transaction() {
    local rollback_failed=false cleanup_pending=false
    if [ -n "$install_staging_app" ]; then
        remove_controlled_staging "$install_staging_app" || rollback_failed=true
    fi
    if [ -n "$install_replaced_app" ] && { [ -e "$install_replaced_app" ] || [ -L "$install_replaced_app" ]; }; then
        if [ ! -e "$canonical_app" ] && [ ! -L "$canonical_app" ]; then
            restore_replaced_app "$install_replaced_app" || rollback_failed=true
        elif [ "$install_transaction_phase" = 'cleanup_pending' ] && is_recoverable_historical_app "$canonical_app" && is_recoverable_historical_app "$install_replaced_app"; then
            cleanup_pending=true
        else
            installer_error 'cannot complete rollback while canonical and replacement evidence both remain'
            rollback_failed=true
        fi
    fi
    if [ "$rollback_failed" = true ]; then
        return 1
    fi
    if [ "$cleanup_pending" = true ]; then
        install_transaction_active=true
        install_transaction_phase='cleanup_pending'
        return 1
    fi
    install_staging_app=''
    install_replaced_app=''
    install_transaction_active=false
    install_transaction_phase='closed'
    return 0
}

cleanup_failed_install_transaction() {
    local exit_code=$?
    trap - EXIT
    if [ "$install_transaction_active" = true ]; then
        if ! rollback_install_transaction; then
            if [ "$install_transaction_phase" != 'cleanup_pending' ]; then
                printf 'error: installation rollback left recoverable evidence\n' >&2
            fi
            [ "$exit_code" -ne 0 ] || exit_code=1
        fi
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
    if is_recoverable_historical_app "$failed_app"; then
        safe_remove_app "$failed_app" || printf 'error: retained validated failed canonical evidence: %s\n' "$failed_app" >&2
    else
        printf 'error: retained unrecognized failed canonical evidence: %s\n' "$failed_app" >&2
    fi
}

install_canonical_app() {
    local built_app="$1" commit="$2" build_number="$3"
    local staging_app replaced_app failed_app transaction_id
    validate_test_mode_paths || return 1
    applications_directory="$(canonical_directory "$applications_directory")" || { installer_error 'cannot resolve Applications directory'; return 1; }
    [ "$applications_directory" != '/Applications' ] || {
        [ "$installer_test_mode" = false ] || { installer_error 'test mode must never resolve to the real /Applications directory'; return 1; }
    }
    if [ "$installer_test_mode" = false ]; then
        [ "$applications_directory" = '/Applications' ] || { installer_error 'unexpected /Applications canonical path'; return 1; }
    else
        path_is_strictly_within "$installer_test_root" "$applications_directory" || { installer_error 'test Applications directory escaped the test root'; return 1; }
        canonical_app="$applications_directory/Target.app"
        path_is_strictly_within "$applications_directory" "$canonical_app" || { installer_error 'test canonical app escaped Applications'; return 1; }
    fi
    [ -w "$applications_directory" ] || { installer_error 'Applications directory is not safely writable by the current user'; return 1; }
    [ ! -L "$canonical_app" ] || { installer_error 'refusing to replace symlink canonical path'; return 1; }
    if [ -e "$canonical_app" ]; then
        is_recoverable_historical_app "$canonical_app" || { installer_error "expected a recoverable $expected_bundle_id canonical app: $canonical_app"; return 1; }
        [ ! -d "$canonical_app/Contents/Application Support" ] || { installer_error 'canonical app contains a user data directory'; return 1; }
        [ ! -d "$canonical_app/Contents/Preferences" ] || { installer_error 'canonical app contains a user data directory'; return 1; }
    fi
    transaction_id="${BASHPID:-$$}.${RANDOM}"
    staging_app="$applications_directory/.Target.app.installing-$transaction_id"
    replaced_app="$applications_directory/.Target.app.replaced-$transaction_id"
    failed_app="$applications_directory/.Target.app.installing-$transaction_id.failed"
    if [ "$installer_test_mode" = true ]; then
        path_is_strictly_within "$applications_directory" "$staging_app" || { installer_error 'test staging path escaped Applications'; return 1; }
        path_is_strictly_within "$applications_directory" "$replaced_app" || { installer_error 'test replacement path escaped Applications'; return 1; }
        path_is_strictly_within "$applications_directory" "$failed_app" || { installer_error 'test failed-app path escaped Applications'; return 1; }
    fi
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
    install_transaction_phase='active'
    if test_failpoint 'copy' || ! "$installer_ditto" "$built_app" "$staging_app"; then
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
        rollback_install_transaction || true
        return 1
    fi
    if [ -n "$install_replaced_app" ] && ! safe_remove_app "$install_replaced_app"; then
        install_transaction_phase='cleanup_pending'
        installer_error 'installation cleanup pending: valid canonical app remains installed and validated replacement cleanup will retry on the next run'
        return 1
    fi
    install_replaced_app=''
    install_transaction_active=false
    install_transaction_phase='closed'
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
