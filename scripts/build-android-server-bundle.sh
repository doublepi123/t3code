#!/usr/bin/env bash
# Builds the Android t3 server bundle: a self-contained runtime tree an Android
# app extracts and starts with Alpine's nodejs inside PRoot.
#
# The bundle runs on musl, so every native module has to be compiled or fetched
# for musl on the target CPU: node-pty has no musl prebuild (its glibc prebuild
# segfaults), and npm only resolves the fff/keyring musl binaries when it runs on
# musl itself. All work therefore happens inside alpine:3.24 on the runner's
# native architecture; cross-architecture builds would need qemu.
#
# Runtime externals come from apps/server/package.json (resolved through the root
# catalog) pinned to the versions in pnpm-lock.yaml, and the repository patches
# for those packages are applied after `npm install`.
#
# Usage:
#   scripts/build-android-server-bundle.sh \
#     --dist apps/server/dist \
#     --version 0.1.6-pw.4 \
#     --arch x64 \
#     --output-dir release-android
#
# Requires docker on the host, plus network access inside the container for apk
# and npm. Writes t3-<version>-android-linux-<arch>-musl.tar.gz.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly IMAGE="alpine:3.24"

usage() {
  cat <<'USAGE'
Usage: build-android-server-bundle.sh --dist DIR --version VERSION --arch ARCH --output-dir DIR

  --dist DIR         Built server dist directory (bin.mjs, chunks, client/).
  --version VERSION  Release version, used in the bundle and archive name.
  --arch ARCH        x64 or arm64; must match the docker host architecture.
  --output-dir DIR   Directory that receives the .tar.gz.
  --image IMAGE      Build image (default alpine:3.24).
  --keep             Keep the temporary work directory for inspection.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "[android-bundle] $*"
}

dist=""
version=""
arch=""
output_dir=""
image="$IMAGE"
keep=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist)
      dist="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --arch)
      arch="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --image)
      image="${2:-}"
      shift 2
      ;;
    --keep)
      keep=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$dist" ]] || die "--dist is required"
[[ -n "$version" ]] || die "--version is required"
[[ -n "$arch" ]] || die "--arch is required"
[[ -n "$output_dir" ]] || die "--output-dir is required"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "unexpected version: $version"
case "$arch" in
  x64) docker_platform="linux/amd64" ;;
  arm64) docker_platform="linux/arm64" ;;
  *) die "--arch must be x64 or arm64, got: $arch" ;;
esac

[[ -d "$dist" ]] || die "missing dist directory: $dist"
[[ -f "$dist/bin.mjs" ]] || die "missing $dist/bin.mjs"
[[ -f "$dist/client/index.html" ]] || die "missing $dist/client/index.html (the web client ships inside the bundle)"
command -v docker >/dev/null || die "docker is required"

dist="$(cd "$dist" && pwd)"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

