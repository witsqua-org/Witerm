#!/usr/bin/env python3 -I
"""Writes RendererSpike.xcodeproj: three iOS app targets sharing the harness.

- SpikeSwiftTerm: SwiftTerm 1.19.0 (Witerm's pin), CoreGraphics or -metal.
- SpikeGhostty:   libghostty-vt xcframework from .build/ + a spike Metal renderer.
- SpikeBaseline:  no terminal engine, for binary-size and memory baselines.

Object IDs are derived from names, so the output is stable.
"""
import hashlib
import os

HERE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROJ = os.path.join(HERE, "RendererSpike.xcodeproj")
XCFRAMEWORK = "../../.build/spikes/ghostty/zig-out/lib/ghostty-vt.xcframework"
STREAMS = "../../.build/spikes/streams"

SHARED = ["Harness/Shared/App.swift", "Harness/Shared/Engine.swift", "Harness/Shared/Probe.swift",
          "Harness/Shared/Runner.swift", "Harness/Shared/Streams.swift"]
TARGETS = {
    "SpikeSwiftTerm": {"cond": "ENGINE_SWIFTTERM", "sources": ["Harness/SwiftTerm/SwiftTermEngine.swift"],
                       "package": True, "xcframework": False},
    "SpikeGhostty": {"cond": "ENGINE_GHOSTTY", "sources": ["Harness/Ghostty/GhosttyEngine.swift",
                                                           "Harness/Ghostty/GhosttyRenderer.swift",
                                                           "Harness/Ghostty/Shaders.metal"],
                     "package": False, "xcframework": True},
    "SpikeBaseline": {"cond": "ENGINE_NONE", "sources": ["Harness/Baseline/BaselineEngine.swift"],
                      "package": False, "xcframework": False},
}


def oid(*parts) -> str:
    return hashlib.sha1("/".join(parts).encode()).hexdigest()[:24].upper()


def ftype(path: str) -> str:
    return {"swift": "sourcecode.swift", "metal": "sourcecode.metal"}[path.rsplit(".", 1)[1]]


objects = {}


def add(i, body):
    objects[i] = body


all_sources = SHARED + sorted({s for t in TARGETS.values() for s in t["sources"]})
for path in all_sources:
    add(oid("ref", path), f'{{isa = PBXFileReference; lastKnownFileType = {ftype(path)}; path = "{path}"; sourceTree = "<group>"; }}')
add(oid("ref", "streams"), f'{{isa = PBXFileReference; lastKnownFileType = folder; name = streams; path = "{STREAMS}"; sourceTree = "<group>"; }}')
add(oid("ref", "xcframework"), f'{{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; name = "ghostty-vt.xcframework"; path = "{XCFRAMEWORK}"; sourceTree = "<group>"; }}')
for name in TARGETS:
    add(oid("product", name), f'{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{name}.app"; sourceTree = BUILT_PRODUCTS_DIR; }}')

children = ", ".join(oid("ref", p) for p in all_sources + ["streams", "xcframework"])
add(oid("group", "products"), "{isa = PBXGroup; children = (" + ", ".join(oid("product", n) for n in TARGETS) + "); name = Products; sourceTree = \"<group>\"; }")
add(oid("group", "main"), "{isa = PBXGroup; children = (" + children + ", " + oid("group", "products") + "); sourceTree = \"<group>\"; }")

add(oid("pkg", "SwiftTerm"), '{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/migueldeicaza/SwiftTerm.git"; requirement = {kind = exactVersion; version = 1.19.0; }; }')


def settings(name, cond, debug):
    s = {
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "PRODUCT_BUNDLE_IDENTIFIER": f"com.witerm.spike.{name[5:].lower()}",
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "TARGETED_DEVICE_FAMILY": "1",
        "SWIFT_VERSION": "5.0",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": f'"{cond}{" DEBUG" if debug else ""}"',
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"' if debug else '"-O"',
        "GCC_OPTIMIZATION_LEVEL": "0" if debug else "s",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UIRequiresFullScreen": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
        "CODE_SIGN_STYLE": "Manual",
        '"CODE_SIGN_IDENTITY[sdk=iphonesimulator*]"': '"-"',
        "DEVELOPMENT_TEAM": '""',
        "DEAD_CODE_STRIPPING": "YES",
        "LD_GENERATE_MAP_FILE": "YES",
        "ONLY_ACTIVE_ARCH": "YES" if debug else "NO",
        "ARCHS": "arm64",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "MTL_FAST_MATH": "YES",
    }
    if name == "SpikeGhostty":
        # libghostty-vt bundles simdutf and highway (C++).
        s["OTHER_LDFLAGS"] = '("-lc++")'
    return "{isa = XCBuildConfiguration; buildSettings = {" + " ".join(f"{k} = {v};" for k, v in s.items()) + "}; name = " + ("Debug" if debug else "Release") + "; }"


