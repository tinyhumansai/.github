# rust_ci image

`ghcr.io/tinyhumansai/rust_ci` holds what a Rust workspace's CI job would
otherwise install step by step, so the job starts at its first cargo
command:

| Component | Version |
|---|---|
| Ubuntu | 22.04 (the same base as `openhuman_ci` and the EX63 guest) |
| Rust | `stable` (1.99.1) and OpenHuman `1.96.1` with rustfmt, clippy, llvm-tools; `1.96` (MSRV) |
| cargo-llvm-cov, cargo-deny | 0.9.1, 0.20.2 |
| cargo-nextest | 0.9.148 |
| tinymold | 0.3.2 |
| sccache | 0.18.0 |
| Node.js, pnpm | 24.22.0, 10.10.0 |
| tauri-driver | 2.0.5 |
| MongoDB server, mongosh | 7.0.45, latest 2.x |
| mold | 2.40.4 (default Rust linker) |
| clang, cmake, libssl-dev, pkg-config, jq, git | Ubuntu's |
| GTK 3, WebKitGTK 4.1, AppIndicator, librsvg, ALSA, X11/XTest, libxdo, libevdev development libraries | Ubuntu's |
| Xvfb, xauth, AT-SPI, D-Bus, WebKitWebDriver, patchelf, Python/tomli | Ubuntu's |

Downloaded tool archives are checked against sha256 digests pinned in the
Dockerfile. pnpm is installed from npm at a pinned version; tauri-driver is
built from crates.io with its published lockfile. A change to `images/rust-ci/` is built on its pull request and
pushed when it reaches main, tagged `latest`, `rust-<stable>` and
`sha-<commit>`. Pin `sha-<commit>` in workflows.

## Using it

```yaml
jobs:
  rust:
    runs-on: ubuntu-latest
    container: ghcr.io/tinyhumansai/rust_ci:sha-<commit>
    steps:
      - uses: tinyhumansai/.github/actions/checkout@<sha>
      - run: cargo test --all-features
```

Inside a container job, `services:` containers are reachable by their job
name, but `docker run` is not available. Start MongoDB in the job instead
(`mongod --fork --dbpath ... --logpath ...`). The same goes for the EX63
microVMs, which have no Docker either.

Rust builds use mold by default through
`CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=/usr/local/bin/rust-mold-linker`.
The wrapper selects the pinned mold binary with clang, overriding rustc's
bundled-lld hint. It remains effective when coverage sets `RUSTFLAGS` or an
EX63 guest relocates `CARGO_HOME`.

This linker does not enable a compiler cache. Tinymold and sccache are
available on `PATH`; normal CI may choose either with `RUSTC_WRAPPER`.
Release jobs can use the default mold linker while leaving `RUSTC_WRAPPER`
and `RUSTC_WORKSPACE_WRAPPER` empty. Tests may use `cargo nextest run`.

## OpenHuman CI

The image includes the native development and headless desktop dependencies
from [OpenHuman's CI Dockerfile](https://github.com/tinyhumansai/openhuman/blob/main/.github/Dockerfile),
plus its Node 24/pnpm toolchain, sccache and tauri-driver. OpenHuman's
`rust-toolchain.toml` selects the preinstalled `1.96.1` toolchain.

Run desktop test commands under a display and D-Bus session, for example:

```sh
xvfb-run -a dbus-run-session -- bash app/scripts/e2e-run-session.sh
```

The image does not start background desktop services automatically. CI jobs
choose when to start them. Repository JS dependencies and browser downloads
remain part of the consuming workflow's setup. Existing workflows need to
select this image's published SHA tag to use it.

Every image build runs `smoke.sh`: tool checks; real Rust ELF linker checks
for stable, MSRV and OpenHuman toolchains, with and without coverage flags
and with a relocated `CARGO_HOME`; a C compile/link against the
native development libraries using mold, and GTK initialization under Xvfb
and D-Bus. This verifies the image dependencies, not the full OpenHuman suite.

## Bumping

- **Rust.** Raise `RUST_STABLE` to the new stable. The build checks that
  rustup's `stable` is that version, so a stale pin fails the build rather
  than publishing a mislabeled image.
- **OpenHuman.** Keep `RUST_OPENHUMAN`, `PNPM_VERSION` and
  `TAURI_DRIVER_VERSION` aligned with its toolchain, package manager and CI
  Dockerfile when updating those dependencies.
- **The other tools.** Raise the version and replace its `*_SHA256` with
  the digest of the new release asset.

Deploy jobs can start Docker in rootless mode using `docker/setup-docker-action`.
The image includes `uidmap`, `slirp4netns`, `iptables`, `iproute2`, OpenSSH and
AWS CLI v2 (`AWSCLI_VERSION`; v1's `aws eks update-kubeconfig` writes an exec
API current kubectl refuses). A VM runner must supply user namespaces and at least 65,536 subordinate
UIDs/GIDs for its job user. No root daemon or privileged Docker socket is baked
into this image. Verify a rootless build in the target VM before enabling deploys;
image build smoke tests cannot prove the host kernel supports user namespaces.

## bubblewrap

`/usr/bin/bwrap` is bubblewrap 0.13.1, built in a Dockerfile stage from the
checksum-verified upstream release tarball (Ubuntu 22.04's package is 0.6.1,
which lacks `--disable-userns`, so TinyBox reports no isolation). It is
root-owned, mode 0755 and not setuid, so a jail needs unprivileged user
namespaces from the VM kernel (`CONFIG_USER_NS`, `user.max_user_namespaces` > 0).
The image build smoke test checks the version and the `--disable-userns` flag.

## MongoDB 8 variant

OpenIntents requires MongoDB 8. The publisher also builds `mongo8-latest`,
`mongo8-rust-<stable>` and `mongo8-sha-<commit>` using MongoDB 8.0.34,
with its own verified signing key and pnpm 10.34.5. Existing tags keep MongoDB 7.0.45.
Both variants smoke-test replica-set primary readiness and a transaction.
Consumers must pin the published digest and roll matching idle EX63 guests
before enabling that pin. Do not replace an active slot's rootfs.
