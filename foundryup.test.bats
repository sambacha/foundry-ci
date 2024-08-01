#!/usr/bin/env bats

load 'bats-mock/stub'
load 'bats-mock/mock'

setup() {
  # Runs before each test
  stub git
  stub curl
  stub cargo
  stub uname
  stub sysctl
  stub mkdir
  stub cd
  stub tar
  stub ln
  stub mv
  stub awk
  stub wget
  stub unzip
  stub help2man
}

teardown() {
  # Runs after each test
  unstub git
  unstub curl
  unstub cargo
  unstub uname
  unstub sysctl
  unstub mkdir
  unstub cd
  unstub tar
  unstub ln
  unstub mv
  unstub awk
  unstub wget
  unstub unzip
  unstub help2man
}

@test "git command should be called during main execution" {
  run ./foundryup.sh --version
  [ "$status" -eq 0 ]
  mock_called git
}

@test "curl command should be called during main execution" {
  run ./foundryup.sh --version
  [ "$status" -eq 0 ]
  mock_called curl
}

@test "cargo command should be called during local repository installation" {
  run ./foundryup.sh --path /path/to/local/repo
  [ "$status" -eq 0 ]
  mock_called cargo
}

@test "appropriate warning is given for unknown option" {
  run ./foundryup.sh --unknown
  [ "$status" -eq 1 ]
  [ "$output" == "foundryup: warning: unknown option: --unknown
Usage:
    foundryup <OPTIONS>

OPTIONS:
    -h, --help      Print help information
    -v, --version   Install a specific version from built binaries
    -b, --branch    Build and install a specific branch
    -P, --pr        Build and install a specific Pull Request
    -C, --commit    Build and install a specific commit
    -r, --repo      Build and install from a remote GitHub repo (uses default branch if no other options are set)
    -p, --path      Build and install a local repository
    -j, --jobs      Number of CPUs to use for building Foundry (default: all CPUs)
    --arch          Install a specific architecture (supports amd64 and arm64)
    --platform      Install a specific platform (supports win32, linux, and darwin)
EOF
" ]
}

@test "ensure function should fail when command fails" {
  stub -r false failing_command
  run ./foundryup.sh --ensure-failing-command
  [ "$status" -eq 1 ]
  [ "$output" == "foundryup: command failed: failing_command" ]
}

@test "install from local repository should call cd and cargo" {
  run ./foundryup.sh --path /path/to/local/repo
  [ "$status" -eq 0 ]
  mock_called cd
  mock_called cargo
}

@test "platform and architecture handling" {
  uname() { echo "Linux"; }
  sysctl() { echo "4"; }
  run ./foundryup.sh --version
  [ "$status" -eq 0 ]
  [ "${lines[0]}" == "foundryup: installing foundry (version nightly, tag nightly)" ]
}

@test "help message should be displayed with --help" {
  run ./foundryup.sh --help
  [ "$status" -eq 0 ]
  [ "${lines[0]}" == "The installer for Foundry." ]
}

@test "warn function should display warning message" {
  run bash -c 'source ./foundryup.sh; warn "test warning"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" == "foundryup: warning: test warning" ]
}

@test "say function should display message" {
  run bash -c 'source ./foundryup.sh; say "test message"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" == "foundryup: test message" ]
}

@test "error function should display error message and exit" {
  run bash -c 'source ./foundryup.sh; err "test error"'
  [ "$status" -eq 1 ]
  [ "${lines[0]}" == "foundryup: test error" ]
}
