#!/bin/bash
# muguet - build.sh
# Constantin Clerc (c22dev) - 0.1

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /)"
if [ ! -f "$HERE/make-app.sh" ]; then
  HERE=/tmp/v4mac
  printf '\nDownloading V4Mac into %s\n' "$HERE"
  mkdir -p "$HERE"
  curl -fsSL https://github.com/Arjun941/V4Mac/archive/refs/heads/v4mac.tar.gz | tar -xz -C "$HERE" --strip-components 1
  exec /bin/bash "$HERE/build.sh"
fi
cd "$HERE"

OUT="$HOME/Downloads/V4MacOutput"
SAVED=build/.choices

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ask() {
  local answer
  read -r -e -p "$1 [$2]: " answer || exit 1
  answer="$(printf '%s' "$answer" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  REPLY="${answer:-$2}"
}
pick() {
  local prompt="$1"; shift
  bold "$prompt"
  PS3="Choose 1-$#: "
  select choice in "$@"; do
    [ -n "${choice:-}" ] && return
    echo "Type a number between 1 and $#."
  done
  exit 1
}
clean_path() {
  local p="$1"
  p="${p#\'}"; p="${p%\'}"; p="${p#\"}"; p="${p%\"}"
  p="${p//\\ / }"
  p="${p/#\~/$HOME}"
  printf '%s' "$p"
}
game_zip() { [ -f "$1" ] && unzip -Z1 "$1" 2>/dev/null | grep -E '(^|/)b/[^/]+/game\.wasm$' >/dev/null; }
xcode_teams() {
  defaults export com.apple.dt.Xcode - 2>/dev/null | /usr/bin/python3 -I -c '
import plistlib, sys
try: d = plistlib.loads(sys.stdin.buffer.read())
except Exception: sys.exit()
seen = set()
for teams in d.get("IDEProvisioningTeamByIdentifier", {}).values():
    for t in teams:
        if t.get("teamID") and t["teamID"] not in seen:
            seen.add(t["teamID"])
            print("%s\t%d\t%s" % (t["teamID"], bool(t.get("isFreeProvisioningTeam")), t.get("teamName", t["teamID"])))
' || true
}
run() {
  mkdir -p build
  if "$@" 2>&1 | tee build/build.log; then return; fi
  explain
}
explain() {
  local log=build/build.log hint=""
  if grep -E "No Account for Team|No signing certificate|No profiles for|requires a provisioning profile" "$log" >/dev/null; then
    hint="Xcode couldn't sign the app. Open Xcode > Settings > Accounts, check you're signed in with your Apple ID, then run this again."
  elif grep -E "maximum number of apps|App ID limit" "$log" >/dev/null; then
    hint="Free Apple IDs can only have a few sideloaded apps at once. Delete one from your device, wait a bit, then run this again."
  elif grep -E "Failed to register bundle identifier|is not available|cannot be registered" "$log" >/dev/null; then
    hint="That app identifier is already taken. Run this again with your own one, like: BUNDLE_ID=com.yourname.v4mac ./build.sh"
  elif grep -E "No space left on device" "$log" >/dev/null; then
    hint="Your Mac ran out of disk space. Free up at least 15 GB, then run this again."
  elif grep -iE "device is locked|passcode" "$log" >/dev/null; then
    hint="Your device is locked. Unlock it, keep it unlocked, then run this again."
  elif grep -E "Developer Mode" "$log" >/dev/null; then
    hint="Turn on Settings > Privacy & Security > Developer Mode on your device, restart it, then run this again."
  elif grep -E "untrusted|not trusted|ApplicationVerificationFailed" "$log" >/dev/null; then
    hint="Unlock your device and tap Trust when it asks to trust this Mac, then run this again."
  fi
  printf '\n\033[31mThe build failed.\033[0m\n'
  if [ -n "$hint" ]; then echo "$hint"; else echo "Last lines of the log:"; tail -15 "$log"; fi
  echo "Full log: $PWD/$log"
  exit 1
}
remember() { mkdir -p build; echo "LAST_ZIP=$(printf '%q' "$ZIP")" > "$SAVED"; }

[ "$(uname -s)" = Darwin ] || fail "V4Mac builds on macOS only."
[ "$(uname -m)" = arm64 ] || fail "V4Mac needs an Apple Silicon Mac (M1 or newer)."

bold "Checking Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
  [ -n "$XCODE" ] || fail "Install Xcode from the App Store (Xcode 26 or later), open it once, then run this again."
  echo "Xcode is installed but not selected. Selecting it (asks for your Mac password):"
  sudo xcode-select -s "$XCODE/Contents/Developer"
fi
XCODE_MAJOR="$(xcodebuild -version | awk '/^Xcode/ {split($2, v, "."); print v[1]}')"
[ "${XCODE_MAJOR:-0}" -ge 26 ] || fail "Xcode $XCODE_MAJOR is too old: update Xcode to 26 or later from the App Store."
if ! xcodebuild -license check >/dev/null 2>&1; then
  echo "Accepting the Xcode license (asks for your Mac password):"
  sudo xcodebuild -license accept
fi
xcodebuild -version | head -1

bold "Checking Homebrew"
if ! command -v brew >/dev/null; then
  [ -x /opt/homebrew/bin/brew ] || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
brew --version | head -1
for tool in cmake:cmake; do
  command -v "${tool%%:*}" >/dev/null || { bold "Installing ${tool##*:}"; brew install "${tool##*:}"; }
done

bold "Checking Rust"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
if ! command -v rustup >/dev/null; then
  brew install rustup
  hash -r
fi
rustup toolchain list | grep '^stable' >/dev/null || rustup toolchain install stable --profile minimal
rustup default >/dev/null 2>&1 || rustup default stable
cargo --version

bold "Downloading Rust dependencies"
cargo fetch --locked
bold "Building V4Mac (a few minutes the first time)"
run ./make-app.sh
mkdir -p "$OUT"
rm -rf "$OUT/V4Mac.app"
ditto build/V4Mac.app "$OUT/V4Mac.app"
bold "Done: $OUT/V4Mac.app"
echo "Showing it in Finder: open it, then import your game .zip."
open -R "$OUT/V4Mac.app"

