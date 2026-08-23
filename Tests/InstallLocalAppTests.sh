#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
transaction_library="$repo_root/Scripts/install_local_app_transaction.sh"
installer_script="$repo_root/Scripts/install_local_app.sh"
commit='0123456789abcdef0123456789abcdef01234567'
build_number='42'
test_root=''
sentinel_root=''
passed=0

fail_test() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass_test() {
    passed=$((passed + 1))
    printf 'PASS %02d: %s\n' "$passed" "$1"
}

cleanup() {
    local exit_code=$?
    if [ -n "$test_root" ] && [ -e "$test_root" ]; then
        rm -rf -- "$test_root"
    fi
    if [ -n "$test_root" ] && [ -e "$test_root" ]; then
        printf 'FAIL: temporary test root was not removed: %s\n' "$test_root" >&2
        exit 1
    fi
    if [ -n "$sentinel_root" ] && [ -e "$sentinel_root" ]; then
        rm -rf -- "$sentinel_root"
    fi
    if [ -n "$sentinel_root" ] && [ -e "$sentinel_root" ]; then
        printf 'FAIL: temporary sentinel root was not removed: %s\n' "$sentinel_root" >&2
        exit 1
    fi
    exit "$exit_code"
}

trap cleanup EXIT

test_root="$(mktemp -d "${TMPDIR:-/tmp}/TargetInstallerTests.XXXXXXXX")"
sentinel_root="$(mktemp -d "${TMPDIR:-/tmp}/TargetInstallerSentinels.XXXXXXXX")"
test_root="$(cd -P -- "$test_root" && pwd -P)"
sentinel_root="$(cd -P -- "$sentinel_root" && pwd -P)"
mkdir -p "$test_root/Applications" "$test_root/tools" "$test_root/Home"
cat > "$test_root/tools/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${TARGET_INSTALLER_FIXTURE_LOG:-}" ]; then
    printf 'xcodebuild\n' >> "$TARGET_INSTALLER_FIXTURE_LOG"
fi
if [ "${1:-}" = '-list' ]; then
    printf '    Schemes:\n        Target\n'
    exit 0
fi
derived_data=''
commit=''
build_number=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -derivedDataPath) derived_data="$2"; shift ;;
        TARGET_SOURCE_COMMIT=*) commit="${1#*=}" ;;
        CURRENT_PROJECT_VERSION=*) build_number="${1#*=}" ;;
    esac
    shift
done
[ -n "$derived_data" ] && [ -n "$commit" ] && [ -n "$build_number" ]
app="$derived_data/Build/Products/Release/Target.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
printf '#!/usr/bin/env bash\nexit 0\n' > "$app/Contents/MacOS/Target"
chmod 755 "$app/Contents/MacOS/Target"
: > "$app/Contents/Resources/Assets.car"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.jason312928.Target</string>
<key>CFBundleShortVersionString</key><string>new</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>TargetSourceCommit</key><string>$commit</string>
<key>TargetSourceCommitShort</key><string>${commit:0:12}</string>
<key>TargetBuildChannel</key><string>Local</string>
</dict></plist>
PLIST
EOF
cat > "$test_root/tools/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${TARGET_INSTALLER_FIXTURE_LOG:-}" ]; then
    printf 'ditto\n' >> "$TARGET_INSTALLER_FIXTURE_LOG"
fi
cp -R -- "$1" "$2"
EOF
cat > "$test_root/tools/lsregister" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${TARGET_INSTALLER_FIXTURE_LOG:-}" ]; then
    printf 'lsregister %s\n' "$*" >> "$TARGET_INSTALLER_FIXTURE_LOG"
fi
exit 0
EOF
cat > "$test_root/tools/mdimport" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${TARGET_INSTALLER_FIXTURE_LOG:-}" ]; then
    printf 'mdimport %s\n' "$*" >> "$TARGET_INSTALLER_FIXTURE_LOG"
fi
exit 0
EOF
chmod 755 "$test_root/tools/xcodebuild" "$test_root/tools/ditto" "$test_root/tools/lsregister" "$test_root/tools/mdimport"

export TARGET_INSTALLER_TEST_MODE=1
export TARGET_INSTALLER_TEST_ROOT="$test_root"
source "$transaction_library"
configure_installer_paths

make_app() {
    local app="$1" version="$2" bundle_id="${3:-$expected_bundle_id}"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$app/Contents/MacOS/Target"
    chmod 755 "$app/Contents/MacOS/Target"
    : > "$app/Contents/Resources/Assets.car"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>TargetSourceCommit</key><string>$commit</string>
<key>TargetSourceCommitShort</key><string>${commit:0:12}</string>
<key>TargetBuildChannel</key><string>Local</string>
</dict></plist>
EOF
}

app_version() {
    plist_value "$1" CFBundleShortVersionString
}

artifact_count() {
    find "$applications_directory" -mindepth 1 -maxdepth 1 -name "$1" -print | wc -l | tr -d ' '
}

