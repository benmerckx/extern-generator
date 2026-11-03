using StringTools;

// `objc-extern-gen slice`: splits the macOS, iOS and Mac Catalyst outputs
// into libraries, each module into the one of the platforms where its text is
// the same:
//
//   apple-shared        all three
//   apple-shared-uikit  iOS and Mac Catalyst (UIKit, and the iOS frameworks)
//   apple-shared-mac    macOS and Mac Catalyst
//   apple-appkit        macOS only (with what macOS and iOS share alone: a
//                       hundred-odd modules, copied into apple-uikit too)
//   apple-uikit         iOS only
//   apple-catalyst      Mac Catalyst only
//   apple-appkit-legacy macOS only, out of apple-appkit: frameworks that are
//                       gone in all but name (OpenGL, QuickDraw, Tcl, ...) and
//                       classes deprecated as a whole
//   apple-matter        Matter, on every platform: the SDKs' largest framework,
//                       which apps rarely use
//
// A platform's libraries (apple-appkit, apple-uikit or apple-catalyst, with
// the shared ones they depend on) have each type once: together they are the
// platform's output. A library refers to types of the others by their paths
// (Haxe's), declaring no dependency on them: one used without them fails
// where such a type is used (HomeKit's HMAccessorySetupRequest without
// apple-matter).
class Slice {
	static final PLATFORMS = ["macos", "ios", "maccatalyst"];
	static final SIDE = ["matter" => "apple-matter"];
	static final LEGACY = [
		"calendarstore", "directoryservice", "discrecording", "discrecordingui", "dvdplayback", "glut", "javaruntimesupport", "opengl", "qd",
		"quartzcomposer", "ruby", "speechsynthesis", "syncservices", "tcl", "twain"
	];
	static final ORG = "https://github.com/hx-objc/";

	// the libraries: their platforms, dependencies and description
	static final LIBS:Array<{name:String, platforms:Array<String>, deps:Array<String>, about:String}> = [
		{name: "apple-shared", platforms: ["macos", "ios", "maccatalyst"], deps: [], about: "the declarations macOS, iOS and Mac Catalyst share"},
		{name: "apple-shared-uikit", platforms: ["ios", "maccatalyst"], deps: [], about: "the declarations iOS and Mac Catalyst share (UIKit and most iOS frameworks)"},
		{name: "apple-shared-mac", platforms: ["macos", "maccatalyst"], deps: [], about: "the declarations macOS and Mac Catalyst share"},
		{name: "apple-appkit", platforms: ["macos"], deps: ["apple-shared", "apple-shared-mac"], about: "macOS: AppKit and every macOS API"},
		{name: "apple-appkit-legacy", platforms: ["macos"], deps: ["apple-appkit"], about: "macOS's legacy APIs: OpenGL, QuickDraw, Tcl, Ruby and other frameworks gone in all but name, and classes deprecated as a whole"},
		{name: "apple-uikit", platforms: ["ios"], deps: ["apple-shared", "apple-shared-uikit"], about: "iOS: UIKit and every iOS API"},
		{name: "apple-catalyst", platforms: ["maccatalyst"], deps: ["apple-shared", "apple-shared-uikit", "apple-shared-mac"], about: "Mac Catalyst: UIKit on macOS, and every Mac Catalyst API"},
		{name: "apple-matter", platforms: ["macos", "ios", "maccatalyst"], deps: [], about: "Matter (smart home accessories), on every platform"},
	];

	static function modules(dir:String):Map<String, String> {
		var m = new Map<String, String>();
		for (p in sys.FileSystem.readDirectory(dir)) {
			var d = '$dir/$p';
			if (p.startsWith(".") || !sys.FileSystem.isDirectory(d)) continue;
			for (f in sys.FileSystem.readDirectory(d))
				if (f.endsWith(".hx")) m.set('$p/$f', sys.io.File.getContent('$d/$f'));
		}
		return m;
	}

	// a module whose type is deprecated as a whole
	static function deprecated(src:String):Bool {
		for (l in src.split("\n"))
			if (l.startsWith("@") && ~/\b(extern|abstract|enum|class|interface|typedef)\b/.match(l)) return l.indexOf("@:deprecated") >= 0;
		return false;
	}

