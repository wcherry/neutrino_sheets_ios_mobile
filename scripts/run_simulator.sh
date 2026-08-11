#!/usr/bin/env bash
#
# Build, install, and launch Neutrino Sheets in an iOS Simulator.
#
#   scripts/run_simulator.sh                        # iPhone 17 Pro, latest OS, Debug
#   scripts/run_simulator.sh --device "iPad Pro 13-inch (M4)"
#   scripts/run_simulator.sh --os 18.0 --release
#   scripts/run_simulator.sh --console              # stream the app's stdout/stderr
#   scripts/run_simulator.sh --reset --screenshot   # fresh install, then a PNG
#
# The bundle id and scheme come from project.yml, which stays the source of
# truth exactly as it is for scripts/deploy_testflight.sh.
#
# Flags:
#   --device NAME     simulator to use (default: iPhone 17 Pro)
#   --os VERSION      runtime version, e.g. 18.0 (default: newest installed)
#   --release         build the Release configuration instead of Debug
#   --clean           clean the build directory first
#   --no-build        install and launch whatever was built last
#   --no-generate     skip xcodegen (use the .xcodeproj as it is on disk)
#   --reset           erase the simulator before installing — wipes the Keychain
#                     and UserDefaults, so the app comes up at a signed-out first
#                     launch. This is the only way to retest login and key import
#   --uninstall       remove the app first, keeping the rest of the simulator
#   --console         attach to the app's output and stay in the foreground
#   --screenshot[=P]  write a PNG after launch (default: build/screenshot.png)

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCHEME="NeutrinoSheets"
readonly PROJECT="NeutrinoSheets.xcodeproj"
readonly BUILD_DIR="$PROJECT_ROOT/build"

DEVICE_NAME="iPhone 17 Pro"
OS_VERSION=""
CONFIGURATION="Debug"
DO_BUILD=1
DO_GENERATE=1
DO_CLEAN=0
DO_RESET=0
DO_UNINSTALL=0
DO_CONSOLE=0
SCREENSHOT_PATH=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- arguments ---------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)       DEVICE_NAME="${2:-}"; [[ -n "$DEVICE_NAME" ]] || die "--device needs a name"; shift 2 ;;
    --device=*)     DEVICE_NAME="${1#*=}"; shift ;;
    --os)           OS_VERSION="${2:-}"; [[ -n "$OS_VERSION" ]] || die "--os needs a version"; shift 2 ;;
    --os=*)         OS_VERSION="${1#*=}"; shift ;;
    --release)      CONFIGURATION="Release"; shift ;;
    --clean)        DO_CLEAN=1; shift ;;
    --no-build)     DO_BUILD=0; shift ;;
    --no-generate)  DO_GENERATE=0; shift ;;
    --reset)        DO_RESET=1; shift ;;
    --uninstall)    DO_UNINSTALL=1; shift ;;
    --console)      DO_CONSOLE=1; shift ;;
    --screenshot)   SCREENSHOT_PATH="$BUILD_DIR/screenshot.png"; shift ;;
    --screenshot=*) SCREENSHOT_PATH="${1#*=}"; shift ;;
    -h|--help)      sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

cd "$PROJECT_ROOT"

# --console replaces this process with the launch, so anything after it never
# runs. Said out loud rather than silently dropping the screenshot.
if [[ $DO_CONSOLE -eq 1 && -n "$SCREENSHOT_PATH" ]]; then
  die "--console and --screenshot cannot be combined: --console hands the terminal to the app
  and never returns. Run once with --screenshot, then again with --console --no-build."
fi

# --- preflight ---------------------------------------------------------------

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode"
command -v xcrun >/dev/null      || die "xcrun not found — install Xcode"
[[ $DO_GENERATE -eq 1 ]] && { command -v xcodegen >/dev/null || die "xcodegen not found — brew install xcodegen"; }

# The bundle id is read rather than hard-coded: project.yml is what actually
# decides it, and a copy here would be one more thing to forget when it changes.
BUNDLE_ID="$(awk -F': ' '/PRODUCT_BUNDLE_IDENTIFIER:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' project.yml)"
[[ -n "$BUNDLE_ID" ]] || die "could not read PRODUCT_BUNDLE_IDENTIFIER from project.yml"

# --- device ------------------------------------------------------------------

# Resolves a simulator name to a UDID.
#
# `simctl list` groups devices under `-- iOS 26.0 --` runtime headers, so the
# runtime has to be tracked while scanning rather than read off the device line.
# Names are matched *exactly*: a prefix match would resolve "iPhone 17 Pro" to
# "iPhone 17 Pro Max" whenever the plain model happened to be listed second.
find_device() {
  local want_name="$1" want_os="$2"
  xcrun simctl list devices available | awk -v want_name="$want_name" -v want_os="$want_os" '
    /^-- / {
      runtime = $0
      gsub(/^-- | --$/, "", runtime)
      next
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      # "Name (UDID) (State)" — split off the trailing two parenthesised fields.
      if (match(line, /\([0-9A-Fa-f-]{36}\)/) == 0) next
      udid = substr(line, RSTART + 1, RLENGTH - 2)
      name = substr(line, 1, RSTART - 2)
      sub(/[[:space:]]+$/, "", name)
      if (name != want_name) next
      if (runtime !~ /^iOS/) next
      if (want_os != "" && runtime != "iOS " want_os) next
      print udid
    }
  ' | tail -1
}

