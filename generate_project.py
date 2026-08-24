#!/usr/bin/env python3
"""Generate BetterNotes.xcodeproj/project.pbxproj — fast, no compile step."""
import hashlib, os, sys

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
PROJ_NAME = "BetterNotes"
PROJ_DIR = os.path.join(ROOT, PROJ_NAME + ".xcodeproj")
SOURCES_ROOT = os.path.join(ROOT, PROJ_NAME)

os.makedirs(PROJ_DIR, exist_ok=True)

def oid(seed: str) -> str:
    """Stable 24-hex-char identifier (PBXObjectID format)."""
    h = hashlib.sha256(seed.encode()).hexdigest()[:24].upper()
    return h

# ---- Collect sources & resources ----
class File:
    def __init__(self, abs_path, rel_path):
        self.abs = abs_path
        self.rel = rel_path  # relative to ROOT, e.g. BetterNotes/App/Foo.swift
        self.name = os.path.basename(abs_path)
        under = abs_path[len(SOURCES_ROOT) + 1:]
        self.group_path = under.split("/")[:-1]

sources, resources = [], []
for dirpath, dirnames, filenames in os.walk(SOURCES_ROOT):
    # .xcassets are directories — treat them as leaf resources (don't recurse in).
    kept_dirs = []
    for d in sorted(dirnames):
        if d.endswith(".xcassets"):
            abs_p = os.path.join(dirpath, d)
            rel_p = os.path.relpath(abs_p, ROOT)
            resources.append(File(abs_p, rel_p))
        else:
            kept_dirs.append(d)
    dirnames[:] = kept_dirs  # prune walk into asset catalogs
    for fn in sorted(filenames):
        ext = os.path.splitext(fn)[1]
        if ext != ".swift":
            continue
        abs_p = os.path.join(dirpath, fn)
        rel_p = os.path.relpath(abs_p, ROOT)
        sources.append(File(abs_p, rel_p))

# ---- IDs ----
PROJECT_OID       = oid("PROJECT_OBJECT")
MAIN_GROUP        = oid("MAIN_GROUP")
PROJECT_GROUP     = oid("PROJECT_SOURCES_GROUP")  # group named "BetterNotes"
PRODUCTS_GROUP    = oid("PRODUCTS_GROUP")
TARGET_OID        = oid("TARGET_OBJECT")
PRODUCT_REF       = oid("PRODUCT_REF")
SOURCES_PHASE     = oid("SOURCES_PHASE")
RESOURCES_PHASE   = oid("RESOURCES_PHASE")
FRAMEWORKS_PHASE  = oid("FRAMEWORKS_PHASE")
DEBUG_CONF        = oid("PROJECT_DEBUG_XC")
RELEASE_CONF      = oid("PROJECT_RELEASE_XC")
BUILD_CONF_LIST   = oid("PROJECT_BUILD_CONF_LIST")
TARGET_DEBUG      = oid("TARGET_DEBUG_XC")
TARGET_RELEASE    = oid("TARGET_RELEASE_XC")
TARGET_CONF_LIST  = oid("TARGET_BUILD_CONF_LIST")

def src_ids(f):  return (oid("BUILD_FILE_" + f.rel), oid("FILE_REF_" + f.rel))
def res_ids(f):  return (oid("BUILD_FILE_" + f.rel), oid("FILE_REF_" + f.rel))

src_map = {f: src_ids(f) for f in sources}
res_map = {f: res_ids(f) for f in resources}

# ---- Build group tree ----
class Node:
    pass
class FileNode(Node):
    def __init__(self, name, ref): self.name, self.ref = name, ref
class GroupNode(Node):
    def __init__(self, name, gid): self.name, self.id = name, gid; self.children = []

def build_tree():
    all_files = [(f, "src") for f in sources] + [(f, "res") for f in resources]
    # group by full directory chain under BetterNotes/
    grouped = {}
    for f, kind in all_files:
        key = tuple(f.group_path)
        grouped.setdefault(key, []).append((f, kind))

    # Build nested dict
    root_children = {}
    for gp, items in grouped.items():
        cur = root_children
        for part in gp:
            cur = cur.setdefault(part, {})
        cur.setdefault("__files__", []).extend(items)

    def make_node(full_path, leaf_name, sub):
        gid = oid("GROUP_" + full_path)        # unique id across the tree
        g = GroupNode(leaf_name, gid)          # path is the LEAF segment only
        files = sub.get("__files__", [])
        for f, kind in files:
            ref = src_map[f][1] if kind == "src" else res_map[f][1]
            g.children.append(FileNode(f.name, ref))
        for k, v in sub.items():
            if k == "__files__": continue
            g.children.append(make_node(full_path + "/" + k, k, v))
        return g

    nodes = []
    for k, v in root_children.items():
        if k == "__files__":
            for f, kind in v:
                ref = src_map[f][1] if kind == "src" else res_map[f][1]
                nodes.append(FileNode(f.name, ref))
            continue
        nodes.append(make_node(k, k, v))
    return nodes

top_nodes = build_tree()

