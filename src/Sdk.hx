using StringTools;

// What the generator reads from an SDK besides the headers: where its
// frameworks are, which of them a platform links (their .tbd files), which
// sub-frameworks an umbrella re-exports, and which frameworks import (the
// whole SDK's scope, --frameworks all).
class Sdk {
	public var path:String;
	public var platform:String;

	public function new(path, platform) {
		this.path = path;
		this.platform = platform;
	}

	public static function locate(platform:String):String {
		var p = new sys.io.Process("xcrun", ["--sdk", platform == "ios" ? "iphoneos" : "macosx", "--show-sdk-path"]);
		var s = p.stdout.readAll().toString().trim();
		p.close();
		return s;
	}

	// clang's flags for the platform (iOS: the device's, arm64; Mac Catalyst:
	// the macOS SDK with its iOS frameworks, /System/iOSSupport)
	public function clangFlags():String
		return switch platform {
			case "ios": ' -target arm64-apple-ios17.0 -isysroot $path';
			case "maccatalyst": ' -target arm64-apple-ios17.0-macabi -isysroot $path -iframework $path/System/iOSSupport/System/Library/Frameworks -isystem $path/System/iOSSupport/usr/include';
			case _: ' -isysroot $path';
		}

	// the directories of frameworks, in the order clang searches them
	public function frameworkDirs():Array<String> {
		var dirs = ['$path/System/Library/Frameworks'];
		if (platform == "maccatalyst") dirs.unshift('$path/System/iOSSupport/System/Library/Frameworks');
		return dirs;
	}

	static function isDir(p:String)
		return sys.FileSystem.exists(p) && sys.FileSystem.isDirectory(p);

	// a framework's .tbd: the one clang's search finds first
	function tbd(dir:String, name:String):Null<String> {
		for (p in ['$dir/$name.framework/$name.tbd', '$dir/$name.framework/Versions/A/$name.tbd'])
			if (sys.FileSystem.exists(p)) return p;
		return null;
	}

	function tbdOf(name:String):Null<String> {
		for (d in frameworkDirs())
			if (isDir('$d/$name.framework')) return tbd(d, name);
		return null;
	}

	// whether the platform links the framework: its .tbd names a target of
	// the platform (a framework without one, linked through another's, is
	// taken as linked)
	public function links(name:String):Bool {
		var t = tbdOf(name);
		if (t == null) return true;
		var targets = ~/[a-z0-9_.]+-(macos|ios|maccatalyst)(-simulator)?\b/g;
		var text = sys.io.File.getContent(t), found = false;
		var pos = 0;
		while (targets.matchSub(text, pos)) {
			var p = targets.matchedPos();
			pos = p.pos + p.len;
			if (targets.matched(2) == null && targets.matched(1) == platform) return true;
			found = true;
		}
		return !found;
	}

	// the sub-frameworks (/System/Library/SubFrameworks) an umbrella
	// re-exports, by name: the umbrella's (ARKitCore: ARKit). Its declarations
	// are the umbrella's, linked through it, as on a platform where the
	// umbrella has them itself (Mac Catalyst's ARKit)
	public function reexports():Map<String, String> {
		var m = new Map<String, String>();
		var r = ~/\/SubFrameworks\/([A-Za-z0-9_]+)\.framework\//g;
		for (d in frameworkDirs()) {
			if (!isDir(d)) continue;
			for (f in sys.FileSystem.readDirectory(d)) {
				if (!f.endsWith(".framework")) continue;
				var name = f.substr(0, f.length - ".framework".length), t = tbd(d, name);
				if (t == null) continue;
				var text = sys.io.File.getContent(t);
				var i = text.indexOf("reexported-libraries:");
				if (i < 0) continue;
				// (the section ends where the exports begin)
				var end = text.indexOf("exports:", i);
				var sec = text.substring(i, end < 0 ? text.length : end), pos = 0;
				while (r.matchSub(sec, pos)) {
					var p = r.matchedPos();
					pos = p.pos + p.len;
					if (!m.exists(r.matched(1))) m.set(r.matched(1), name);
				}
			}
		}
		return m;
	}

