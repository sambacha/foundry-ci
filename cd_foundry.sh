#!/usr/bin/env bash
set -eo pipefail

BASE_DIR=${XDG_CONFIG_HOME:-$HOME}
FOUNDRY_DIR=${FOUNDRY_DIR:-"$BASE_DIR/.foundry"}
FOUNDRY_BIN_DIR="$FOUNDRY_DIR/bin"
FOUNDRY_MAN_DIR="$FOUNDRY_DIR/share/man/man1"

FOUNDRYUP_JOBS=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu)

BINS=(forge cast anvil chisel)

export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"

main() {
  need_cmd git
  need_cmd curl

  parse_args "$@"

  CARGO_BUILD_ARGS=(--release)
  [ -n "$FOUNDRYUP_JOBS" ] && CARGO_BUILD_ARGS+=(--jobs "$FOUNDRYUP_JOBS")

  banner

  validate_args

  if [[ -n "$FOUNDRYUP_LOCAL_REPO" ]]; then
    install_from_local_repo
  else
    FOUNDRYUP_REPO=${FOUNDRYUP_REPO:-foundry-rs/foundry}
    if [[ "$FOUNDRYUP_REPO" == "foundry-rs/foundry" && -z "$FOUNDRYUP_BRANCH" && -z "$FOUNDRYUP_COMMIT" ]]; then
      install_from_binaries
    else
      install_from_repo
    fi
  fi
}

parse_args() {
  while [[ -n $1 ]]; do
    case $1 in
      --) shift; break;;
      -r|--repo) shift; FOUNDRYUP_REPO=$1;;
      -b|--branch) shift; FOUNDRYUP_BRANCH=$1;;
      -v|--version) shift; FOUNDRYUP_VERSION=$1;;
      -p|--path) shift; FOUNDRYUP_LOCAL_REPO=$1;;
      -P|--pr) shift; FOUNDRYUP_PR=$1;;
      -C|--commit) shift; FOUNDRYUP_COMMIT=$1;;
      -j|--jobs) shift; FOUNDRYUP_JOBS=$1;;
      --arch) shift; FOUNDRYUP_ARCH=$1;;
      --platform) shift; FOUNDRYUP_PLATFORM=$1;;
      -h|--help) usage; exit 0;;
      *) warn "unknown option: $1"; usage; exit 1;;
    esac
    shift
  done
}

validate_args() {
  if [ -n "$FOUNDRYUP_PR" ]; then
    if [ -z "$FOUNDRYUP_BRANCH" ]; then
      FOUNDRYUP_BRANCH="refs/pull/$FOUNDRYUP_PR/head"
    else
      err "can't use --pr and --branch at the same time"
    fi
  fi
}

install_from_local_repo() {
  need_cmd cargo

  warn "--branch, --version, and --repo arguments are ignored during local install" if [ -n "$FOUNDRYUP_REPO" ] || [ -n "$FOUNDRYUP_BRANCH" ] || [ -n "$FOUNDRYUP_VERSION" ]

  say "installing from $FOUNDRYUP_LOCAL_REPO"
  cd "$FOUNDRYUP_LOCAL_REPO"
  ensure cargo build --bins "${CARGO_BUILD_ARGS[@]}"

  for bin in "${BINS[@]}"; do
    rm -f "$FOUNDRY_BIN_DIR/$bin"
    ensure ln -s "$PWD/target/release/$bin" "$FOUNDRY_BIN_DIR/$bin"
  done

  say "done"
  exit 0
}

install_from_binaries() {
  FOUNDRYUP_VERSION=${FOUNDRYUP_VERSION:-nightly}
  FOUNDRYUP_TAG=$FOUNDRYUP_VERSION

  normalize_version

  say "installing foundry (version ${FOUNDRYUP_VERSION}, tag ${FOUNDRYUP_TAG})"

  PLATFORM=$(tolower "${FOUNDRYUP_PLATFORM:-$(uname -s)}")
  EXT="tar.gz"
  case $PLATFORM in
    linux) ;;
    darwin|mac*) PLATFORM="darwin";;
    mingw*|win*) EXT="zip"; PLATFORM="win32";;
    *) err "unsupported platform: $PLATFORM";;
  esac

  ARCHITECTURE=$(tolower "${FOUNDRYUP_ARCH:-$(uname -m)}")
  if [ "${ARCHITECTURE}" = "x86_64" ]; then
    ARCHITECTURE=$(sysctl -n sysctl.proc_translated 2>/dev/null && echo "arm64" || echo "amd64")
  elif [ "${ARCHITECTURE}" = "arm64" ] || [ "${ARCHITECTURE}" = "aarch64" ]; then
    ARCHITECTURE="arm64"
  else
    ARCHITECTURE="amd64"
  fi

  RELEASE_URL="https://github.com/${FOUNDRYUP_REPO}/releases/download/${FOUNDRYUP_TAG}/"
  BIN_ARCHIVE_URL="${RELEASE_URL}foundry_${FOUNDRYUP_VERSION}_${PLATFORM}_${ARCHITECTURE}.$EXT"
  MAN_TARBALL_URL="${RELEASE_URL}foundry_man_${FOUNDRYUP_VERSION}.tar.gz"

  download_and_extract_binaries "$BIN_ARCHIVE_URL" "$PLATFORM" "$EXT"
  download_manpages "$MAN_TARBALL_URL"

  for bin in "${BINS[@]}"; do
    bin_path="$FOUNDRY_BIN_DIR/$bin"
    say "installed - $(ensure "$bin_path" --version)"
    warn_path_conflict "$bin" "$bin_path"
  done

  say "done!"
}