UDID="$(find_device "$DEVICE_NAME" "$OS_VERSION")"

if [[ -z "$UDID" ]]; then
  warn "no available simulator named \"$DEVICE_NAME\"${OS_VERSION:+ on iOS $OS_VERSION}"
  printf 'Available iOS simulators:\n' >&2
  xcrun simctl list devices available | sed -n '/^-- iOS/,/^-- [^i]/p' | grep -E '^\s+\S' >&2 || true
  die "pick one with --device, or create it in Xcode > Window > Devices and Simulators"
fi

log "Simulator: $DEVICE_NAME ($UDID)"

# --- generate & build --------------------------------------------------------

if [[ $DO_GENERATE -eq 1 ]]; then
  log "Regenerating $PROJECT from project.yml"
  xcodegen generate
fi

[[ -d "$PROJECT" ]] || die "$PROJECT not found — run without --no-generate, or run xcodegen"

if [[ $DO_CLEAN -eq 1 ]]; then
  log "Cleaning $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi

if [[ $DO_BUILD -eq 1 ]]; then
  log "Building $SCHEME ($CONFIGURATION) for the simulator"
  mkdir -p "$BUILD_DIR"
  # `id=` rather than `name=` so the build targets the same simulator that is
  # about to run it, even when two runtimes offer the same device name.
  #
  # The full transcript goes to a log and only the interesting lines to the
  # terminal. No `|| true` on the end: it would run in place of the failing
  # pipeline and reset PIPESTATUS to 0, hiding a broken build behind a launch
  # of the previous binary. `set +e` is what keeps grep's empty-match exit from
  # ending the script instead.
  set +e
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "id=$UDID" \
    -derivedDataPath "$BUILD_DIR" \
    2>&1 | tee "$BUILD_DIR/xcodebuild.log" | grep -E "error:|warning:.*\.swift|BUILD"
  build_status="${PIPESTATUS[0]}"
  set -e
  [[ "$build_status" -eq 0 ]] || die "build failed — full output in ${BUILD_DIR#$PROJECT_ROOT/}/xcodebuild.log"
fi

# --- locate the .app ---------------------------------------------------------

APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION-iphonesimulator/$SCHEME.app"
if [[ ! -d "$APP_PATH" ]]; then
  # A custom SYMROOT or a stale layout — ask the build system rather than guess.
  APP_PATH="$(find "$BUILD_DIR/Build/Products" -maxdepth 2 -name "$SCHEME.app" -type d 2>/dev/null | head -1)"
fi
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || die "$SCHEME.app not found — build first (drop --no-build)"

log "App: ${APP_PATH#$PROJECT_ROOT/}"

# --- boot --------------------------------------------------------------------

if [[ $DO_RESET -eq 1 ]]; then
  # Erasing takes the Keychain and UserDefaults with it, which is the point:
  # the signed-in session and the imported encryption key both survive a plain
  # reinstall, so this is the only way to see a true first launch.
  log "Erasing the simulator (signs out, and removes the imported encryption key)"
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  xcrun simctl erase "$UDID"
fi

log "Booting"
xcrun simctl boot "$UDID" 2>/dev/null || true
# Waits for the device to finish booting rather than sleeping and hoping; an
# install issued against a half-booted device fails intermittently.
xcrun simctl bootstatus "$UDID" -b >/dev/null

open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null || warn "could not bring Simulator.app to the front"

# --- install & launch --------------------------------------------------------

if [[ $DO_UNINSTALL -eq 1 ]]; then
  log "Uninstalling $BUNDLE_ID"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
fi

log "Installing $BUNDLE_ID"
xcrun simctl install "$UDID" "$APP_PATH"

# A running copy would otherwise keep the old binary until it was killed.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

if [[ $DO_CONSOLE -eq 1 ]]; then
  log "Launching (attached — Ctrl-C to detach; the app keeps running)"
  # --console-pty forwards stdout/stderr and stays in the foreground. Note this
  # shows print()/NSLog only: the app's own diagnostics go through os.log, which
  # is read with `xcrun simctl spawn $UDID log stream --predicate ...`.
  exec xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID"
fi

log "Launching"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

if [[ -n "$SCREENSHOT_PATH" ]]; then
  mkdir -p "$(dirname "$SCREENSHOT_PATH")"
  # A moment for the first frame; a screenshot taken the instant after launch
  # catches the launch screen rather than the app.
  sleep 3
  xcrun simctl io "$UDID" screenshot "$SCREENSHOT_PATH" >/dev/null 2>&1
  log "Screenshot: ${SCREENSHOT_PATH#$PROJECT_ROOT/}"
fi

log "Running — $SCHEME ($CONFIGURATION) on $DEVICE_NAME"
printf '\n  Logs:      xcrun simctl spawn %s log stream --predicate '"'"'subsystem == "%s"'"'"'\n' "$UDID" "$BUNDLE_ID"
printf '  Stop:      xcrun simctl terminate %s %s\n\n' "$UDID" "$BUNDLE_ID"
