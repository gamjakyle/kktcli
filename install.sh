#!/usr/bin/env bash
# Installs kktcli for the current macOS user.
#
#   curl -fsSL https://raw.githubusercontent.com/gamjakyle/kktcli/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/gamjakyle/kktcli/main/install.sh | bash -s -- --version 0.2.1
#   ./install.sh --from-source        # in a checkout: build it and install the result
#
# On Apple silicon it downloads kktcli-<version>-macos-arm64.tar.gz and its .sha256 from the
# GitHub release v<version> (the latest release unless a version is given) and installs the
# binary only after `shasum -a 256 -c` passes.
# On other Macs, after a failed download, or with --from-source it builds the checkout it is
# run from with `swift build -c release`. It writes only the install directory and a
# temporary directory that is removed on exit (a source build also fills the checkout's
# SwiftPM build directory). See `install.sh --help`.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "install.sh: run this script with bash" >&2
  exit 1
fi

set -eu
set -o pipefail

REPO_URL="https://github.com/gamjakyle/kktcli"
LATEST_URL="$REPO_URL/releases/latest"
ACCESSIBILITY_SETTINGS="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

usage() {
  cat <<'EOF'
Usage: install.sh [--version X.Y.Z] [--from-source] [--prefix DIR] [--dry-run]

Installs kktcli as DIR/kktcli.

  --version X.Y.Z  release to install (default: $KKTCLI_VERSION, else the VERSION file
                   of the checkout this script is in, else the latest release)
  --from-source    build this checkout with `swift build -c release` instead of
                   downloading a release
  --prefix DIR     install directory, created if missing (default: $HOME/.local/bin)
  --dry-run        print what would happen; download, build and write nothing
  -h, --help       show this help

On Apple silicon (arm64) the release tarball and its .sha256 are downloaded from
https://github.com/gamjakyle/kktcli/releases and the binary is installed only if its
SHA-256 matches. On other Macs, or when the download fails, a checkout is built from
source instead. Source builds honour KKTCLI_BUILD_PATH (swift build --build-path) and
KKTCLI_BUILD_JOBS (swift build -j).
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'install.sh: %s\n' "$*" >&2; }
die() {
  warn "$*"
  exit 1
}
usage_error() {
  warn "$*"
  usage >&2
  exit 64
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --version)
        [ $# -ge 2 ] || usage_error "--version needs a value such as 0.2.0"
        opt_version=$2
        shift 2
        ;;
      --version=*)
        opt_version=${1#*=}
        shift
        ;;
      --prefix)
        [ $# -ge 2 ] || usage_error "--prefix needs a directory"
        prefix=$2
        shift 2
        ;;
      --prefix=*)
        prefix=${1#*=}
        shift
        ;;
      --from-source)
        from_source=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
}

# Prints the directory of this script when it is a kktcli checkout; nothing when the script
# arrives on stdin (curl ... | bash).
find_checkout() {
  local script=${BASH_SOURCE[0]:-} dir
  if [ -z "$script" ] || [ ! -f "$script" ]; then
    return 0
  fi
  dir=$(cd "$(dirname "$script")" && pwd -P) || return 0
  if [ -f "$dir/VERSION" ] && [ -d "$dir/Sources/kktcli" ] &&
    grep -q 'name: "kktcli"' "$dir/Package.swift" 2>/dev/null; then
    say "$dir"
  fi
}

is_release_version() {
  local pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
  [[ $1 =~ $pattern ]]
}

# --version, else $KKTCLI_VERSION, else the checkout's VERSION file; empty if none.
resolve_version() {
  version=$opt_version
  if [ -z "$version" ]; then
    version=${KKTCLI_VERSION:-}
  fi
  if [ -z "$version" ] && [ -n "$src_dir" ]; then
    version=$(tr -d '[:space:]' <"$src_dir/VERSION")
  fi
  if [ -n "$version" ] && ! is_release_version "$version"; then
    die "'$version' is not a release version: use X.Y.Z such as 0.2.0 (no leading v)"
  fi
}

