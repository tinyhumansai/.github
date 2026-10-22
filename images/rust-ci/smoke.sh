#!/usr/bin/env bash
# Build-time checks for the tools and native libraries used by Rust/OpenHuman CI.
set -euo pipefail

rustc +stable --version
rustc "+${RUST_MSRV}" --version
rustc "+${RUST_OPENHUMAN}" --version
cargo +stable clippy --version
cargo +stable fmt --version
cargo "+${RUST_OPENHUMAN}" clippy --version
cargo "+${RUST_OPENHUMAN}" fmt --version
cargo llvm-cov --version
cargo deny --version
cargo nextest --version
tinymold --version
test "$(tinymold --version)" = "tinymold ${TINYMOLD_VERSION}"
sccache --version
mongod --version | head -1
mongod --version | head -1 | grep -F "v${RUST_CI_MONGODB_MAJOR}."
mongo_dir="${CARGO_HOME}/target/rust-ci-mongo-smoke"
mkdir -p "$mongo_dir"
mongod --fork --bind_ip 127.0.0.1 --port 27027 --replSet rust_ci_smoke \
  --dbpath "$mongo_dir" --logpath "$mongo_dir/mongod.log"
trap 'mongod --shutdown --dbpath "$mongo_dir"; rm -rf "$mongo_dir"' EXIT
mongosh --quiet --port 27027 --eval 'rs.initiate({_id:"rust_ci_smoke",members:[{_id:0,host:"127.0.0.1:27027"}]})'
ready=0
for attempt in {1..30}; do
  if mongosh --quiet --port 27027 --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)'; then ready=1; break; fi
  sleep 1
done
test "$ready" = 1
mongosh --quiet --port 27027 --eval 'const s=db.getMongo().startSession(); s.startTransaction(); s.getDatabase("smoke").probe.insertOne({ok:true}); s.commitTransaction(); s.endSession()'
mongod --shutdown --dbpath "$mongo_dir"
rm -rf "$mongo_dir"
trap - EXIT
mongosh --version
mold --version
jq --version
node --version
pnpm --version
python3 -c 'import tomli'
aws --version
# v1 writes a kubeconfig current kubectl refuses (exec API v1alpha1).
aws --version | grep -q '^aws-cli/2\.'
ssh -V
slirp4netns --version
iptables --version
command -v newuidmap
command -v newgidmap
patchelf --version

# TinyBox needs bubblewrap >= 0.8 (--disable-userns), root-owned and not setuid.
bwrap_path="$(command -v bwrap)"
test "$bwrap_path" = /usr/bin/bwrap
test "$(stat -c '%U:%G %a' /usr/bin/bwrap)" = "root:root 755"
bwrap_version="$(bwrap --version | awk '{print $2}')"
test "$(printf '%s\n0.8.0\n' "$bwrap_version" | sort -V | head -n1)" = 0.8.0
bwrap --help | grep -q -- --disable-userns
tauri-driver --help
WebKitWebDriver --help

# Compile and link using the headers and libraries needed by Tauri, audio,
# input and tray support, then initialize GTK in a real headless display.
check_dir="${CARGO_HOME}/target/rust-ci-smoke"
mkdir -p "$check_dir"
trap 'rm -rf "$check_dir"' EXIT

# Cargo's linker setting must survive both a relocated CARGO_HOME (EX63)
# and coverage RUSTFLAGS. Verify the linker recorded in real ELF binaries,
# including the minimum and OpenHuman toolchains, rather than just its version.
: "${CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER:?mold must be the default Cargo linker}"
mkdir -p "$check_dir/rust/src" "$check_dir/cargo-home"
cat > "$check_dir/rust/Cargo.toml" <<'TOML'
[package]
name = "rust-ci-linker-smoke"
version = "0.0.0"
edition = "2021"
[workspace]
TOML
printf 'fn main() { println!("mold smoke passed"); }\n' > "$check_dir/rust/src/main.rs"
for toolchain in stable "$RUST_MSRV" "$RUST_OPENHUMAN"; do
  for flags in '' '-C instrument-coverage'; do
    CARGO_HOME="$check_dir/cargo-home" RUSTFLAGS="$flags" \
      cargo "+$toolchain" build --manifest-path "$check_dir/rust/Cargo.toml"
    readelf -p .comment "$check_dir/rust/target/debug/rust-ci-linker-smoke" | grep -q mold
    LLVM_PROFILE_FILE="$check_dir/profile-%p.profraw" "$check_dir/rust/target/debug/rust-ci-linker-smoke"
  done
done

cat > "$check_dir/desktop.c" <<'C'
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <libappindicator/app-indicator.h>
#include <librsvg/rsvg.h>
#include <alsa/asoundlib.h>
#include <X11/extensions/XTest.h>
#include <libevdev/libevdev.h>
#include <xdo.h>
int main(int argc, char **argv) {
    if (!gtk_init_check(&argc, &argv)) return 1;
    return webkit_get_major_version() < 2 || snd_asoundlib_version() == NULL;
}
C
# pkg-config emits separate compiler/linker arguments intentionally.
# shellcheck disable=SC2046
cc "$check_dir/desktop.c" -o "$check_dir/desktop" -fuse-ld=mold \
    $(pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1 appindicator3-0.1 librsvg-2.0 alsa xtst x11 libevdev) -lxdo
xvfb-run -a dbus-run-session -- "$check_dir/desktop"