	// the modules a module refers to: its imports, and its package's types it names
	static function refs(k:String, text:String, all:Map<String, String>):Array<String> {
		var r = [], pkg = k.split("/")[0];
		var imp = ~/^import ([a-z0-9_]+)\.([A-Za-z0-9_]+);/gm, pos = 0;
		while (imp.matchSub(text, pos)) {
			var p = imp.matchedPos();
			pos = p.pos + p.len;
			r.push(imp.matched(1) + "/" + imp.matched(2) + ".hx");
		}
		var id = ~/\b[A-Z][A-Za-z0-9_]*\b/g;
		pos = 0;
		var seen = new Map<String, Bool>();
		while (id.matchSub(text, pos)) {
			var p = id.matchedPos();
			pos = p.pos + p.len;
			var m = pkg + "/" + id.matched(0) + ".hx";
			if (!seen.exists(m) && m != k && all.exists(m)) r.push(m);
			seen.set(m, true);
		}
		return r;
	}

	// macOS's legacy modules (its own, the others share none): the frameworks of
	// LEGACY and the types deprecated as a whole, but those the rest of macOS
	// refers to, directly or through others (NSWindowBackingLocation, which
	// NSWindow names: a class names its fields' types, which Haxe resolves with it)
	static function legacyOf(macos:Map<String, String>, own:String->Bool):Map<String, Bool> {
		var legacy = new Map<String, Bool>();
		for (k => t in macos)
			if (own(k) && (LEGACY.contains(k.split("/")[0]) || deprecated(t))) legacy.set(k, true);
		var stack = [for (k in macos.keys()) if (!legacy.exists(k)) k];
		var kept = new Map<String, Bool>();
		while (stack.length > 0) {
			var k = stack.pop();
			for (m in refs(k, macos.get(k), macos))
				if (legacy.exists(m)) {
					legacy.remove(m);
					kept.set(m, true);
					stack.push(m);
				}
		}
		return legacy;
	}

