#!/bin/sh
# tools/publish.sh <libs-dir> [message]: commits each library of <libs-dir>
# (tools/libs.sh's) to its repository, github.com/hx-objc/<library>, and pushes.
set -e
libs=${1:?usage: tools/publish.sh <libs-dir> [message]}
libs=$(cd "$libs" && pwd)
work=$(mktemp -d)
for dir in "$libs"/*/; do
	lib=$(basename "$dir")
	msg=${2:-"Regenerated: $(sed -n 's/.*"releasenote": "From \(.*\)\.".*/\1/p' "$dir/haxelib.json")"}
	git clone -q "https://github.com/hx-objc/$lib.git" "$work/$lib"
	(
		cd "$work/$lib"
		git rm -rq --ignore-unmatch . > /dev/null
		cp -R "$dir/." .
		git add -A
		if git diff --cached --quiet; then echo "$lib: unchanged"; else git commit -qm "$msg" && git push -q origin HEAD:main && echo "$lib: pushed"; fi
	)
done
rm -rf "$work"
