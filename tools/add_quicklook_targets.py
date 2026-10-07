#!/usr/bin/env python3
"""Adds the QuickLookThumbnail and QuickLookPreview app-extension targets to
MacDesign.xcodeproj and embeds them in the app. Safe to run once; it refuses to run
twice. Usage: python3 tools/add_quicklook_targets.py MacDesign/MacDesign.xcodeproj/project.pbxproj
"""
import sys, re

path = sys.argv[1]
s = open(path).read()
if 'QuickLookThumbnail' in s:
    print("already added"); sys.exit(0)

APP_TARGET = '000000000000000100000000'
PRODUCTS_GROUP = '000000000000000000000020'
MAIN_GROUP = '000000000000000000000001'
PROJECT = '000000000000000000000000'
APP_FRAMEWORKS_PHASE = '000000000000000130000000'

def ids(prefix):
    return [prefix + f'{i:02d}' for i in range(1, 20)]

exts = [
    dict(name='QuickLookThumbnail', idp='BB000000000000000000', bundle='com.imaginaryparts.macdesign.thumbnail',
         display='MacDesign Thumbnails', plist='QuickLookThumbnail-Info.plist'),
    dict(name='QuickLookPreview', idp='CC000000000000000000', bundle='com.imaginaryparts.macdesign.preview',
         display='MacDesign Preview', plist='QuickLookPreview-Info.plist'),
]

build_files = []; file_refs = []; sync_groups = []; frameworks_phases = []; sources_phases = []
resources_phases = []; native_targets = []; configs = []; config_lists = []; pkg_deps = []
embed_files = []; dependencies = []; proxies = []; target_ids = []; product_ids = []

