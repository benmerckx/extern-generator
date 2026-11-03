#!/bin/sh
# tools/libs.sh <out-dir>: the externs of the whole SDKs, for macOS, iOS and Mac
# Catalyst (<out-dir>/<platform>), and the libraries they make (<out-dir>/libs).
# With HXMC set (an hxmc that has the Objective-C interop), each platform's
# output is type-checked too.
set -e
out=${1:-out/sdk}
here=$(cd "$(dirname "$0")/.." && pwd)
gen="$here/bin/objc-extern-gen"
ulimit -s unlimited 2>/dev/null || true
mkdir -p "$out"
pids=""
for p in macos ios maccatalyst; do
	rm -rf "$out/$p"
	"$gen" "$out/$p" --platform $p --frameworks all --check > "$out/$p.log" 2>&1 &
	pids="$pids $!"
done
for pid in $pids; do wait $pid || { echo "failed: see $out/*.log"; exit 1; }; done
if [ -n "$HXMC" ]; then
	for p in macos ios maccatalyst; do
		case $p in macos) t=macos-arm64;; ios) t=ios-arm64;; *) t=macos-catalyst-arm64;; esac
		"$HXMC" -D hxmc.target=$t -cp "$out/$p" -main ObjcExternsCheck --no-output > "$out/$p.check" 2>&1 \
			|| { echo "$p: type errors, see $out/$p.check"; exit 1; }
		echo "$p: type-checked"
	done
fi
versions="Xcode $(xcodebuild -version | head -1 | awk '{print $2}'), macOS SDK $(xcrun --sdk macosx --show-sdk-version), iOS SDK $(xcrun --sdk iphoneos --show-sdk-version)"
"$gen" slice "$out/libs" "$out/macos" "$out/ios" "$out/maccatalyst" --sdk-versions "$versions"