assert_no_artifacts() {
    [ "$(artifact_count '.Target.app.installing-*')" = 0 ] || fail_test 'unexpected staging artifact'
    [ "$(artifact_count '.Target.app.replaced-*')" = 0 ] || fail_test 'unexpected replacement artifact'
}

assert_transaction_closed() {
    [ -z "$install_staging_app" ] || fail_test 'staging transaction state was retained'
    [ -z "$install_replaced_app" ] || fail_test 'replacement transaction state was retained'
    [ "$install_transaction_active" = false ] || fail_test 'transaction remained active after a successful rollback'
    [ "$install_transaction_phase" = 'closed' ] || fail_test 'transaction phase was not closed'
}

assert_transaction_cleanup_pending() {
    [ -z "$install_staging_app" ] || fail_test 'cleanup-pending state retained a staging path'
    [ -n "$install_replaced_app" ] || fail_test 'cleanup-pending state lost the replacement path'
    [ -d "$install_replaced_app" ] || fail_test 'cleanup-pending replacement evidence is missing'
    [ "$install_transaction_active" = true ] || fail_test 'cleanup-pending transaction was marked inactive'
    [ "$install_transaction_phase" = 'cleanup_pending' ] || fail_test 'transaction phase is not cleanup_pending'
}

assert_canonical() {
    local expected_version="$1"
    [ -d "$canonical_app" ] || fail_test 'canonical app is missing'
    [ "$(plist_value "$canonical_app" CFBundleIdentifier)" = "$expected_bundle_id" ] || fail_test 'canonical Bundle ID is wrong'
    [ "$(app_version "$canonical_app")" = "$expected_version" ] || fail_test "canonical version is not $expected_version"
}

reset_apps() {
    rm -rf -- "$applications_directory" "$test_root/Built" "$derived_data_root" "$archive_root" \
        "$test_home_root/Applications" "$test_home_root/Desktop" "$test_home_root/Downloads"
    mkdir -p "$applications_directory" "$test_root/Built" "$test_home_root/Applications" \
        "$test_home_root/Desktop" "$test_home_root/Downloads"
    install_staging_app=''
    install_replaced_app=''
    install_transaction_active=false
    install_transaction_phase='closed'
    dry_run=false
    unset TARGET_INSTALLER_TEST_FAILPOINT || true
}

make_isolated_test_root() {
    local root
    root="$(mktemp -d "${TMPDIR:-/tmp}/TargetInstallerTests.XXXXXXXX")"
    root="$(cd -P -- "$root" && pwd -P)"
    mkdir -p "$root/Applications" "$root/Home/Applications" "$root/Home/Desktop" \
        "$root/Home/Downloads" "$root/tools"
    cp "$test_root/tools/xcodebuild" "$root/tools/xcodebuild"
    cp "$test_root/tools/ditto" "$root/tools/ditto"
    cp "$test_root/tools/lsregister" "$root/tools/lsregister"
    cp "$test_root/tools/mdimport" "$root/tools/mdimport"
    chmod 755 "$root/tools/xcodebuild" "$root/tools/ditto" "$root/tools/lsregister" "$root/tools/mdimport"
    printf '%s\n' "$root"
}

configure_fixture_root() {
    local root="$1"
    TARGET_INSTALLER_TEST_MODE=1 TARGET_INSTALLER_TEST_ROOT="$root" bash -c '
        set -euo pipefail
        source "$1"
        configure_installer_paths
    ' bash "$transaction_library"
}

assert_sentinel_unchanged() {
    local sentinel="$1" expected="$2"
    [ -f "$sentinel/sentinel.txt" ] || fail_test 'external sentinel file disappeared'
    [ "$(cat "$sentinel/sentinel.txt")" = "$expected" ] || fail_test 'external sentinel content changed'
    [ ! -e "$sentinel/Target.app" ] || fail_test 'external sentinel gained Target.app'
    [ -z "$(find "$sentinel" -mindepth 1 -maxdepth 1 \( -name '.Target.app.installing-*' -o -name '.Target.app.replaced-*' \) -print)" ] || \
        fail_test 'external sentinel gained an installer transaction artifact'
}

expect_failure() {
    local label="$1"
    shift
    if "$@"; then
        fail_test "$label unexpectedly succeeded"
    fi
}

install_fixture() {
    install_canonical_app "$test_root/Built/New.app" "$commit" "$build_number"
}

make_historical_app() {
    local app="$1" version="$2"
    make_app "$app" "$version"
    rm -f -- "$app/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c 'Delete :TargetSourceCommit' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Delete :TargetSourceCommitShort' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Delete :TargetBuildChannel' "$app/Contents/Info.plist"
}

# 1. First installation succeeds without an existing canonical app.
reset_apps
make_app "$test_root/Built/New.app" 'new'
install_fixture
assert_canonical 'new'
assert_no_artifacts
pass_test 'first install exits 0 with a valid new canonical app and no artifacts'

# 2. Replacing an existing canonical app succeeds.
reset_apps
make_app "$canonical_app" 'old'
make_app "$test_root/Built/New.app" 'new'
install_fixture
assert_canonical 'new'
assert_no_artifacts
pass_test 'replacement exits 0 with new canonical version and no artifacts'

