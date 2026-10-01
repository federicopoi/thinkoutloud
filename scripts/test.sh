#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# CLT ships Swift Testing but leaves its Foundation overlay empty. This flag
# disables that optional overlay. Full Xcode installations need no flags.
if [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
    swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
else
    swift test
fi