	public static function run(args:Array<String>) {
		var dirs = [], versions = "";
		var i = 0;
		while (i < args.length) {
			if (args[i] == "--sdk-versions") versions = args[++i] else dirs.push(args[i]);
			i++;
		}
		if (dirs.length != 4) {
			Sys.println("usage: objc-extern-gen slice <out-dir> <macos-dir> <ios-dir> <maccatalyst-dir> [--sdk-versions text]");
			Sys.exit(1);
		}
		var out = dirs[0];
		var mods = [for (k in 0...3) PLATFORMS[k] => modules(dirs[k + 1])];
		var keys = new Map<String, Bool>();
		for (p in PLATFORMS)
			for (k in mods.get(p).keys())
				keys.set(k, true);
		var files = new Map<String, Map<String, String>>(); // library -> path -> text
		function put(lib:String, k:String, text:String) {
			if (!files.exists(lib)) files.set(lib, new Map());
			files.get(lib).set(k, text);
		}
		var sorted = [for (k in keys.keys()) k];
		sorted.sort(Reflect.compare);
		var legacy = legacyOf(mods.get("macos"), k -> {
			var t = mods.get("macos").get(k);
			mods.get("ios").get(k) != t && mods.get("maccatalyst").get(k) != t;
		});
		var conflicts = [];
		for (k in sorted) {
			// the platforms by the module's text
			var groups:Array<{text:String, ps:Array<String>}> = [];
			for (p in PLATFORMS) {
				var t = mods.get(p).get(k);
				if (t == null) continue;
				var g = Lambda.find(groups, g -> g.text == t);
				if (g != null) g.ps.push(p) else groups.push({text: t, ps: [p]});
			}
			var pkg = k.split("/")[0];
			if (SIDE.exists(pkg)) {
				// one library for all: the text most platforms have
				var best = groups[0];
				for (g in groups)
					if (g.ps.length > best.ps.length) best = g;
				if (groups.length > 1) conflicts.push('$k: ${best.ps.join(", ")}\'s');
				put(SIDE.get(pkg), k, best.text);
				continue;
			}
			for (g in groups) {
				var libs = switch g.ps.join(",") {
					case "macos,ios,maccatalyst": ["apple-shared"];
					case "ios,maccatalyst": ["apple-shared-uikit"];
					case "macos,maccatalyst": ["apple-shared-mac"];
					case "macos,ios": ["apple-appkit", "apple-uikit"];
					case "macos": ["apple-appkit"];
					case "ios": ["apple-uikit"];
					case _: ["apple-catalyst"];
				}
				for (lib in libs)
					put(lib == "apple-appkit" && legacy.exists(k) ? "apple-appkit-legacy" : lib, k, g.text);
			}
		}
		if (conflicts.length > 0) Sys.println('side libraries, modules that differ by platform (the version used): ${conflicts.join("; ")}');
		Main.removeTree(out);
		var license = sys.FileSystem.exists("LICENSE") ? sys.io.File.getContent("LICENSE") : null;
		for (lib in LIBS) {
			var fs = files.get(lib.name);
			if (fs == null) continue;
			var dir = '$out/${lib.name}', lines = 0, count = 0;
			for (k => text in fs) {
				var f = '$dir/src/$k';
				sys.FileSystem.createDirectory(haxe.io.Path.directory(f));
				sys.io.File.saveContent(f, text);
				lines += text.split("\n").length;
				count++;
			}
			var deps:haxe.DynamicAccess<String> = {};
			for (d in lib.deps)
				deps.set(d, 'git:$ORG$d.git');
			sys.io.File.saveContent('$dir/haxelib.json', haxe.Json.stringify({
				name: lib.name,
				url: ORG + lib.name,
				license: "MIT",
				tags: ["hxmc", "objc", "apple", "externs"],
				description: 'Haxe externs for hxmc: ${lib.about}. Generated by hx-objc/extern-generator.',
				version: "0.1.0",
				releasenote: versions != "" ? 'From $versions.' : "",
				contributors: ["back2dos"],
				classPath: "src",
				dependencies: deps
			}, null, "  ") + "\n");
			if (license != null) sys.io.File.saveContent('$dir/LICENSE', license);
			sys.io.File.saveContent('$dir/README.md', readme(lib, count, versions));
			Sys.println('${lib.name}: $count modules, $lines lines');
		}
	}

	static function readme(lib:{name:String, platforms:Array<String>, deps:Array<String>, about:String}, count:Int, versions:String):String {
		var names = ["macos" => "macOS", "ios" => "iOS", "maccatalyst" => "Mac Catalyst"];
		var b = new StringBuf();
		b.add('# ${lib.name}\n\n');
		b.add('Haxe externs for [hxmc](https://github.com/benmerckx/hxmc): ${lib.about}. $count modules, one per class, protocol, struct or enum, in a package per framework (`foundation.NSString`, `uikit.UIView`).\n\n');
		b.add('Generated by [extern-generator](${ORG}extern-generator)' + (versions != "" ? ' from $versions' : "") + ', declarations only. Do not edit: regenerate.\n\n');
		b.add("## Which libraries\n\n");
		b.add("An app depends on its platform's library, which brings the shared ones:\n\n");
		b.add("| platform | library | with |\n|---|---|---|\n");
		b.add("| macOS | `apple-appkit` | `apple-shared`, `apple-shared-mac` |\n");
		b.add("| iOS | `apple-uikit` | `apple-shared`, `apple-shared-uikit` |\n");
		b.add("| Mac Catalyst | `apple-catalyst` | `apple-shared`, `apple-shared-uikit`, `apple-shared-mac` |\n\n");
		b.add("Optional: `apple-matter` (Matter, on every platform) and `apple-appkit-legacy` (macOS's legacy APIs).\n\n");
		b.add("A platform's libraries have each type once. The shared libraries refer to the platform's types by their paths without depending on a platform library: used on their own, they fail where such a type is used.\n");
		if (!lib.deps.contains("apple-shared") && lib.name != "apple-appkit-legacy")
			b.add('\nThis library is for ${[for (p in lib.platforms) names.get(p)].join(", ")}' + (lib.name.startsWith("apple-shared") ? ", through the platform libraries above.\n" : ".\n"));
		return b.toString();
	}
}