	// frameworks that never import together with the others (Kerberos
	// redefines GSS's types), or that a platform does not support (AppKit on
	// Mac Catalyst: its .tbd lists the platform, but apps cannot use it)
	static final CONFLICTS = ["Kerberos"];
	static final UNSUPPORTED = ["maccatalyst" => ["AppKit", "Cocoa"]];
	// imported first: CoreHaptics before AVFAudio, whose AVAudioSession is
	// then unavailable to it; NetworkExtension before AccessorySetupKit (Mac
	// Catalyst: ASAccessory)
	static final FIRST = ["CoreHaptics", "NetworkExtension"];

	// the whole SDK: every framework with an umbrella header that imports on
	// its own and that the platform links, the frameworks inside them
	// (CarbonCore in CoreServices), the sub-frameworks no umbrella re-exports,
	// and libSystem's dispatch, os and xpc
	public function allFrameworks(tmp:String):Array<String> {
		var umbrellas = [], seen = new Map<String, Bool>();
		var unsupported = UNSUPPORTED.exists(platform) ? UNSUPPORTED.get(platform) : [];
		for (d in frameworkDirs()) {
			if (!isDir(d)) continue;
			for (f in sys.FileSystem.readDirectory(d)) {
				if (!f.endsWith(".framework")) continue;
				var name = f.substr(0, f.length - ".framework".length);
				if (seen.exists(name) || CONFLICTS.contains(name) || unsupported.contains(name)) continue;
				seen.set(name, true);
				if (sys.FileSystem.exists('$d/$f/Headers/$name.h') && links(name)) umbrellas.push(name);
			}
		}
		umbrellas.sort(Reflect.compare);
		// each on its own (in parallel: a few hundred clang runs)
		var dir = tmp + "/imports";
		sys.FileSystem.createDirectory(dir);
		for (u in umbrellas)
			sys.io.File.saveContent('$dir/$u.m', '#import <$u/$u.h>\n');
		sys.io.File.saveContent('$dir/list', umbrellas.join("\n") + "\n");
		// (a script: BSD xargs -I limits the command's length)
		sys.io.File.saveContent('$dir/import.sh', 'clang -fsyntax-only -x objective-c${clangFlags()} "$$1.m" > "$$1.log" 2>&1 && touch "$$1.ok"\n');
		Sys.command("/bin/sh", ["-c", 'cd $dir && xargs -P 8 -n 1 sh import.sh < list']);
		var ok = [for (u in umbrellas) if (sys.FileSystem.exists('$dir/$u.ok')) u];
		var failed = [for (u in umbrellas) if (!ok.contains(u)) u];
		if (failed.length > 0) Sys.println('frameworks that do not import on their own (left out): ${failed.join(" ")}');
		var scope = [for (f in FIRST) if (ok.contains(f)) f].concat([for (u in ok) if (!FIRST.contains(u)) u]);
		// the frameworks inside them
		for (d in frameworkDirs())
			for (u in ok)
				for (inner in ['$d/$u.framework/Frameworks', '$d/$u.framework/Versions/A/Frameworks'])
					if (isDir(inner))
						for (f in sys.FileSystem.readDirectory(inner)) {
							var name = f.substr(0, f.length - ".framework".length);
							if (f.endsWith(".framework") && isDir('$inner/$f/Headers') && !scope.contains(name)) scope.push(name);
						}
		// the sub-frameworks no umbrella re-exports
		var re = reexports(), subs = '$path/System/Library/SubFrameworks';
		if (platform != "maccatalyst" && isDir(subs))
			for (f in sys.FileSystem.readDirectory(subs)) {
				var name = f.substr(0, f.length - ".framework".length);
				if (f.endsWith(".framework") && !re.exists(name) && sys.FileSystem.exists('$subs/$f/Headers/$name.h') && !scope.contains(name))
					scope.push(name);
			}
		for (f in ["dispatch", "os", "xpc"])
			scope.push(f);
		return scope;
	}
}
