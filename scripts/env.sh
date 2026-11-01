#!/bin/zsh
# Options communes : avec les seules Command Line Tools, les plugins de macros
# SwiftUI (@State) et Swift Testing (@Test) doivent être chargés explicitement.
ROOT="${0:A:h:h}"
SWIFT_FLAGS=()
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  SWIFTUI_PLUGIN="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
  TESTING_PLUGIN="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  for p in "$SWIFTUI_PLUGIN" "$TESTING_PLUGIN"; do
    [[ -f "$p" ]] && SWIFT_FLAGS+=(-Xswiftc -load-plugin-library -Xswiftc "$p")
  done
fi