# 3. Copy failure leaves the old canonical app unchanged.
reset_apps
make_app "$canonical_app" 'old'
make_app "$test_root/Built/New.app" 'new'
TARGET_INSTALLER_TEST_FAILPOINT='copy'
expect_failure 'copy failure' install_fixture
unset TARGET_INSTALLER_TEST_FAILPOINT
assert_canonical 'old'
assert_no_artifacts
assert_transaction_closed
pass_test 'staging copy failure exits nonzero; old canonical remains and rollback state is clear'

# 4. Failure after the old app was moved restores it.
reset_apps
make_app "$canonical_app" 'old'
make_app "$test_root/Built/New.app" 'new'
TARGET_INSTALLER_TEST_FAILPOINT='staging_rename'
expect_failure 'staging rename failure' install_fixture
unset TARGET_INSTALLER_TEST_FAILPOINT
assert_canonical 'old'
assert_no_artifacts
assert_transaction_closed
pass_test 'staging rename failure exits nonzero, restores the old app, and clears rollback state'

# 5. Failed validation of the new canonical app restores the old app.
reset_apps
make_app "$canonical_app" 'old'
make_app "$test_root/Built/New.app" 'new'
TARGET_INSTALLER_TEST_FAILPOINT='verify_canonical'
expect_failure 'canonical verification failure' install_fixture
unset TARGET_INSTALLER_TEST_FAILPOINT
assert_canonical 'old'
assert_no_artifacts
pass_test 'canonical validation failure exits nonzero, removes failed new app, and restores old app'

# 6. Old-app cleanup failure preserves the good canonical app and is recovered next run.
reset_apps
make_app "$canonical_app" 'old'
make_app "$test_root/Built/New.app" 'new'
TARGET_INSTALLER_TEST_FAILPOINT='remove_replaced'
expect_failure 'replacement cleanup failure' install_fixture
unset TARGET_INSTALLER_TEST_FAILPOINT
assert_canonical 'new'
[ "$(artifact_count '.Target.app.replaced-*')" = 1 ] || fail_test 'validated replacement evidence was not retained'
recover_interrupted_installation
assert_canonical 'new'
assert_no_artifacts
pass_test 'replacement cleanup failure exits nonzero; next recovery safely removes one validated leftover'

# 7. Startup removes only a valid staging artifact.
reset_apps
make_app "$applications_directory/.Target.app.installing-orphan" 'staged'
recover_interrupted_installation
[ ! -e "$applications_directory/.Target.app.installing-orphan" ] || fail_test 'orphaned staging app remains'
assert_no_artifacts
pass_test 'startup with only valid staging artifact exits 0 and removes it'

# 8. Startup restores exactly one valid replacement when canonical is absent.
reset_apps
make_app "$applications_directory/.Target.app.replaced-orphan" 'old'
recover_interrupted_installation
assert_canonical 'old'
assert_no_artifacts
pass_test 'startup with one valid replacement and no canonical exits 0 and restores it'

# 9. Startup removes one validated old replacement when canonical is valid.
reset_apps
make_app "$canonical_app" 'new'
make_app "$applications_directory/.Target.app.replaced-orphan" 'old'
recover_interrupted_installation
assert_canonical 'new'
assert_no_artifacts
pass_test 'startup with valid canonical and one replacement exits 0 and cleans the replacement'

# 10. Multiple valid replacements are ambiguous and are retained.
reset_apps
make_app "$applications_directory/.Target.app.replaced-one" 'old-one'
make_app "$applications_directory/.Target.app.replaced-two" 'old-two'
expect_failure 'ambiguous replacements' recover_interrupted_installation
[ -d "$applications_directory/.Target.app.replaced-one" ] || fail_test 'first ambiguous candidate changed'
[ -d "$applications_directory/.Target.app.replaced-two" ] || fail_test 'second ambiguous candidate changed'
[ ! -e "$canonical_app" ] || fail_test 'ambiguous recovery created canonical app'
pass_test 'multiple replacements exit nonzero and preserve all candidates'

# 11. A symlink replacement is rejected without deletion.
reset_apps
make_app "$test_root/Outside.app" 'outside'
ln -s "$test_root/Outside.app" "$applications_directory/.Target.app.replaced-link"
expect_failure 'symlink replacement' recover_interrupted_installation
[ -L "$applications_directory/.Target.app.replaced-link" ] || fail_test 'symlink replacement changed'
[ -d "$test_root/Outside.app" ] || fail_test 'symlink target changed'
pass_test 'symlink replacement exits nonzero and is not deleted'

# 12. A wrong-Bundle-ID replacement is rejected without deletion.
reset_apps
make_app "$applications_directory/.Target.app.replaced-wrong" 'wrong' 'example.invalid'
expect_failure 'wrong Bundle ID replacement' recover_interrupted_installation
[ -d "$applications_directory/.Target.app.replaced-wrong" ] || fail_test 'wrong-ID replacement changed'
pass_test 'wrong Bundle ID replacement exits nonzero and is not deleted'

