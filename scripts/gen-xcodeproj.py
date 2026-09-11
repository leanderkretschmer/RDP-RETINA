#!/usr/bin/env python3
"""
Erzeugt rdp-retina.xcodeproj aus den Quellen in core/ und mac/.

Das Projekt liegt fertig im Repo, damit Xcode und Xcode Cloud es direkt öffnen. Nach dem
Hinzufügen oder Entfernen von Quelldateien einfach erneut ausführen:

    python3 scripts/gen-xcodeproj.py

FreeRDP 3 wird gesucht in (erste Fundstelle gewinnt):
    vendor/freerdp   eigener Build, z.B. mit VideoToolbox (scripts/build-freerdp-macos.sh)
    /opt/homebrew    Homebrew auf Apple Silicon
    /usr/local       Homebrew auf Intel
"""
import hashlib
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAME = "rdp-retina"
BUNDLE_ID = "com.cratchmere.rdp-retina"
DEPLOYMENT_TARGET = "13.0"
GROUPS = ["core", "mac"]
FILE_TYPES = {
    ".c": "sourcecode.c.c",
    ".h": "sourcecode.c.h",
    ".m": "sourcecode.c.objc",
    ".plist": "text.plist.xml",
}
COMPILED = {".c", ".m"}
PREFIXES = ["$(SRCROOT)/vendor/freerdp", "/opt/homebrew", "/usr/local"]
# App-Icon aus Icon Composer (Xcode 26) als <Name>.icon im Wurzelverzeichnis. actool macht
# daraus Assets.car und für ältere macOS-Versionen eine .icns.
ICON_TYPE = "folder.iconcomposer.icon"


def oid(*parts):
    return hashlib.md5("/".join((NAME,) + parts).encode()).hexdigest()[:24].upper()


def q(value):
    """Wert für project.pbxproj, nur wenn nötig in Anführungszeichen."""
    if value and all(c.isalnum() or c in "._/" for c in value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def setting(key, value, indent):
    pad = "\t" * indent
    if isinstance(value, list):
        items = "".join(f"{pad}\t{q(v)},\n" for v in value)
        return f"{pad}{key} = (\n{items}{pad});\n"
    return f"{pad}{key} = {q(value)};\n"


def settings_block(values, indent):
    return "".join(setting(k, values[k], indent) for k in sorted(values))


def project_settings(debug):
    values = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_COMMA": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
        "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
        "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
        "CLANG_WARN_STRICT_PROTOTYPES": "NO",
        "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu11",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "NO",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "macosx",
    }
    if debug:
        values.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "ONLY_ACTIVE_ARCH": "YES",
        })
    else:
        values.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
        })
    return values


def target_settings(icon):
    values = {
        # FreeRDP aus Homebrew gibt es nur für die eigene Architektur.
        "ARCHS": "$(NATIVE_ARCH_ACTUAL)",
        "CODE_SIGN_IDENTITY": "-",
        "CODE_SIGN_STYLE": "Automatic",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        # Homebrew-Bibliotheken sind nicht vom selben Team signiert.
        "ENABLE_HARDENED_RUNTIME": "NO",
        "GCC_PREFIX_HEADER": "mac/RRPrefix.h",
        "GENERATE_INFOPLIST_FILE": "NO",
        "HEADER_SEARCH_PATHS": ["$(SRCROOT)/core"],
        # FreeRDP als System-Header: deren Warnungen (z.B. -Wambiguous-macro in winpr/stream.h)
        # gehören nicht zu diesem Projekt.
        "SYSTEM_HEADER_SEARCH_PATHS": [
            f"{p}/include/{lib}" for p in PREFIXES for lib in ("freerdp3", "winpr3")
        ],
        "INFOPLIST_FILE": "mac/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"]
        + [f"{p}/lib" for p in PREFIXES],
        "LIBRARY_SEARCH_PATHS": [f"{p}/lib" for p in PREFIXES],
        "MARKETING_VERSION": "0.1.0",
        "OTHER_LDFLAGS": [
            "-lfreerdp-client3", "-lfreerdp3", "-lwinpr3",
            "-framework", "AppKit", "-framework", "Metal", "-framework", "QuartzCore",
            "-framework", "Carbon", "-framework", "IOKit",
        ],
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
    }
    if icon:
        values["ASSETCATALOG_COMPILER_APPICON_NAME"] = icon.stem
    return values


