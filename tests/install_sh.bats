#!/usr/bin/env bats
#
# Tests for install.sh's platform gate — the one part of the installer that can
# be exercised without a network, a release, or a real foreign machine, by
# stubbing `uname` on PATH.
#
# Deterministic and offline: `curl` and `wget` are stubbed to fail, so a case
# that gets past the gate dies at the download instead of reaching the network —
# and the message it dies with names the asset that platform selected, which is
# the assertion those cases actually want.

bats_require_minimum_version 1.5.0

bats_load_library bats-support
bats_load_library bats-assert

setup() {
  INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  stub_failing_downloaders
}

# No test here has any business reaching the network. install.sh picks whichever
# of curl/wget is on PATH, so both are replaced with an immediate failure.
stub_failing_downloaders() {
  for tool in curl wget; do
    printf '#!/usr/bin/env sh\nexit 1\n' > "$STUB_DIR/$tool"
    chmod +x "$STUB_DIR/$tool"
  done
}

# Stand in for `uname`, so the gate can be driven to any platform. `-s` reports
# the OS and `-m` the architecture; install.sh calls both.
stub_uname() {
  cat > "$STUB_DIR/uname" <<STUB
#!/usr/bin/env sh
case "\$1" in
  -s) echo '$1' ;;
  -m) echo '$2' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$STUB_DIR/uname"
}

# Run the gate with the stub in front of the real uname. AGENT_APROPOS_BIN_DIR
# points into the test tmpdir so a case that got past the gate could not write
# to a real bin directory.
run_installer() {
  run --separate-stderr env PATH="$STUB_DIR:$PATH" \
    AGENT_APROPOS_BIN_DIR="$BATS_TEST_TMPDIR/bin" sh "$INSTALLER"
}

@test "a Git Bash host names the PowerShell install path" {
  stub_uname 'MINGW64_NT-10.0-26100' 'x86_64'
  run_installer
  assert_failure
  assert_equal "$status" 1
  [[ "$stderr" == *"install.ps1"* ]] || fail "expected the message to name install.ps1: $stderr"
  [[ "$stderr" != *"unsupported OS"* ]] || fail "expected a Windows-specific message, got the generic one: $stderr"
}

@test "an MSYS2 host names the PowerShell install path" {
  stub_uname 'MSYS_NT-10.0-26100' 'x86_64'
  run_installer
  assert_failure
  [[ "$stderr" == *"install.ps1"* ]] || fail "expected the message to name install.ps1: $stderr"
}

@test "a Cygwin host names the PowerShell install path" {
  stub_uname 'CYGWIN_NT-10.0-26100' 'x86_64'
  run_installer
  assert_failure
  [[ "$stderr" == *"install.ps1"* ]] || fail "expected the message to name install.ps1: $stderr"
}

@test "a genuinely unknown OS still reports it as unsupported" {
  stub_uname 'Haiku' 'x86_64'
  run_installer
  assert_failure
  [[ "$stderr" == *"unsupported OS 'Haiku'"* ]] || fail "expected the generic message: $stderr"
  [[ "$stderr" != *"install.ps1"* ]] || fail "install.ps1 is not the answer for a non-Windows OS: $stderr"
}

@test "Linux and macOS still resolve their own assets rather than hitting the gate" {
  for platform in 'Linux x86_64 agent-apropos-linux-x86_64' \
                  'Linux aarch64 agent-apropos-linux-arm64' \
                  'Darwin arm64 agent-apropos-darwin-arm64' \
                  'Darwin x86_64 agent-apropos-darwin-x86_64'; do
    set -- $platform
    stub_uname "$1" "$2"
    run_installer
    # The gate passed, so the run proceeds to the download and fails against
    # the stub instead — on the asset this platform selected, which the
    # download-failure message names.
    assert_failure
    [[ "$stderr" == *"$3"* ]] || fail "expected $1/$2 to select $3, got: $stderr"
  done
}

@test "an unsupported architecture on a supported OS names that OS's architectures" {
  stub_uname 'Linux' 'riscv64'
  run_installer
  assert_failure
  [[ "$stderr" == *"unsupported architecture 'riscv64'"* ]] || fail "unexpected: $stderr"
  [[ "$stderr" == *"Linux ships x86_64/arm64 only"* ]] || fail "unexpected: $stderr"
}