for e in exts:
    i = ids(e['idp'])
    (tgt, prod, sync, srcphase, fwphase, resphase, bf_pkg, pkgdep, cfglist, cfgdbg, cfgrel,
     bf_embed, dep, proxy) = i[:14]
    target_ids.append(tgt); product_ids.append(prod)
    build_files.append(f"\t\t{bf_pkg} /* TSDKit in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkgdep} /* TSDKit */; }};")
    build_files.append(f"\t\t{bf_embed} /* {e['name']}.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {prod} /* {e['name']}.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")
    file_refs.append(f"\t\t{prod} /* {e['name']}.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = {e['name']}.appex; sourceTree = BUILT_PRODUCTS_DIR; }};")
    sync_groups.append(f"\t\t{sync} /* {e['name']} */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = {e['name']};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
    frameworks_phases.append(f"\t\t{fwphase} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{bf_pkg} /* TSDKit in Frameworks */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
    sources_phases.append(f"\t\t{srcphase} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
    resources_phases.append(f"\t\t{resphase} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
    native_targets.append(f"""\t\t{tgt} /* {e['name']} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cfglist} /* Build configuration list for PBXNativeTarget "{e['name']}" */;
\t\t\tbuildPhases = (
\t\t\t\t{srcphase} /* Sources */,
\t\t\t\t{fwphase} /* Frameworks */,
\t\t\t\t{resphase} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{sync} /* {e['name']} */,
\t\t\t);
\t\t\tname = {e['name']};
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkgdep} /* TSDKit */,
\t\t\t);
\t\t\tproductName = {e['name']};
\t\t\tproductReference = {prod} /* {e['name']}.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};""")
    settings = f"""\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = H5W43R3LCU;
\t\t\t\tENABLE_APP_SANDBOX = YES;
\t\t\t\tENABLE_USER_SELECTED_FILES = readonly;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_FILE = {e['plist']};
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "{e['display']}";
\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t\t"@executable_path/../../../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {e['bundle']};
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSUPPORTED_PLATFORMS = macosx;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;"""
    for cfg, name in ((cfgdbg, 'Debug'), (cfgrel, 'Release')):
        configs.append(f"\t\t{cfg} /* {name} configuration for PBXNativeTarget \"{e['name']}\" */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};")
    config_lists.append(f"\t\t{cfglist} /* Build configuration list for PBXNativeTarget \"{e['name']}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{cfgdbg} /* Debug */,\n\t\t\t\t{cfgrel} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};")
    pkg_deps.append(f"\t\t{pkgdep} /* TSDKit */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = TSDKit;\n\t\t}};")
    embed_files.append(f"\t\t\t\t{bf_embed} /* {e['name']}.appex in Embed Foundation Extensions */,")
    dependencies.append(f"\t\t{dep} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {tgt} /* {e['name']} */;\n\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n\t\t}};")
    proxies.append(f"\t\t{proxy} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {PROJECT} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {tgt};\n\t\t\tremoteInfo = {e['name']};\n\t\t}};")
    e['dep'] = dep; e['sync'] = sync

EMBED_PHASE = 'DD00000000000000000001'

def insert_section(s, name, body):
    marker = f"/* End {name} section */"
    if marker in s:
        return s.replace(marker, body + "\n" + marker)
    # create the section before XCBuildConfiguration
    return s.replace("/* Begin XCBuildConfiguration section */", f"/* Begin {name} section */\n{body}\n/* End {name} section */\n\n/* Begin XCBuildConfiguration section */")

s = insert_section(s, 'PBXBuildFile', "\n".join(build_files))
s = insert_section(s, 'PBXFileReference', "\n".join(file_refs))
s = insert_section(s, 'PBXFileSystemSynchronizedRootGroup', "\n".join(sync_groups))
s = insert_section(s, 'PBXFrameworksBuildPhase', "\n".join(frameworks_phases))
s = insert_section(s, 'PBXSourcesBuildPhase', "\n".join(sources_phases))
s = insert_section(s, 'PBXResourcesBuildPhase', "\n".join(resources_phases))
s = insert_section(s, 'PBXNativeTarget', "\n".join(native_targets))
s = insert_section(s, 'XCBuildConfiguration', "\n".join(configs))
s = insert_section(s, 'XCConfigurationList', "\n".join(config_lists))
s = insert_section(s, 'XCSwiftPackageProductDependency', "\n".join(pkg_deps))
s = insert_section(s, 'PBXTargetDependency', "\n".join(dependencies))
s = insert_section(s, 'PBXContainerItemProxy', "\n".join(proxies))
s = insert_section(s, 'PBXCopyFilesBuildPhase', f"""\t\t{EMBED_PHASE} /* Embed Foundation Extensions */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
{chr(10).join(embed_files)}
\t\t\t);
\t\t\tname = "Embed Foundation Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};""")

# App target: add the embed phase, dependencies.
s = s.replace("""				000000000000000140000000 /* Resources */,
			);
			buildRules = (
			);
			fileSystemSynchronizedGroups = (
				000000000000000000000010 /* MacDesign */,
			);""", f"""				000000000000000140000000 /* Resources */,
				{EMBED_PHASE} /* Embed Foundation Extensions */,
			);
			buildRules = (
			);
			dependencies = (
{chr(10).join('				' + e['dep'] + ' /* PBXTargetDependency */,' for e in exts)}
			);
			fileSystemSynchronizedGroups = (
				000000000000000000000010 /* MacDesign */,
			);""")

# Main group children and products.
s = s.replace("""				000000000000000000000010 /* MacDesign */,
				000000000000000000000020 /* Products */,""", f"""				000000000000000000000010 /* MacDesign */,
{chr(10).join('				' + e['sync'] + ' /* ' + e['name'] + ' */,' for e in exts)}
				000000000000000000000020 /* Products */,""")
s = s.replace("""				000000000000000000000120 /* MacDesign.app */,
			);
			name = Products;""", f"""				000000000000000000000120 /* MacDesign.app */,
{chr(10).join('				' + pid + ' /* ' + e['name'] + '.appex */,' for pid, e in zip(product_ids, exts))}
			);
			name = Products;""")
# Project targets.
s = s.replace("""			targets = (
				000000000000000100000000 /* MacDesign */,
			);""", f"""			targets = (
				000000000000000100000000 /* MacDesign */,
{chr(10).join('				' + t + ' /* ' + e['name'] + ' */,' for t, e in zip(target_ids, exts))}
			);""")
open(path, 'w').write(s)
print("added QuickLook targets")