def main():
    files = []
    for group in GROUPS:
        for path in sorted((ROOT / group).iterdir()):
            if path.is_file() and path.suffix in FILE_TYPES:
                files.append((group, path.name, path.suffix))
    icons = sorted(p for p in ROOT.glob("*.icon") if p.is_dir())
    icon = icons[0] if icons else None
    if icon:
        icon_file = oid("file", "root", icon.name)
        icon_build = oid("build", "root", icon.name)

    project = oid("project")
    target = oid("target")
    main_group = oid("group", "main")
    products_group = oid("group", "products")
    product = oid("product")
    sources_phase = oid("phase", "sources")
    frameworks_phase = oid("phase", "frameworks")
    resources_phase = oid("phase", "resources")
    project_list = oid("configlist", "project")
    target_list = oid("configlist", "target")
    configs = {(scope, cfg): oid("config", scope, cfg)
               for scope in ("project", "target") for cfg in ("Debug", "Release")}

    out = []
    w = out.append
    w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n\n")

    w("/* Begin PBXBuildFile section */\n")
    for group, name, ext in files:
        if ext in COMPILED:
            w(f"\t\t{oid('build', group, name)} /* {name} in Sources */ = "
              f"{{isa = PBXBuildFile; fileRef = {oid('file', group, name)} /* {name} */; }};\n")
    if icon:
        w(f"\t\t{icon_build} /* {icon.name} in Resources */ = "
          f"{{isa = PBXBuildFile; fileRef = {icon_file} /* {icon.name} */; }};\n")
    w("/* End PBXBuildFile section */\n\n")

    w("/* Begin PBXFileReference section */\n")
    for group, name, ext in files:
        w(f"\t\t{oid('file', group, name)} /* {name} */ = {{isa = PBXFileReference; "
          f"lastKnownFileType = {FILE_TYPES[ext]}; path = {q(name)}; sourceTree = \"<group>\"; }};\n")
    if icon:
        w(f"\t\t{icon_file} /* {icon.name} */ = {{isa = PBXFileReference; "
          f"lastKnownFileType = {ICON_TYPE}; path = {q(icon.name)}; sourceTree = \"<group>\"; }};\n")
    w(f"\t\t{product} /* {NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; "
      f"includeInIndex = 0; path = {q(NAME + '.app')}; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
    w("/* End PBXFileReference section */\n\n")

    w("/* Begin PBXFrameworksBuildPhase section */\n")
    w(f"\t\t{frameworks_phase} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n"
      "\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
      "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
    w("/* End PBXFrameworksBuildPhase section */\n\n")

    w("/* Begin PBXGroup section */\n")
    children = "".join(f"\t\t\t\t{oid('group', g)} /* {g} */,\n" for g in GROUPS)
    if icon:
        children = f"\t\t\t\t{icon_file} /* {icon.name} */,\n" + children
    w(f"\t\t{main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}"
      f"\t\t\t\t{products_group} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
    for group in GROUPS:
        entries = "".join(f"\t\t\t\t{oid('file', g, n)} /* {n} */,\n" for g, n, _ in files if g == group)
        w(f"\t\t{oid('group', group)} /* {group} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{entries}"
          f"\t\t\t);\n\t\t\tpath = {group};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
    w(f"\t\t{products_group} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
      f"\t\t\t\t{product} /* {NAME}.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
    w("/* End PBXGroup section */\n\n")

    w("/* Begin PBXNativeTarget section */\n")
    w(f"\t\t{target} /* {NAME} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
      f"\t\t\tbuildConfigurationList = {target_list} /* Build configuration list for PBXNativeTarget \"{NAME}\" */;\n"
      f"\t\t\tbuildPhases = (\n\t\t\t\t{sources_phase} /* Sources */,\n\t\t\t\t{frameworks_phase} /* Frameworks */,\n"
      f"\t\t\t\t{resources_phase} /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n"
      f"\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {q(NAME)};\n\t\t\tproductName = {q(NAME)};\n"
      f"\t\t\tproductReference = {product} /* {NAME}.app */;\n"
      "\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t};\n")
    w("/* End PBXNativeTarget section */\n\n")

    w("/* Begin PBXProject section */\n")
    w(f"\t\t{project} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n"
      "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastUpgradeCheck = 2650;\n"
      f"\t\t\t\tTargetAttributes = {{\n\t\t\t\t\t{target} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.5;\n"
      "\t\t\t\t\t};\n\t\t\t\t};\n\t\t\t};\n"
      f"\t\t\tbuildConfigurationList = {project_list} /* Build configuration list for PBXProject \"{NAME}\" */;\n"
      "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = de;\n"
      "\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\tde,\n\t\t\t\tBase,\n\t\t\t);\n"
      f"\t\t\tmainGroup = {main_group};\n\t\t\tproductRefGroup = {products_group} /* Products */;\n"
      "\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
      f"\t\t\ttargets = (\n\t\t\t\t{target} /* {NAME} */,\n\t\t\t);\n\t\t}};\n")
    w("/* End PBXProject section */\n\n")

    w("/* Begin PBXResourcesBuildPhase section */\n")
    resources = f"\t\t\t\t{icon_build} /* {icon.name} in Resources */,\n" if icon else ""
    w(f"\t\t{resources_phase} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n"
      f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{resources}\t\t\t);\n"
      "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
    w("/* End PBXResourcesBuildPhase section */\n\n")

    w("/* Begin PBXSourcesBuildPhase section */\n")
    sources = "".join(f"\t\t\t\t{oid('build', g, n)} /* {n} in Sources */,\n"
                      for g, n, ext in files if ext in COMPILED)
    w(f"\t\t{sources_phase} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
      f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{sources}\t\t\t);\n"
      "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
    w("/* End PBXSourcesBuildPhase section */\n\n")

    w("/* Begin XCBuildConfiguration section */\n")
    for cfg in ("Debug", "Release"):
        w(f"\t\t{configs[('project', cfg)]} /* {cfg} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n"
          f"\t\t\tbuildSettings = {{\n{settings_block(project_settings(cfg == 'Debug'), 4)}\t\t\t}};\n"
          f"\t\t\tname = {cfg};\n\t\t}};\n")
    for cfg in ("Debug", "Release"):
        w(f"\t\t{configs[('target', cfg)]} /* {cfg} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n"
          f"\t\t\tbuildSettings = {{\n{settings_block(target_settings(icon), 4)}\t\t\t}};\n"
          f"\t\t\tname = {cfg};\n\t\t}};\n")
    w("/* End XCBuildConfiguration section */\n\n")

    w("/* Begin XCConfigurationList section */\n")
    for scope, list_id, label in (("project", project_list, f"PBXProject \"{NAME}\""),
                                  ("target", target_list, f"PBXNativeTarget \"{NAME}\"")):
        w(f"\t\t{list_id} /* Build configuration list for {label} */ = {{\n\t\t\tisa = XCConfigurationList;\n"
          f"\t\t\tbuildConfigurations = (\n\t\t\t\t{configs[(scope, 'Debug')]} /* Debug */,\n"
          f"\t\t\t\t{configs[(scope, 'Release')]} /* Release */,\n\t\t\t);\n"
          "\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n")
    w("/* End XCConfigurationList section */\n")

    w(f"\t}};\n\trootObject = {project} /* Project object */;\n}}\n")

    proj_dir = ROOT / f"{NAME}.xcodeproj"
    (proj_dir / "project.xcworkspace").mkdir(parents=True, exist_ok=True)
    (proj_dir / "xcshareddata" / "xcschemes").mkdir(parents=True, exist_ok=True)
    (proj_dir / "project.pbxproj").write_text("".join(out), encoding="utf-8")

    (proj_dir / "project.xcworkspace" / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
        '   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n', encoding="utf-8")

    def reference(indent):
        """BuildableReference so eingerückt, wie Xcode sie an dieser Stelle schreibt."""
        pad = " " * indent
        return (f'<BuildableReference\n{pad}   BuildableIdentifier = "primary"\n'
                f'{pad}   BlueprintIdentifier = "{target}"\n'
                f'{pad}   BuildableName = "{NAME}.app"\n'
                f'{pad}   BlueprintName = "{NAME}"\n'
                f'{pad}   ReferencedContainer = "container:{NAME}.xcodeproj">\n'
                f'{pad}</BuildableReference>')
    # Beispielargumente, abgeschaltet. Das Kennwort fragt FreeRDP in der Xcode-Konsole ab.
    arguments = ["/v:192.168.0.0", "/u:Administrator", "/f", "/scale:180",
                 "/gfx:AVC444", "/network:lan", "/cert:ignore", "/app:program:||taskmgr"]
    argument_xml = "".join(
        f'         <CommandLineArgument\n            argument = "{a}"\n            isEnabled = "NO">\n'
        f'         </CommandLineArgument>\n' for a in arguments)
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2650"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {reference(12)}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "NO"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {reference(9)}
      </BuildableProductRunnable>
      <CommandLineArguments>
{argument_xml}      </CommandLineArguments>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "NO">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {reference(9)}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    (proj_dir / "xcshareddata" / "xcschemes" / f"{NAME}.xcscheme").write_text(scheme, encoding="utf-8")
    print(f"{proj_dir.relative_to(ROOT)}: {len(files)} Dateien")


if __name__ == "__main__":
    main()