target_ids = []
for name, t in TARGETS.items():
    srcs = []
    for path in SHARED + t["sources"]:
        bid = oid("build", name, path)
        add(bid, f"{{isa = PBXBuildFile; fileRef = {oid('ref', path)}; }}")
        srcs.append(bid)
    add(oid("sources", name), "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (" + ", ".join(srcs) + "); runOnlyForDeploymentPostprocessing = 0; }")
    fw = []
    deps = []
    if t["xcframework"]:
        bid = oid("build", name, "xcframework")
        add(bid, f"{{isa = PBXBuildFile; fileRef = {oid('ref', 'xcframework')}; }}")
        fw.append(bid)
    if t["package"]:
        dep = oid("pkgdep", name)
        add(dep, "{isa = XCSwiftPackageProductDependency; package = " + oid("pkg", "SwiftTerm") + "; productName = SwiftTerm; }")
        deps.append(dep)
        bid = oid("build", name, "SwiftTerm")
        add(bid, f"{{isa = PBXBuildFile; productRef = {dep}; }}")
        fw.append(bid)
    add(oid("frameworks", name), "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (" + ", ".join(fw) + "); runOnlyForDeploymentPostprocessing = 0; }")
    rb = oid("build", name, "streams")
    add(rb, f"{{isa = PBXBuildFile; fileRef = {oid('ref', 'streams')}; }}")
    add(oid("resources", name), "{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (" + rb + "); runOnlyForDeploymentPostprocessing = 0; }")
    add(oid("cfg", name, "Debug"), settings(name, t["cond"], True))
    add(oid("cfg", name, "Release"), settings(name, t["cond"], False))
    add(oid("cfglist", name), "{isa = XCConfigurationList; buildConfigurations = (" + oid("cfg", name, "Debug") + ", " + oid("cfg", name, "Release") + "); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")
    tid = oid("target", name)
    target_ids.append(tid)
    add(tid, "{isa = PBXNativeTarget; buildConfigurationList = " + oid("cfglist", name) + "; buildPhases = (" + ", ".join([oid("sources", name), oid("frameworks", name), oid("resources", name)]) + "); buildRules = (); dependencies = (); name = " + name + "; packageProductDependencies = (" + ", ".join(deps) + "); productName = " + name + "; productReference = " + oid("product", name) + "; productType = \"com.apple.product-type.application\"; }")

proj_common = "ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; ENABLE_STRICT_OBJC_MSGSEND = YES; SDKROOT = iphoneos;"
add(oid("pcfg", "Debug"), "{isa = XCBuildConfiguration; buildSettings = {" + proj_common + " ENABLE_TESTABILITY = YES; }; name = Debug; }")
add(oid("pcfg", "Release"), "{isa = XCBuildConfiguration; buildSettings = {" + proj_common + " VALIDATE_PRODUCT = YES; }; name = Release; }")
add(oid("pcfglist"), "{isa = XCConfigurationList; buildConfigurations = (" + oid("pcfg", "Debug") + ", " + oid("pcfg", "Release") + "); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")
root = oid("project")
add(root, "{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2700; }; buildConfigurationList = " + oid("pcfglist") + "; compatibilityVersion = \"Xcode 15.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = " + oid("group", "main") + "; packageReferences = (" + oid("pkg", "SwiftTerm") + "); productRefGroup = " + oid("group", "products") + "; projectDirPath = \"\"; projectRoot = \"\"; targets = (" + ", ".join(target_ids) + "); }")

os.makedirs(PROJ, exist_ok=True)
with open(os.path.join(PROJ, "project.pbxproj"), "w") as f:
    f.write("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n")
    for k in sorted(objects):
        f.write(f"\t\t{k} = {objects[k]};\n")
    f.write(f"\t}};\n\trootObject = {root};\n}}\n")

# Pin SwiftTerm exactly as Witerm does, so resolution can use the local cache.
resolved_dir = os.path.join(PROJ, "project.xcworkspace", "xcshareddata", "swiftpm")
os.makedirs(resolved_dir, exist_ok=True)
with open(os.path.join(resolved_dir, "Package.resolved"), "w") as f:
    f.write("""{
  "pins" : [
    {
      "identity" : "swift-argument-parser",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-argument-parser",
      "state" : {
        "revision" : "6a52f3251125d74daf04fcbd5e6f08a75d074382",
        "version" : "1.8.2"
      }
    },
    {
      "identity" : "swiftterm",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/migueldeicaza/SwiftTerm.git",
      "state" : {
        "revision" : "464df5207fc2432e16c9a23abe538187196daf5f",
        "version" : "1.19.0"
      }
    }
  ],
  "version" : 3
}
""")
print("wrote", PROJ)