stem="t3-${version}-android-linux-${arch}-musl"
work="$(mktemp -d "${TMPDIR:-/tmp}/t3-android-bundle.XXXXXX")"
cleanup() {
  if [[ "$keep" == true ]]; then
    echo "[android-bundle] kept $work"
    return
  fi
  # A failed container run can leave root-owned files behind; ignore that.
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

# Resolves the runtime externals, their exact lockfile versions and the patches
# that apply to them. It runs inside the container, next to the repository mount,
# because it imports scripts/lib/cli-external-packages.ts: that keeps the external
# list in one place and needs no TypeScript build.
cat >"$work/plan.mjs" <<'PLAN'
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [repo, version, arch, output] = process.argv.slice(2);

/** Reads a flat two-space-indented mapping block, enough for catalog and patchedDependencies. */
function readBlock(source, header) {
  const lines = source.split("\n");
  const start = lines.indexOf(`${header}:`);
  const values = {};
  for (let index = start + 1; start !== -1 && index < lines.length; index += 1) {
    const line = lines[index];
    if (line.trim() === "" || line.trimStart().startsWith("#")) continue;
    if (!/^\s/.test(line)) break;
    const match = /^\s+([^:]+):\s*(.+?)\s*$/.exec(line);
    if (!match) continue;
    const key = match[1].trim().replace(/^["']|["']$/g, "");
    values[key] = match[2].trim().replace(/^["']|["']$/g, "");
  }
  return values;
}

/** Exact versions the server importer resolved in the lockfile, without peer suffixes. */
function readServerLockVersions(source) {
  const lines = source.split("\n");
  const start = lines.indexOf("  apps/server:");
  const versions = {};
  let inDependencies = false;
  let current = "";
  for (let index = start + 1; start !== -1 && index < lines.length; index += 1) {
    const line = lines[index];
    if (/^ {2}\S/.test(line)) break;
    if (/^ {4}dependencies:$/.test(line)) {
      inDependencies = true;
      continue;
    }
    if (/^ {4}\S/.test(line)) {
      inDependencies = false;
      continue;
    }
    if (!inDependencies) continue;
    const name = /^ {6}('?)(.+?)\1:$/.exec(line);
    if (name) {
      current = name[2];
      continue;
    }
    const resolved = /^ {8}version: (.+)$/.exec(line);
    if (resolved && current !== "") {
      versions[current] = resolved[1].split("(")[0].trim();
      current = "";
    }
  }
  return versions;
}

const { selectCliRuntimeExternalDependencies } = await import(
  pathToFileURL(join(repo, "scripts/lib/cli-external-packages.ts")).href
);

const serverPackage = JSON.parse(readFileSync(join(repo, "apps/server/package.json"), "utf8"));
const workspace = readFileSync(join(repo, "pnpm-workspace.yaml"), "utf8");
const catalog = readBlock(workspace, "catalog");
const patchedDependencies = readBlock(workspace, "patchedDependencies");
const lockedVersions = readServerLockVersions(
  readFileSync(join(repo, "pnpm-lock.yaml"), "utf8"),
);

const resolved = Object.fromEntries(
  Object.entries(serverPackage.dependencies).map(([name, spec]) => {
    if (!spec.startsWith("catalog:")) return [name, spec];
    const key = spec.slice("catalog:".length).trim() || name;
    const catalogVersion = catalog[key];
    if (catalogVersion === undefined) {
      throw new Error(`apps/server depends on ${name} through the missing catalog key ${key}`);
    }
    return [name, catalogVersion];
  }),
);

// The lockfile decides exact versions so the repository patches keep applying.
const dependencies = Object.fromEntries(
  Object.entries(selectCliRuntimeExternalDependencies(resolved)).map(([name, spec]) => {
    const locked = lockedVersions[name];
    return [name, locked ?? spec.replace(/^[\^~]/, "")];
  }),
);

const patches = [];
for (const [key, file] of Object.entries(patchedDependencies)) {
  const separator = key.lastIndexOf("@");
  const name = separator > 0 ? key.slice(0, separator) : key;
  const patchedVersion = separator > 0 ? key.slice(separator + 1) : "";
  if (!Object.hasOwn(dependencies, name)) continue;
  if (patchedVersion !== dependencies[name]) {
    process.stderr.write(
      `warning: ${name} patch targets ${patchedVersion} but the bundle pins ${dependencies[name]}\n`,
    );
    continue;
  }
  patches.push({ package: name, file });
}

writeFileSync(
  output,
  `${JSON.stringify(
    {
      version,
      arch,
      nodeEngine: serverPackage.engines?.node ?? ">=24",
      dependencies,
      overrides: dependencies,
      patches,
    },
    null,
    2,
  )}\n`,
);
PLAN

cat >"$work/probe.mjs" <<'PROBE'
const base = `http://127.0.0.1:${process.env.SMOKE_PORT ?? "3773"}`;
const mode = process.argv[2];
const fail = (message) => {
  console.error(message);
  process.exit(1);
};

if (mode === "wait") {
  try {
    const response = await fetch(`${base}/.well-known/t3/environment`, {
      signal: AbortSignal.timeout(2000),
    });
    if (!response.ok) fail(`environment endpoint returned ${response.status}`);
    const body = await response.json();
    if (body === null || typeof body !== "object") fail("environment endpoint did not return JSON");
    console.log("environment endpoint ok");
  } catch (error) {
    fail(String(error));
  }
} else if (mode === "login") {
  const response = await fetch(`${base}/api/auth/browser-session`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ credential: process.env.SMOKE_PASSWORD }),
  });
  const body = await response.text();
  if (response.status !== 200) fail(`password login returned ${response.status}: ${body.slice(0, 500)}`);
  if (!response.headers.get("set-cookie")) fail("password login returned no Set-Cookie");
  console.log("password login ok");
} else {
  fail(`unknown probe mode: ${mode}`);
}
PROBE

cat >"$work/in-alpine.sh" <<'IN_ALPINE'
#!/bin/sh
# Runs inside alpine:3.24 with /work (read-write), /repo and /input/dist (read-only).
set -eu

log() { printf '[android-bundle] %s\n' "$*"; }

# node-pty and the other native externals compile from source; node-gyp needs a
# toolchain and headers, the rest is the smallest set npm install needs.
apk add --no-cache nodejs npm python3 make g++ linux-headers patch tar
log "Alpine $(cat /etc/alpine-release) on $(apk --print-arch), node $(node --version)"

node /work/plan.mjs /repo "$BUNDLE_VERSION" "$BUNDLE_ARCH" /work/plan.json

build=/work/build
rm -rf "$build" /work/stage /work/out
mkdir -p "$build" /work/stage /work/out
cp -a /input/dist/. "$build"/
# Sourcemaps triple the tree and are useless at runtime.
find "$build" -name "*.map" -delete

# Runtime package.json: exact external versions plus the same pins as overrides,
# so a transitive copy cannot drift away from the repository patches.
node -e '
const fs = require("node:fs");
const plan = JSON.parse(fs.readFileSync("/work/plan.json", "utf8"));
const packageJson = {
  name: "t3-android-server",
  version: plan.version,
  private: true,
  description: "T3 Code server runtime for Android: Alpine musl inside PRoot.",
  engines: { node: plan.nodeEngine },
  // bin.mjs resolves the web client from the directory it lives in.
  bin: { t3: "./bin.mjs" },
  dependencies: plan.dependencies,
  overrides: plan.overrides,
};
fs.writeFileSync("/work/build/package.json", JSON.stringify(packageJson, null, 2) + "\n");
'

log "Installing runtime externals: $(node -p 'Object.keys(require("/work/plan.json").dependencies).join(", ")')"
cd "$build"
npm install --omit=dev --no-audit --no-fund --loglevel=error --foreground-scripts

node -e '
const plan = require("/work/plan.json");
for (const patch of plan.patches) console.log(`${patch.package}\t${patch.file}`);
' >/work/patches.tsv
while IFS="$(printf '\t')" read -r patch_package patch_file; do
  [ -n "$patch_package" ] || continue
  log "Applying $(basename "$patch_file") to $patch_package"
  patch -p1 --batch --forward --silent -d "node_modules/$patch_package" -i "/repo/$patch_file"
done </work/patches.tsv

# npm installs node-pty's glibc prebuild on musl and it segfaults, so build the
# addon against musl and leave no prebuild for the loader to fall back to.
log "Rebuilding node-pty against musl"
(cd node_modules/node-pty && npx --yes node-gyp rebuild)
test -f node_modules/node-pty/build/Release/pty.node

log "Pruning bundle"
rm -rf node_modules/node-pty/prebuilds
# Intermediates from the source build; the loader only needs Release/pty.node.
rm -rf node_modules/node-pty/build/Release/obj.target node_modules/node-pty/build/Release/.deps
# Windows-only ConPTY sources.
rm -rf node_modules/node-pty/third_party
find node_modules -name "*.map" -delete
find node_modules -type d -name ".bin" -prune -exec rm -rf {} \; 2>/dev/null || true
rm -rf node_modules/.package-lock.json package-lock.json

log "PTY smoke test"
pty_log=/tmp/pty-smoke.log
if ! timeout 60 node -e '
const pty = require("node-pty");
const child = pty.spawn("/bin/sh", ["-c", "echo pty-ok"], { name: "xterm-color", cols: 80, rows: 24 });
child.onData((data) => process.stdout.write(data));
child.onExit(({ exitCode }) => process.exit(exitCode === 0 ? 0 : 1));
' >"$pty_log" 2>&1; then
  cat "$pty_log"
  exit 1
fi
grep -q "pty-ok" "$pty_log" || {
  cat "$pty_log"
  exit 1
}
log "node-pty spawned /bin/sh over a pty"

log "Server smoke test"
export T3CODE_HOST=127.0.0.1
export T3CODE_PORT="${SMOKE_PORT:-3773}"
export T3CODE_NO_BROWSER=1
export T3CODE_HOME=/tmp/t3-smoke-home
export T3CODE_AUTH_PASSWORD="${SMOKE_PASSWORD}"
rm -rf "$T3CODE_HOME"
node bin.mjs >/tmp/t3-server.log 2>&1 &
server_pid=$!
stop_server() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap stop_server EXIT

attempt=0
while ! node /work/probe.mjs wait 2>/dev/null; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "server exited before becoming ready" >&2
    cat /tmp/t3-server.log
    exit 1
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 120 ]; then
    echo "server did not become ready" >&2
    cat /tmp/t3-server.log
    exit 1
  fi
  sleep 1
done
node /work/probe.mjs login
stop_server
trap - EXIT

log "Writing manifest"
node -e '
const fs = require("node:fs");
const plan = JSON.parse(fs.readFileSync("/work/plan.json", "utf8"));
const manifest = {
  version: plan.version,
  arch: plan.arch,
  libc: "musl",
  nodeEngine: plan.nodeEngine,
  builtWith: `node ${process.version} on alpine:${fs.readFileSync("/etc/alpine-release", "utf8").trim()}`,
  start: "node bin.mjs",
  dependencies: plan.dependencies,
};
fs.writeFileSync("/work/build/ANDROID-BUNDLE.json", JSON.stringify(manifest, null, 2) + "\n");
'

cd /
mv "$build" "/work/stage/${BUNDLE_STEM}"
tar --hard-dereference -czf "/work/out/${BUNDLE_STEM}.tar.gz" -C /work/stage "$BUNDLE_STEM"
chown -R "${HOST_UID}:${HOST_GID}" /work/out /work/stage
log "Wrote /work/out/${BUNDLE_STEM}.tar.gz"
IN_ALPINE

log "Building ${stem} in ${image} (${docker_platform})"
docker run --rm \
  --platform "$docker_platform" \
  -e "BUNDLE_VERSION=$version" \
  -e "BUNDLE_ARCH=$arch" \
  -e "BUNDLE_STEM=$stem" \
  -e "SMOKE_PORT=3773" \
  -e "SMOKE_PASSWORD=testpassword123" \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
  -v "$work":/work \
  -v "$REPO_ROOT":/repo:ro \
  -v "$dist":/input/dist:ro \
  -w /work \
  "$image" /bin/sh /work/in-alpine.sh

tarball="$work/out/${stem}.tar.gz"
[[ -f "$tarball" ]] || die "the build did not produce $stem.tar.gz"
cp "$tarball" "$output_dir/${stem}.tar.gz"

log "Archive: $output_dir/${stem}.tar.gz"
ls -lh "$output_dir/${stem}.tar.gz"
sha256sum "$output_dir/${stem}.tar.gz"