# 13. A Bundle-ID-only replacement is rejected without deletion.
reset_apps
make_app "$applications_directory/.Target.app.replaced-incomplete" 'incomplete'
rm -f -- "$applications_directory/.Target.app.replaced-incomplete/Contents/MacOS/Target"
expect_failure 'incomplete replacement' recover_interrupted_installation
[ -d "$applications_directory/.Target.app.replaced-incomplete" ] || fail_test 'incomplete replacement changed'
pass_test 'startup recovery rejects a Bundle-ID-only replacement without deleting it'

# 14. A Bundle-ID-only canonical app does not authorize replacement cleanup.
reset_apps
make_app "$canonical_app" 'incomplete'
rm -f -- "$canonical_app/Contents/MacOS/Target"
make_app "$applications_directory/.Target.app.replaced-valid" 'old'
expect_failure 'incomplete canonical app' recover_interrupted_installation
[ -d "$canonical_app" ] || fail_test 'incomplete canonical app changed'
[ -d "$applications_directory/.Target.app.replaced-valid" ] || fail_test 'validated replacement was deleted beside incomplete canonical app'
pass_test 'startup recovery rejects a Bundle-ID-only canonical app and preserves the replacement'

# 15. Deletion is bounded to approved verified paths.
reset_apps
unapproved_app="$applications_directory/.Target.app.replaced-container/Nested.app"
make_app "$unapproved_app" 'unapproved'
expect_failure 'nested transaction removal path' safe_remove_app "$unapproved_app"
[ -d "$unapproved_app" ] || fail_test 'nested unapproved app was deleted'
pass_test 'nested transaction deletion path exits nonzero and remains intact'

make_repository_fixture() {
    local fixture="$1" remote="$2"
    mkdir -p "$fixture/Target.xcodeproj" "$fixture/Target" "$fixture/Scripts"
    printf '// fixture\n' > "$fixture/Target.xcodeproj/project.pbxproj"
    printf 'fixture\n' > "$fixture/Target/Source.swift"
    cp "$installer_script" "$fixture/Scripts/install_local_app.sh"
    cp "$transaction_library" "$fixture/Scripts/install_local_app_transaction.sh"
    git -C "$fixture" init -q
    git -C "$fixture" checkout -q -b main
    git -C "$fixture" config user.name 'Installer Test'
    git -C "$fixture" config user.email 'installer-test@example.invalid'
    git -C "$fixture" remote add origin "$remote"
    git -C "$fixture" add .
    git -C "$fixture" commit -q -m fixture
}

add_top_level_command_fixtures() {
    local fixture="$1"
    mkdir -p "$fixture/bin"
    cat > "$fixture/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = '-list' ]; then
    printf '    Schemes:\n        Target\n'
    exit 0
fi
derived_data=''
commit=''
build_number=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -derivedDataPath) derived_data="$2"; shift ;;
        TARGET_SOURCE_COMMIT=*) commit="${1#*=}" ;;
        CURRENT_PROJECT_VERSION=*) build_number="${1#*=}" ;;
    esac
    shift
done
[ -n "$derived_data" ] && [ -n "$commit" ] && [ -n "$build_number" ]
app="$derived_data/Build/Products/Release/Target.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
printf '#!/usr/bin/env bash\nexit 0\n' > "$app/Contents/MacOS/Target"
chmod 755 "$app/Contents/MacOS/Target"
: > "$app/Contents/Resources/Assets.car"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.jason312928.Target</string>
<key>CFBundleShortVersionString</key><string>new</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>TargetSourceCommit</key><string>$commit</string>
<key>TargetSourceCommitShort</key><string>${commit:0:12}</string>
<key>TargetBuildChannel</key><string>Local</string>
</dict></plist>
PLIST
EOF
    cat > "$fixture/bin/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cp -R -- "$1" "$2"
EOF
    cat > "$fixture/bin/mdimport" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$fixture/bin/open" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 755 "$fixture/bin/xcodebuild" "$fixture/bin/ditto" "$fixture/bin/mdimport" "$fixture/bin/open"
    git -C "$fixture" add bin
    git -C "$fixture" commit -q -m 'add isolated installer command fixtures'
}

make_top_level_repository_fixture() {
    local fixture="$1"
    make_repository_fixture "$fixture" 'https://github.com/jason312928/Target.git'
    add_top_level_command_fixtures "$fixture"
}

run_top_level_installer() {
    local fixture="$1" stdout_file="$2" stderr_file="$3"
    (
        cd "$fixture"
        PATH="$fixture/bin:$PATH" \
            TARGET_INSTALLER_TEST_MODE=1 \
            TARGET_INSTALLER_TEST_ROOT="$test_root" \
            bash Scripts/install_local_app.sh >"$stdout_file" 2>"$stderr_file"
    )
}

repository_validation() {
    local fixture="$1"
    (
        cd "$fixture"
        source "$transaction_library"
        validate_target_repository >/dev/null
    )
}