resolve_prefix() {
  if [ -z "$prefix" ]; then
    [ -n "${HOME:-}" ] || die "HOME is not set; pass --prefix DIR"
    prefix="$HOME/.local/bin"
  fi
  # --prefix=~/bin reaches us with a literal ~.
  case $prefix in
    "~") prefix=${HOME:?} ;;
    "~/"*) prefix="${HOME:?}/${prefix#"~/"}" ;;
  esac
  case $prefix in
    /*) ;;
    *) prefix="$PWD/$prefix" ;;
  esac
  while [ "$prefix" != / ] && [ "${prefix%/}" != "$prefix" ]; do
    prefix=${prefix%/}
  done
  if [ -e "$prefix" ] && { [ ! -d "$prefix" ] || [ ! -w "$prefix" ]; }; then
    die "$prefix is not a directory you can write to; pass another --prefix"
  fi
  dest="$prefix/kktcli"
}

explain_clone() {
  warn "cannot build from source here: this script is not running from a kktcli checkout"
  say "To build from source (needs Xcode or the Command Line Tools):"
  say "  git clone $REPO_URL.git"
  say "  cd kktcli"
  if [ -n "$version" ]; then
    say "  git checkout v$version   # optional: the source of release $version"
  fi
  say "  ./install.sh --from-source"
}

# The latest release's version, from where $LATEST_URL redirects (.../releases/tag/vX.Y.Z);
# no API call and no JSON. Returns 1 when there is none or it is not a release version.
latest_version() {
  local effective tag
  effective=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$LATEST_URL") || return 1
  tag=${effective##*/releases/tag/}
  [ "$tag" != "$effective" ] || return 1
  tag=${tag#v}
  is_release_version "$tag" || return 1
  printf '%s\n' "$tag"
}

# Accepts only one "<sha256>  <tarball>" line, as `shasum -a 256` writes it, so that the check
# covers this tarball; `shasum -a 256 -c` then compares the digest.
verify_checksum() {
  local name=$1 hash="" file="" rest="" hex='^[0-9a-fA-F]{64}$'
  if [ "$(grep -c . "$work/$name.sha256")" = 1 ]; then
    read -r hash file rest <"$work/$name.sha256" || true
  fi
  if ! [[ $hash =~ $hex ]] || [ "${file#\*}" != "$name" ] || [ -n "$rest" ]; then
    die "$name.sha256 does not hold one SHA-256 line for $name; nothing was installed"
  fi
  if ! (cd "$work" && shasum -a 256 -c "$name.sha256"); then
    die "SHA-256 mismatch for $name; nothing was installed"
  fi
}

# Downloads and verifies the release binary and sets $binary. Returns 1 when the download
# fails; exits when the checksum file is wrong or does not match.
download_release() {
  local name="kktcli-$version-macos-arm64.tar.gz"
  local url="$REPO_URL/releases/download/v$version"
  say "Downloading $url/$name"
  if ! curl -fsSL -o "$work/$name" "$url/$name" ||
    ! curl -fsSL -o "$work/$name.sha256" "$url/$name.sha256"; then
    warn "could not download kktcli $version from $url/"
    return 1
  fi
  verify_checksum "$name"
  mkdir "$work/unpacked" || die "could not create $work/unpacked"
  tar -xzf "$work/$name" -C "$work/unpacked" kktcli ||
    die "could not unpack kktcli from $name; nothing was installed"
  binary="$work/unpacked/kktcli"
  if [ ! -f "$binary" ] || [ -L "$binary" ]; then
    die "$name has no kktcli binary at its root; nothing was installed"
  fi
  expected=$version
}

build_from_source() {
  local checkout_version bin_dir
  command -v swift >/dev/null 2>&1 ||
    die "swift not found: install Xcode or the Command Line Tools (xcode-select --install) and rerun"
  checkout_version=$(tr -d '[:space:]' <"$src_dir/VERSION")
  if [ -n "$version" ] && [ "$version" != "$checkout_version" ]; then
    warn "this checkout is version $checkout_version, not $version; building the checkout (run 'git checkout v$version' first for that release)"
  fi
  say "Building kktcli $checkout_version in $src_dir: swift build ${build_args[*]}"
  (cd "$src_dir" && swift build "${build_args[@]}") || die "swift build failed"
  bin_dir=$(cd "$src_dir" && swift build "${build_args[@]}" --show-bin-path | tail -n 1) ||
    die "could not find the swift build output directory"
  binary="$bin_dir/kktcli"
  [ -f "$binary" ] || die "the build finished but $binary is missing"
  expected=$checkout_version
}

install_binary() {
  local out
  mkdir -p "$prefix" || die "could not create $prefix"
  install -m 0755 "$binary" "$dest" || die "could not write $dest"
  say "Installed $dest"
  if ! out=$("$dest" --version 2>&1); then
    die "installed $dest, but 'kktcli --version' failed: $out"
  fi
  say "kktcli --version: $out"
  case $out in
    "$expected" | "$expected "*) ;;
    *) warn "expected kktcli $expected, but the installed binary reports: $out" ;;
  esac
}