# ---- Emit pbxproj ----
L = []
def w(s=""): L.append(s)

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")
w()

# PBXBuildFile
w("/* Begin PBXBuildFile section */")
for f, (bf, fr) in src_map.items():
    w(f"\t\t{bf} /* {f.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {f.name} */; }};")
for f, (bf, fr) in res_map.items():
    w(f"\t\t{bf} /* {f.name} in Resources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {f.name} */; }};")
w("/* End PBXBuildFile section */")
w()

# PBXFileReference
w("/* Begin PBXFileReference section */")
for f, (bf, fr) in src_map.items():
    w(f"\t\t{fr} /* {f.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{f.name}\"; sourceTree = \"<group>\"; }};")
for f, (bf, fr) in res_map.items():
    w(f"\t\t{fr} /* {f.name} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = \"{f.name}\"; sourceTree = \"<group>\"; }};")
w(f"\t\t{PRODUCT_REF} /* {PROJ_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PROJ_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
w("/* End PBXFileReference section */")
w()

# PBXFrameworksBuildPhase
w("/* Begin PBXFrameworksBuildPhase section */")
w(f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{")
w("\t\t\tisa = PBXFrameworksBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXFrameworksBuildPhase section */")
w()

# PBXGroup
def emit_group(node):
    if isinstance(node, FileNode):
        return
    w(f"\t\t{node.id} /* {node.name} */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for c in node.children:
        if isinstance(c, FileNode):
            w(f"\t\t\t\t{c.ref} /* {c.name} */,")
        else:
            w(f"\t\t\t\t{c.id} /* {c.name} */,")
    w("\t\t\t);")
    w(f"\t\t\tpath = \"{node.name}\";")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    for c in node.children:
        emit_group(c)

w("/* Begin PBXGroup section */")
w(f"\t\t{MAIN_GROUP} = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w(f"\t\t\t\t{PROJECT_GROUP} /* {PROJ_NAME} */,")
w(f"\t\t\t\t{PRODUCTS_GROUP} /* Products */,")
w("\t\t\t);")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")
w(f"\t\t{PROJECT_GROUP} /* {PROJ_NAME} */ = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for n in top_nodes:
    ref = n.ref if isinstance(n, FileNode) else n.id
    w(f"\t\t\t\t{ref} /* {n.name} */,")
w("\t\t\t);")
w(f"\t\t\tpath = \"{PROJ_NAME}\";")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")
w(f"\t\t{PRODUCTS_GROUP} /* Products */ = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w(f"\t\t\t\t{PRODUCT_REF} /* {PROJ_NAME}.app */,")
w("\t\t\t);")
w("\t\t\tname = Products;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")
for n in top_nodes:
    emit_group(n)
w("/* End PBXGroup section */")
w()

# PBXNativeTarget
w("/* Begin PBXNativeTarget section */")
w(f"\t\t{TARGET_OID} /* {PROJ_NAME} */ = {{")
w("\t\t\tisa = PBXNativeTarget;")
w(f"\t\t\tbuildConfigurationList = {TARGET_CONF_LIST} /* Build configuration list for PBXNativeTarget \"{PROJ_NAME}\" */;")
w("\t\t\tbuildPhases = (")
w(f"\t\t\t\t{SOURCES_PHASE} /* Sources */,")
w(f"\t\t\t\t{FRAMEWORKS_PHASE} /* Frameworks */,")
w(f"\t\t\t\t{RESOURCES_PHASE} /* Resources */,")
w("\t\t\t);")
w("\t\t\tbuildRules = (")
w("\t\t\t);")
w("\t\t\tdependencies = (")
w("\t\t\t);")
w(f"\t\t\tname = {PROJ_NAME};")
w(f"\t\t\tproductName = {PROJ_NAME};")
w(f"\t\t\tproductReference = {PRODUCT_REF} /* {PROJ_NAME}.app */;")
w('\t\t\tproductType = "com.apple.product-type.application";')
w("\t\t};")
w("/* End PBXNativeTarget section */")
w()

# PBXProject
w("/* Begin PBXProject section */")
w(f"\t\t{PROJECT_OID} /* Project object */ = {{")
w("\t\t\tisa = PBXProject;")
w(f"\t\t\tbuildConfigurationList = {BUILD_CONF_LIST} /* Build configuration list for PBXProject \"{PROJ_NAME}\" */;")
w('\t\t\tcompatibilityVersion = "Xcode 14.0";')
w("\t\t\tdevelopmentRegion = en;")
w("\t\t\thasScannedForEncodings = 0;")
w('\t\t\tknownRegions = ("en", "Base", );')
w(f"\t\t\tmainGroup = {MAIN_GROUP};")
w(f"\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;")
w('\t\t\tprojectDirPath = "";')
w('\t\t\tprojectRoot = "";')
w("\t\t\ttargets = (")
w(f"\t\t\t\t{TARGET_OID} /* {PROJ_NAME} */,")
w("\t\t\t);")
w("\t\t};")
w("/* End PBXProject section */")
w()

# PBXResourcesBuildPhase
w("/* Begin PBXResourcesBuildPhase section */")
w(f"\t\t{RESOURCES_PHASE} /* Resources */ = {{")
w("\t\t\tisa = PBXResourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for f, (bf, fr) in res_map.items():
    w(f"\t\t\t\t{bf} /* {f.name} in Resources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXResourcesBuildPhase section */")
w()

# PBXSourcesBuildPhase
w("/* Begin PBXSourcesBuildPhase section */")
w(f"\t\t{SOURCES_PHASE} /* Sources */ = {{")
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for f, (bf, fr) in src_map.items():
    w(f"\t\t\t\t{bf} /* {f.name} in Sources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXSourcesBuildPhase section */")
w()

# XCBuildConfiguration
PROJECT_DEBUG = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG = YES;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";"""
PROJECT_RELEASE = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t\tVALIDATE_PRODUCT = YES;"""
TARGET_COMMON = """\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\tINFOPLIST_KEY_NSMicrophoneUsageDescription = "BetterNotes uses the microphone to record audio memos in your notes.";
\t\t\tINFOPLIST_KEY_NSPhotoLibraryUsageDescription = "BetterNotes needs access to your photo library to insert images into notes.";
\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;
\t\t\tINFOPLIST_KEY_UIRequiresFullScreen = NO;
\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
\t\t\tLD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", );
\t\t\tMARKETING_VERSION = "0.1";
\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.betternotes.app";
\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\tSWIFT_VERSION = 5.0;
\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""

w("/* Begin XCBuildConfiguration section */")
w(f"\t\t{DEBUG_CONF} /* Debug */ = {{")
w("\t\t\tisa = XCBuildConfiguration;")
w("\t\t\tbuildSettings = {")
w(PROJECT_DEBUG)
w("\t\t\t};")
w("\t\t\tname = Debug;")
w("\t\t};")
w(f"\t\t{RELEASE_CONF} /* Release */ = {{")
w("\t\t\tisa = XCBuildConfiguration;")
w("\t\t\tbuildSettings = {")
w(PROJECT_RELEASE)
w("\t\t\t};")
w("\t\t\tname = Release;")
w("\t\t};")
w(f"\t\t{TARGET_DEBUG} /* Debug */ = {{")
w("\t\t\tisa = XCBuildConfiguration;")
w("\t\t\tbuildSettings = {")
w(TARGET_COMMON)
w("\t\t\t\tDEBUG = YES;")
w("\t\t\t\tENABLE_TESTABILITY = YES;")
w("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
w("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
w('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";')
w("\t\t\t};")
w("\t\t\tname = Debug;")
w("\t\t};")
w(f"\t\t{TARGET_RELEASE} /* Release */ = {{")
w("\t\t\tisa = XCBuildConfiguration;")
w("\t\t\tbuildSettings = {")
w(TARGET_COMMON)
w("\t\t\t\tDEBUG = NO;")
w("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
w('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";')
w("\t\t\t\tVALIDATE_PRODUCT = YES;")
w("\t\t\t};")
w("\t\t\tname = Release;")
w("\t\t};")
w("/* End XCBuildConfiguration section */")
w()

# XCConfigurationList
w("/* Begin XCConfigurationList section */")
w(f"\t\t{BUILD_CONF_LIST} /* Build configuration list for PBXProject \"{PROJ_NAME}\" */ = {{")
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w(f"\t\t\t\t{DEBUG_CONF} /* Debug */,")
w(f"\t\t\t\t{RELEASE_CONF} /* Release */,")
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")
w(f"\t\t{TARGET_CONF_LIST} /* Build configuration list for PBXNativeTarget \"{PROJ_NAME}\" */ = {{")
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w(f"\t\t\t\t{TARGET_DEBUG} /* Debug */,")
w(f"\t\t\t\t{TARGET_RELEASE} /* Release */,")
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")
w("/* End XCConfigurationList section */")
w()

w("\t};")
w(f"\trootObject = {PROJECT_OID} /* Project object */;")
w("}")

with open(os.path.join(PROJ_DIR, "project.pbxproj"), "w") as fh:
    fh.write("\n".join(L) + "\n")

# ---- Shared scheme ----
scheme_dir = os.path.join(PROJ_DIR, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1540" version = "1.3">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TARGET_OID}" BuildableName = "{PROJ_NAME}.app" BlueprintName = "{PROJ_NAME}" ReferencedContainer = "container:{PROJ_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables></Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TARGET_OID}" BuildableName = "{PROJ_NAME}.app" BlueprintName = "{PROJ_NAME}" ReferencedContainer = "container:{PROJ_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TARGET_OID}" BuildableName = "{PROJ_NAME}.app" BlueprintName = "{PROJ_NAME}" ReferencedContainer = "container:{PROJ_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
'''
with open(os.path.join(scheme_dir, f"{PROJ_NAME}.xcscheme"), "w") as fh:
    fh.write(scheme)

print(f"OK: generated {PROJ_NAME}.xcodeproj")
print(f"  sources:   {len(sources)} files")
print(f"  resources: {len(resources)} folders")