# 16. Dirty repositories are rejected.
fixture="$test_root/DirtyRepository"
make_repository_fixture "$fixture" 'https://github.com/jason312928/Target.git'
printf 'dirty\n' > "$fixture/dirty"
expect_failure 'dirty repository' repository_validation "$fixture"
pass_test 'dirty worktree exits nonzero'

# 17. Non-main branches are rejected.
fixture="$test_root/BranchRepository"
make_repository_fixture "$fixture" 'https://github.com/jason312928/Target.git'
git -C "$fixture" checkout -q -b repair
expect_failure 'non-main branch' repository_validation "$fixture"
pass_test 'non-main branch exits nonzero'

# 18. A repository with a different origin is rejected.
fixture="$test_root/WrongRepository"
make_repository_fixture "$fixture" 'https://example.invalid/not-target.git'
expect_failure 'wrong repository' repository_validation "$fixture"
pass_test 'wrong repository exits nonzero'

# 19. The top-level dry run is confined to the test root and changes no files.
fixture="$test_root/DryRunRepository"
make_repository_fixture "$fixture" 'https://github.com/jason312928/Target.git'
mkdir -p "$fixture/bin" "$test_root/Home/Applications"
cat > "$fixture/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
printf '    Schemes:\n        Target\n'
EOF
cat > "$fixture/bin/ditto" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$fixture/bin/xcodebuild" "$fixture/bin/ditto"
git -C "$fixture" add bin
git -C "$fixture" commit -q -m 'add dry-run command fixtures'
[ -z "$(git -C "$fixture" status --porcelain)" ] || fail_test 'dry-run fixture is unexpectedly dirty before invocation'
make_app "$test_root/Home/Applications/Target.app" 'old'
before_tree="$(find "$test_root" -print | LC_ALL=C sort)"
(
    cd "$fixture"
    PATH="$fixture/bin:$PATH" TARGET_INSTALLER_TEST_MODE=1 TARGET_INSTALLER_TEST_ROOT="$test_root" bash Scripts/install_local_app.sh --dry-run >/dev/null
)
after_tree="$(find "$test_root" -print | LC_ALL=C sort)"
[ "$before_tree" = "$after_tree" ] || fail_test 'dry run modified the isolated test root'
[ -d "$test_root/Home/Applications/Target.app" ] || fail_test 'dry run modified an old app candidate'
pass_test 'dry run exits 0 and makes no filesystem changes in the isolated root'

# 20. Normal mode has no path injection and remains fixed to /Applications/Target.app.
env -u TARGET_INSTALLER_TEST_MODE -u TARGET_INSTALLER_TEST_ROOT bash -c '
    source "$1"
    configure_installer_paths
    [ "$applications_directory" = /Applications ]
    [ "$canonical_app" = /Applications/Target.app ]
' bash "$transaction_library" || fail_test 'normal-mode canonical path was redirected'
pass_test 'normal mode remains fixed to /Applications/Target.app'

# 21. Historical canonical apps without Assets.car are replaceable.
reset_apps
make_historical_app "$canonical_app" 'old'
make_app "$test_root/Built/New.app" 'new'
install_fixture
assert_canonical 'new'
assert_no_artifacts
pass_test 'historical canonical without Assets.car is replaced successfully'

# 22. A staging rename failure restores a historical canonical app without Assets.car.
reset_apps
make_historical_app "$canonical_app" 'old'
make_app "$test_root/Built/New.app" 'new'
TARGET_INSTALLER_TEST_FAILPOINT='staging_rename'
expect_failure 'historical staging rename failure' install_fixture
unset TARGET_INSTALLER_TEST_FAILPOINT
assert_canonical 'old'
[ ! -e "$canonical_app/Contents/Resources/Assets.car" ] || fail_test 'historical Assets.car unexpectedly appeared after restore'
assert_no_artifacts
assert_transaction_closed
pass_test 'staging rename failure restores historical canonical without Assets.car'

# 23. A canonical verification failure restores a historical app without Assets.car.
reset_apps
make_historical_app "$canonical_app" 'old'
make_app "$test_root/Built/New.app" 'new'
TARGET_INSTALLER_TEST_FAILPOINT='verify_canonical'
expect_failure 'historical canonical verification failure' install_fixture
unset TARGET_INSTALLER_TEST_FAILPOINT
assert_canonical 'old'
[ ! -e "$canonical_app/Contents/Resources/Assets.car" ] || fail_test 'historical Assets.car unexpectedly appeared after verification rollback'
assert_no_artifacts
assert_transaction_closed
pass_test 'canonical verification failure restores historical canonical without Assets.car'

# 24. Startup restores one historical replacement without Assets.car when canonical is absent.
reset_apps
make_historical_app "$applications_directory/.Target.app.replaced-historical" 'old'
recover_interrupted_installation
assert_canonical 'old'
[ ! -e "$canonical_app/Contents/Resources/Assets.car" ] || fail_test 'historical replacement gained Assets.car during restore'
assert_no_artifacts
pass_test 'startup restores a unique historical replacement without Assets.car'

