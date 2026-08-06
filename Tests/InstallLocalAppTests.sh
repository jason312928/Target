#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
transaction_library="$repo_root/Scripts/install_local_app_transaction.sh"
installer_script="$repo_root/Scripts/install_local_app.sh"
commit='0123456789abcdef0123456789abcdef01234567'
build_number='42'
test_root=''
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
    exit "$exit_code"
}

trap cleanup EXIT

test_root="$(mktemp -d "${TMPDIR:-/tmp}/TargetInstallerTests.XXXXXXXX")"
mkdir -p "$test_root/Applications" "$test_root/tools" "$test_root/Home"
printf '#!/usr/bin/env bash\nexit 0\n' > "$test_root/tools/lsregister"
chmod 755 "$test_root/tools/lsregister"

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
}

assert_canonical() {
    local expected_version="$1"
    [ -d "$canonical_app" ] || fail_test 'canonical app is missing'
    [ "$(plist_value "$canonical_app" CFBundleIdentifier)" = "$expected_bundle_id" ] || fail_test 'canonical Bundle ID is wrong'
    [ "$(app_version "$canonical_app")" = "$expected_version" ] || fail_test "canonical version is not $expected_version"
}

reset_apps() {
    rm -rf -- "$applications_directory" "$test_root/Built"
    mkdir -p "$applications_directory" "$test_root/Built"
    install_staging_app=''
    install_replaced_app=''
    install_transaction_active=false
    dry_run=false
    unset TARGET_INSTALLER_TEST_FAILPOINT || true
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

rm -rf -- "$test_root"
[ ! -e "$test_root" ] || fail_test 'temporary test root final cleanup failed'
printf 'PASS: %d installer recovery scenarios; isolated temporary root removed\n' "$passed"
