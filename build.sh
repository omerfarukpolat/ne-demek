#!/bin/zsh
# NeDemek.app'i derler, ~/Applications altına kurar ve başlatır.
set -e
cd "${0:A:h}"
APP="$HOME/Applications/NeDemek.app"
BUILD="$(mktemp -d)"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" main.swift -o "$BUILD/NeDemek" -framework AppKit

pkill -x NeDemek 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BUILD/NeDemek" "$APP/Contents/MacOS/NeDemek"
codesign --force --sign - "$APP"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
/System/Library/CoreServices/pbs -update
open "$APP"
echo "Kuruldu: $APP"