# 25. Startup removes a historical replacement without Assets.car beside a valid canonical.
reset_apps
make_app "$canonical_app" 'new'
make_historical_app "$applications_directory/.Target.app.replaced-historical" 'old'
recover_interrupted_installation
assert_canonical 'new'
assert_no_artifacts
pass_test 'startup removes a historical replacement without Assets.car beside valid canonical'

# 26. Replacement cleanup failure remains explicitly cleanup pending through rollback.
reset_apps
make_historical_app "$canonical_app" 'old'
make_app "$test_root/Built/New.app" 'new'
TARGET_INSTALLER_TEST_FAILPOINT='remove_replaced'
expect_failure 'cleanup-pending install' install_fixture
assert_canonical 'new'
[ "$(artifact_count '.Target.app.replaced-*')" = 1 ] || fail_test 'cleanup-pending replacement was not retained'
assert_transaction_cleanup_pending
pending_replacement="$install_replaced_app"
expect_failure 'cleanup-pending rollback' rollback_install_transaction
[ "$install_replaced_app" = "$pending_replacement" ] || fail_test 'rollback cleared the pending replacement path'
assert_transaction_cleanup_pending
unset TARGET_INSTALLER_TEST_FAILPOINT
pass_test 'replacement cleanup failure preserves canonical, evidence, and cleanup-pending transaction state'

# 27. A subsequent startup safely cleans the pending historical replacement.
install_staging_app=''
install_replaced_app=''
install_transaction_active=false
install_transaction_phase='closed'
recover_interrupted_installation
assert_canonical 'new'
assert_no_artifacts
assert_transaction_closed
pass_test 'next startup safely cleans the retained cleanup-pending replacement'

# 28. Top-level staging rename failure exits nonzero and its EXIT trap leaves a clean rollback.
reset_apps
fixture="$test_root/TopLevelStagingRepository"
make_top_level_repository_fixture "$fixture"
make_historical_app "$canonical_app" 'old'
export TARGET_INSTALLER_TEST_FAILPOINT='staging_rename'
expect_failure 'top-level staging rename failure' run_top_level_installer "$fixture" "$test_root/top-staging.stdout" "$test_root/top-staging.stderr"
unset TARGET_INSTALLER_TEST_FAILPOINT
assert_canonical 'old'
assert_no_artifacts
if grep -Fq 'rollback left recoverable evidence' "$test_root/top-staging.stderr"; then
    fail_test 'top-level staging failure emitted false recoverable-evidence stderr'
fi
pass_test 'top-level staging rename failure exits nonzero, restores old canonical, and emits no false rollback warning'

# 29. Top-level canonical verification failure exits nonzero and restores the historical app.
reset_apps
fixture="$test_root/TopLevelVerificationRepository"
make_top_level_repository_fixture "$fixture"
make_historical_app "$canonical_app" 'old'
export TARGET_INSTALLER_TEST_FAILPOINT='verify_canonical'
expect_failure 'top-level canonical verification failure' run_top_level_installer "$fixture" "$test_root/top-verify.stdout" "$test_root/top-verify.stderr"
unset TARGET_INSTALLER_TEST_FAILPOINT
assert_canonical 'old'
assert_no_artifacts
if grep -Fq 'rollback left recoverable evidence' "$test_root/top-verify.stderr"; then
    fail_test 'top-level verification failure emitted false recoverable-evidence stderr'
fi
pass_test 'top-level canonical verification failure exits nonzero, restores old canonical, and emits no false rollback warning'

# 30. Top-level cleanup pending preserves both validated apps and succeeds on the next run.
reset_apps
fixture="$test_root/TopLevelCleanupRepository"
make_top_level_repository_fixture "$fixture"
make_historical_app "$canonical_app" 'old'
export TARGET_INSTALLER_TEST_FAILPOINT='remove_replaced'
expect_failure 'top-level cleanup pending' run_top_level_installer "$fixture" "$test_root/top-cleanup.stdout" "$test_root/top-cleanup.stderr"
unset TARGET_INSTALLER_TEST_FAILPOINT
assert_canonical 'new'
[ "$(artifact_count '.Target.app.replaced-*')" = 1 ] || fail_test 'top-level cleanup pending did not retain one replacement'
grep -Fq 'installation cleanup pending:' "$test_root/top-cleanup.stderr" || fail_test 'top-level cleanup pending stderr was missing'
if grep -Fq 'rollback left recoverable evidence' "$test_root/top-cleanup.stderr"; then
    fail_test 'top-level cleanup pending emitted a false rollback warning'
fi
run_top_level_installer "$fixture" "$test_root/top-recovery.stdout" "$test_root/top-recovery.stderr" || fail_test 'next top-level recovery failed'
assert_canonical 'new'
assert_no_artifacts
pass_test 'top-level cleanup pending exits nonzero, preserves evidence, reports accurately, and cleans on next run'