install_from_repo() {
  need_cmd cargo
  FOUNDRYUP_BRANCH=${FOUNDRYUP_BRANCH:-master}
  REPO_PATH="$FOUNDRY_DIR/$FOUNDRYUP_REPO"

  [ ! -d "$REPO_PATH" ] && clone_repo

  cd "$REPO_PATH"
  ensure git fetch origin "${FOUNDRYUP_BRANCH}:remotes/origin/${FOUNDRYUP_BRANCH}"
  ensure git checkout "origin/${FOUNDRYUP_BRANCH}"

  [ -n "$FOUNDRYUP_COMMIT" ] && say "installing at commit $FOUNDRYUP_COMMIT" && ensure git checkout "$FOUNDRYUP_COMMIT"

  ensure cargo build --bins "${CARGO_BUILD_ARGS[@]}"
  install_binaries

  generate_manpages

  say "done"
}

normalize_version() {
  if [[ "$FOUNDRYUP_VERSION" =~ ^nightly ]]; then
    FOUNDRYUP_VERSION="nightly"
  elif [[ "$FOUNDRYUP_VERSION" == [[:digit:]]* ]]; then
    FOUNDRYUP_VERSION="v${FOUNDRYUP_VERSION}"
    FOUNDRYUP_TAG="${FOUNDRYUP_VERSION}"
  fi
}

download_and_extract_binaries() {
  local url=$1
  local platform=$2
  local ext=$3

  say "downloading latest forge, cast, anvil, and chisel"
  if [ "$platform" = "win32" ]; then
    tmp="$(mktemp -d 2>/dev/null || echo ".")/foundry.zip"
    ensure download "$url" "$tmp"
    ensure unzip "$tmp" -d "$FOUNDRY_BIN_DIR"
    rm -f "$tmp"
  else
    ensure download "$url" | ensure tar -xzC "$FOUNDRY_BIN_DIR"
  fi
}

download_manpages() {
  local url=$1

  if check_cmd tar; then
    say "downloading manpages"
    mkdir -p "$FOUNDRY_MAN_DIR"
    download "$url" | tar -xzC "$FOUNDRY_MAN_DIR"
  else
    say 'skipping manpage download: missing "tar"'
  fi
}

warn_path_conflict() {
  local bin=$1
  local bin_path=$2

  which_path=$(command -v "$bin" || true)
  if [ -n "$which_path" ] && [ "$which_path" != "$bin_path" ]; then
    warn "There are multiple binaries with the name '$bin' present in your 'PATH'."
    warn "This may be the result of installing '$bin' using another method, like Cargo or other package managers."
    warn "You may need to run 'rm $which_path' or move '$FOUNDRY_BIN_DIR' in your 'PATH' to allow the newly installed version to take precedence!"
  fi
}

clone_repo() {
  local author
  author=$(echo "$FOUNDRYUP_REPO" | cut -d'/' -f1 -)
  ensure mkdir -p "$FOUNDRY_DIR/$author"
  cd "$FOUNDRY_DIR/$author"
  ensure git clone "https://github.com/$FOUNDRYUP_REPO"
}

install_binaries() {
  for bin in "${BINS[@]}"; do
    for try_path in target/release/$bin target/release/$bin.exe; do
      [ -f "$try_path" ] && warn "overwriting existing $bin in $FOUNDRY_BIN_DIR" && mv -f "$try_path" "$FOUNDRY_BIN_DIR"
    done
  done
}

generate_manpages() {
  if check_cmd help2man; then
    for bin in "${BINS[@]}"; do
      help2man -N "$FOUNDRY_BIN_DIR/$bin" > "$FOUNDRY_MAN_DIR/$bin.1"
    done
  fi
}

usage() {
  cat 1>&2 <<EOF
The installer for Foundry.

Update or revert to a specific Foundry version with ease.

By default, the latest nightly version is installed from built binaries.

USAGE:
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
}

say() {
  printf "foundryup: %s\n" "$1"
}

warn() {
  say "warning: ${1}" >&2
}

err() {
  say "$1" >&2
  exit 1
}

tolower() {
  echo "$1" | awk '{print tolower($0)}'
}

need_cmd() {
  check_cmd "$1" || err "need '$1' (command not found)"
}

check_cmd() {
  command -v "$1" &>/dev/null
}

ensure() {
  "$@" || err "command failed: $*"
}

download() {
  if [ -n "$2" ]; then
    check_cmd curl && curl -#o "$2" -L "$1" || wget --show-progress -qO "$2" "$1"
  else
    check_cmd curl && curl -#L "$1" || wget --show-progress -qO- "$1"
  fi
}

banner() {
  printf '

.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx

 ╔═╗ ╔═╗ ╦ ╦ ╔╗╔ ╔╦╗ ╦═╗ ╦ ╦         Portable and modular toolkit
 ╠╣  ║ ║ ║ ║ ║║║  ║║ ╠╦╝ ╚╦╝    for Ethereum Application Development
 ╚   ╚═╝ ╚═╝ ╝╚╝ ═╩╝ ╩╚═  ╩                 written in Rust.

.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx

Repo       : https://github.com/foundry-rs/
Book       : https://book.getfoundry.sh/
Chat       : https://t.me/foundry_rs/
Support    : https://t.me/foundry_support/
Contribute : https://github.com/orgs/foundry-rs/projects/2/

.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx.xOx

'
}

main "$@"