next_steps() {
  local found
  cat <<EOF

Next, allow Accessibility access for $dest:
  1. Open System Settings > Privacy & Security > Accessibility
     (or run: open "$ACCESSIBILITY_SETTINGS").
  2. Click +, press Cmd+Shift+G, enter $dest, add it and turn it on.
  3. After every update or rebuild, remove the kktcli entry there and add it again.
  4. Check with: kktcli status
EOF
  case ":$PATH:" in
    *":$prefix:"*)
      found=$(command -v kktcli 2>/dev/null || true)
      if [ "$dry_run" = 0 ] && [ -n "$found" ] && [ "$found" != "$dest" ]; then
        warn "'kktcli' on your PATH is $found, not $dest; remove that copy or put $prefix first in PATH"
      fi
      ;;
    *)
      say ""
      say "$prefix is not on your PATH. For zsh, the macOS default shell, run"
      say "  echo 'export PATH=\"$prefix:\$PATH\"' >> ~/.zshrc"
      say "and open a new terminal; until then run $dest."
      ;;
  esac
}

dry_run_report() {
  local name="kktcli-$version-macos-arm64.tar.gz"
  local url="$REPO_URL/releases/download/v$version"
  say "Dry run: nothing is downloaded, built or written."
  if [ "$method" = download ] && [ -z "$version" ]; then
    say "Would look up the latest release at $LATEST_URL"
    name="kktcli-<latest>-macos-arm64.tar.gz"
    url="$REPO_URL/releases/download/v<latest>"
  fi
  if [ "$method" = download ]; then
    say "Would download $url/$name"
    say "           and $url/$name.sha256"
    say "Would check them with shasum -a 256 -c and stop on a mismatch"
    if [ -n "$src_dir" ]; then
      say "If the download fails, would build from source in $src_dir"
    fi
  else
    say "Would build in $src_dir: swift build ${build_args[*]}"
  fi
  if [ ! -d "$prefix" ]; then
    say "Would create $prefix"
  fi
  say "Would install $dest (mode 0755) and run: $dest --version"
  next_steps
}

main() {
  local arch tmp_root
  opt_version="" prefix="" from_source=0 dry_run=0
  parse_args "$@"

  [ "$(uname -s)" = Darwin ] || die "kktcli runs only on macOS"
  [ "$(id -u)" != 0 ] || die "run this as your own user, not as root: kktcli is installed and allowed per user"

  src_dir=$(find_checkout)
  resolve_version
  resolve_prefix
  build_args=(-c release)
  if [ -n "${KKTCLI_BUILD_PATH:-}" ]; then
    build_args+=(--build-path "$KKTCLI_BUILD_PATH")
  fi
  if [ -n "${KKTCLI_BUILD_JOBS:-}" ]; then
    build_args+=(-j "$KKTCLI_BUILD_JOBS")
  fi

  arch=$(uname -m)
  if [ "$from_source" = 1 ]; then
    method=source
  elif [ "$arch" != arm64 ]; then
    say "Release binaries are built for Apple silicon (arm64) only; this Mac reports $arch."
    method=source
  else
    method=download
  fi
  if [ "$method" = source ] && [ -z "$src_dir" ]; then
    explain_clone
    exit 1
  fi

  if [ "$dry_run" = 1 ]; then
    dry_run_report
    return 0
  fi
  if [ "$method" = download ] && [ -z "$version" ]; then
    version=$(latest_version) ||
      die "could not find the latest release at $LATEST_URL: pass --version X.Y.Z (see $REPO_URL/releases) or set KKTCLI_VERSION"
    say "Latest release: $version"
  fi

  tmp_root=${TMPDIR:-/tmp}
  work=$(mktemp -d "${tmp_root%/}/kktcli-install.XXXXXX") || die "could not create a temporary directory"
  trap 'rm -rf "$work"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  binary="" expected=""
  if [ "$method" = download ] && ! download_release; then
    method=source
  fi
  if [ "$method" = source ]; then
    if [ -z "$src_dir" ]; then
      explain_clone
      exit 1
    fi
    build_from_source
  fi
  install_binary
  next_steps
}

# Everything runs from here, so a partly downloaded script does nothing.
main "$@"