# 31. Bundle-ID-correct canonical and replacement apps without executables fail closed.
reset_apps
make_app "$canonical_app" 'incomplete-new'
make_app "$applications_directory/.Target.app.replaced-incomplete-old" 'incomplete-old'
rm -f -- "$canonical_app/Contents/MacOS/Target" "$applications_directory/.Target.app.replaced-incomplete-old/Contents/MacOS/Target"
expect_failure 'missing executables in canonical and replacement' recover_interrupted_installation
[ -d "$canonical_app" ] || fail_test 'missing-executable canonical was changed'
[ -d "$applications_directory/.Target.app.replaced-incomplete-old" ] || fail_test 'missing-executable replacement was changed'
pass_test 'Bundle-ID-correct canonical and replacement without executables remain fail closed'

# 32. An Applications symlink to an external directory is rejected before any write.
escape_root="$(make_isolated_test_root)"
external_applications="$sentinel_root/ExternalApplications"
mkdir -p "$external_applications"
printf 'applications-sentinel\n' > "$external_applications/sentinel.txt"
rm -rf -- "$escape_root/Applications"
ln -s "$external_applications" "$escape_root/Applications"
expect_failure 'external Applications symlink' configure_fixture_root "$escape_root"
assert_sentinel_unchanged "$external_applications" 'applications-sentinel'
[ -L "$escape_root/Applications" ] || fail_test 'external Applications symlink changed'
rm -rf -- "$escape_root"
pass_test 'test Applications symlink to an external sentinel exits nonzero before staging or replacement writes'

# 33. An Applications symlink to the real /Applications is rejected by path validation alone.
escape_root="$(make_isolated_test_root)"
rm -rf -- "$escape_root/Applications"
ln -s /Applications "$escape_root/Applications"
fixture_log="$sentinel_root/real-applications-fixtures.log"
expect_failure 'real Applications symlink' env TARGET_INSTALLER_FIXTURE_LOG="$fixture_log" \
    TARGET_INSTALLER_TEST_MODE=1 TARGET_INSTALLER_TEST_ROOT="$escape_root" bash -c '
        set -euo pipefail
        source "$1"
        configure_installer_paths
    ' bash "$transaction_library"
[ -L "$escape_root/Applications" ] || fail_test 'real Applications symlink changed'
[ ! -e "$fixture_log" ] || fail_test 'a command fixture ran while rejecting the real Applications symlink'
rm -rf -- "$escape_root"
pass_test 'test Applications symlink to real /Applications exits nonzero without invoking any fixture'

# 34. A Home/Applications symlink cannot expose an external Target.app to collection.
escape_root="$(make_isolated_test_root)"
external_home_apps="$sentinel_root/ExternalHomeApplications"
mkdir -p "$external_home_apps"
make_app "$external_home_apps/Target.app" 'external-home'
printf 'home-applications-sentinel\n' > "$external_home_apps/sentinel.txt"
rm -rf -- "$escape_root/Home/Applications"
ln -s "$external_home_apps" "$escape_root/Home/Applications"
fixture_log="$sentinel_root/home-applications-fixtures.log"
expect_failure 'external Home Applications symlink' env TARGET_INSTALLER_FIXTURE_LOG="$fixture_log" \
    TARGET_INSTALLER_TEST_MODE=1 TARGET_INSTALLER_TEST_ROOT="$escape_root" bash -c '
        set -euo pipefail
        source "$1"
        configure_installer_paths
    ' bash "$transaction_library"
[ -d "$external_home_apps/Target.app" ] || fail_test 'external Home Target.app was moved or deleted'
[ "$(app_version "$external_home_apps/Target.app")" = 'external-home' ] || fail_test 'external Home Target.app changed'
[ ! -e "$fixture_log" ] || fail_test 'lsregister or another fixture ran for an external Home Applications root'
rm -rf -- "$escape_root"
pass_test 'external Home/Applications symlink exits nonzero without moving, deleting, or unregistering its App'

# 35. A DerivedData symlink is rejected before build or cleanup.
escape_root="$(make_isolated_test_root)"
external_derived_data="$sentinel_root/ExternalDerivedData"
mkdir -p "$external_derived_data"
printf 'derived-data-sentinel\n' > "$external_derived_data/sentinel.txt"
ln -s "$external_derived_data" "$escape_root/DerivedData"
fixture_log="$sentinel_root/derived-data-fixtures.log"
expect_failure 'external DerivedData symlink' env TARGET_INSTALLER_FIXTURE_LOG="$fixture_log" \
    TARGET_INSTALLER_TEST_MODE=1 TARGET_INSTALLER_TEST_ROOT="$escape_root" bash -c '
        set -euo pipefail
        source "$1"
        configure_installer_paths
    ' bash "$transaction_library"
assert_sentinel_unchanged "$external_derived_data" 'derived-data-sentinel'
[ ! -e "$fixture_log" ] || fail_test 'xcodebuild or another fixture ran for external DerivedData'
rm -rf -- "$escape_root"
pass_test 'external DerivedData symlink exits nonzero before build, deletion, or fixture execution'

# 36. An archive-root symlink is rejected before archival.
escape_root="$(make_isolated_test_root)"
external_archive="$sentinel_root/ExternalArchive"
mkdir -p "$external_archive"
printf 'archive-sentinel\n' > "$external_archive/sentinel.txt"
ln -s "$external_archive" "$escape_root/Archived Builds.noindex"
expect_failure 'external archive symlink' configure_fixture_root "$escape_root"
assert_sentinel_unchanged "$external_archive" 'archive-sentinel'
rm -rf -- "$escape_root"
pass_test 'external archive-root symlink exits nonzero before archive creation or movement'

# 37. A symlink lsregister fixture is rejected even when executable.
escape_root="$(make_isolated_test_root)"
external_lsregister="$sentinel_root/external-lsregister"
printf '#!/usr/bin/env bash\nprintf called >> "$1"\n' > "$external_lsregister"
chmod 755 "$external_lsregister"
rm -f -- "$escape_root/tools/lsregister"
ln -s "$external_lsregister" "$escape_root/tools/lsregister"
expect_failure 'symlink lsregister fixture' configure_fixture_root "$escape_root"
[ -L "$escape_root/tools/lsregister" ] || fail_test 'lsregister fixture symlink changed'
rm -rf -- "$escape_root"
pass_test 'test-mode lsregister symlink resolving outside the test root exits nonzero'

# 38. A symlink mdimport fixture is rejected even when executable.
escape_root="$(make_isolated_test_root)"
external_mdimport="$sentinel_root/external-mdimport"
printf '#!/usr/bin/env bash\nprintf called >> "$1"\n' > "$external_mdimport"
chmod 755 "$external_mdimport"
rm -f -- "$escape_root/tools/mdimport"
ln -s "$external_mdimport" "$escape_root/tools/mdimport"
expect_failure 'symlink mdimport fixture' configure_fixture_root "$escape_root"
[ -L "$escape_root/tools/mdimport" ] || fail_test 'mdimport fixture symlink changed'
rm -rf -- "$escape_root"
pass_test 'test-mode mdimport symlink resolving outside the test root exits nonzero'

# 39. A missing required fixture fails closed and never falls back to PATH.
escape_root="$(make_isolated_test_root)"
rm -f -- "$escape_root/tools/mdimport"
decoy_bin="$sentinel_root/DecoyBin"
mkdir -p "$decoy_bin"
decoy_log="$sentinel_root/path-fallback.log"
cat > "$decoy_bin/mdimport" <<EOF
#!/usr/bin/env bash
printf 'PATH mdimport called\n' >> "$decoy_log"
EOF
chmod 755 "$decoy_bin/mdimport"
expect_failure 'missing mdimport fixture' env PATH="$decoy_bin:$PATH" \
    TARGET_INSTALLER_TEST_MODE=1 TARGET_INSTALLER_TEST_ROOT="$escape_root" bash -c '
        set -euo pipefail
        source "$1"
        configure_installer_paths
    ' bash "$transaction_library"
[ ! -e "$decoy_log" ] || fail_test 'test mode fell back to PATH for missing mdimport fixture'
rm -rf -- "$escape_root"
pass_test 'missing test command fixture exits nonzero without PATH fallback'

# 40. Valid directories and regular fixtures remain accepted.
escape_root="$(make_isolated_test_root)"
configure_fixture_root "$escape_root" || fail_test 'valid isolated path and command fixtures were rejected'
rm -rf -- "$escape_root"
pass_test 'ordinary isolated directories and regular executable fixtures pass containment validation'

# 41. The test root itself cannot be a symlink.
escape_root="$(make_isolated_test_root)"
symlink_root="$sentinel_root/TargetInstallerTests.SYMROOT1"
ln -s "$escape_root" "$symlink_root"
expect_failure 'symlink test root' configure_fixture_root "$symlink_root"
[ -L "$symlink_root" ] || fail_test 'test-root symlink changed'
rm -f -- "$symlink_root"
rm -rf -- "$escape_root"
pass_test 'a test-root symlink exits nonzero before controlled-path validation'

# 42. A non-canonical absolute spelling of the test root is rejected.
escape_root="$(make_isolated_test_root)"
noncanonical_root="$(dirname -- "$escape_root")/${escape_root##*/}/../${escape_root##*/}"
expect_failure 'non-canonical test root' configure_fixture_root "$noncanonical_root"
[ -d "$escape_root" ] || fail_test 'non-canonical test-root rejection changed the real directory'
rm -rf -- "$escape_root"
pass_test 'a non-canonical absolute test-root path exits nonzero without changing the directory'

rm -rf -- "$test_root"
[ ! -e "$test_root" ] || fail_test 'temporary test root final cleanup failed'
rm -rf -- "$sentinel_root"
[ ! -e "$sentinel_root" ] || fail_test 'temporary sentinel root final cleanup failed'
pass_test 'isolated test roots, command fixtures, and external sentinels are removed'
printf 'PASS: %d installer recovery scenarios; isolated temporary root removed\n' "$passed"
