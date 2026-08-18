#!/usr/bin/env python3
"""Regenerate LocalDictation.xcodeproj/project.pbxproj from the files on disk.

The Xcode project stays the single build system and remains committed; this
script only keeps the file lists in sync so adding a source file does not
require hand-editing the pbxproj. Build settings, target, and configuration
sections are copied verbatim from the existing project file.
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "LocalDictation.xcodeproj", "project.pbxproj")

APP_GROUP_PATH = "LocalDictation"
TESTS_GROUP_PATH = "LocalDictationTests"

ROOT_GROUP_ID = "A70000000000000000000001"
PRODUCTS_GROUP_ID = "A70000000000000000000005"
APP_PRODUCT_ID = "A30000000000000000000008"
TESTS_PRODUCT_ID = "A30000000000000000000009"
APP_SOURCES_PHASE_ID = "A90000000000000000000001"
TESTS_SOURCES_PHASE_ID = "A90000000000000000000002"

RESERVED = {
    ROOT_GROUP_ID, PRODUCTS_GROUP_ID, APP_PRODUCT_ID, TESTS_PRODUCT_ID,
    APP_SOURCES_PHASE_ID, TESTS_SOURCES_PHASE_ID,
}


def identifier(kind, path):
    digest = hashlib.md5(f"{kind}:{path}".encode()).hexdigest().upper()
    value = digest[:24]
    if value in RESERVED:
        value = hashlib.md5(f"{kind}:{path}:alt".encode()).hexdigest().upper()[:24]
    return value


def collect(base):
    """Returns (sorted swift files, sorted other files) relative to the repo root."""
    swift, other = [], []
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, base)):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            relative = os.path.relpath(os.path.join(dirpath, name), ROOT)
            if name.endswith(".swift"):
                swift.append(relative)
            elif name.endswith(".plist"):
                other.append(relative)
    return sorted(swift), sorted(other)


def file_type(path):
    if path.endswith(".swift"):
        return "sourcecode.swift"
    if path.endswith(".plist"):
        return "text.plist.xml"
    return "text"


class Tree:
    """Directory tree mirrored as PBXGroups."""

    def __init__(self, path, name=None):
        self.path = path
        self.name = name or os.path.basename(path)
        self.children = {}
        self.files = []

    def add(self, relative_path):
        parts = relative_path.split(os.sep)
        node = self
        for part in parts[1:-1]:
            node = node.children.setdefault(part, Tree(os.path.join(node.path, part), part))
        node.files.append(relative_path)

    def group_id(self):
        return identifier("group", self.path)

    def emit(self, lines):
        for child in sorted(self.children.values(), key=lambda c: c.name):
            child.emit(lines)
        entries = []
        for path in sorted(self.files):
            entries.append(f"\t\t\t\t{identifier('file', path)} /* {os.path.basename(path)} */,")
        for child in sorted(self.children.values(), key=lambda c: c.name):
            entries.append(f"\t\t\t\t{child.group_id()} /* {child.name} */,")
        lines.append(f"\t\t{self.group_id()} /* {self.name} */ = {{")
        lines.append("\t\t\tisa = PBXGroup;")
        lines.append("\t\t\tchildren = (")
        lines.extend(entries)
        lines.append("\t\t\t);")
        lines.append(f"\t\t\tpath = {self.name};")
        lines.append('\t\t\tsourceTree = "<group>";')
        lines.append("\t\t};")


def section(text, name):
    match = re.search(
        rf"/\* Begin {name} section \*/\n(.*?)/\* End {name} section \*/\n",
        text,
        re.S,
    )
    if not match:
        raise SystemExit(f"Missing section {name} in the existing project file")
    return match.group(1)


def main():
    with open(PBXPROJ, encoding="utf-8") as handle:
        existing = handle.read()

    app_swift, app_other = collect(APP_GROUP_PATH)
    test_swift, test_other = collect(TESTS_GROUP_PATH)
    if not app_swift or not test_swift:
        raise SystemExit("No sources found; refusing to write an empty project")

    app_tree = Tree(APP_GROUP_PATH)
    for path in app_swift + app_other:
        app_tree.add(path)
    test_tree = Tree(TESTS_GROUP_PATH)
    for path in test_swift + test_other:
        test_tree.add(path)

    build_files = []
    for path in app_swift + test_swift:
        name = os.path.basename(path)
        build_files.append(
            f"\t\t{identifier('build', path)} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {identifier('file', path)} /* {name} */; }};"
        )

    file_refs = []
    for path in app_swift + app_other + test_swift + test_other:
        name = os.path.basename(path)
        file_refs.append(
            f"\t\t{identifier('file', path)} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = {file_type(path)}; path = {name}; sourceTree = \"<group>\"; }};"
        )
    file_refs.append(
        f"\t\t{APP_PRODUCT_ID} /* LocalDictation.app */ = {{isa = PBXFileReference; "
        "explicitFileType = wrapper.application; includeInIndex = 0; path = LocalDictation.app; "
        "sourceTree = BUILT_PRODUCTS_DIR; };"
    )
    file_refs.append(
        f"\t\t{TESTS_PRODUCT_ID} /* LocalDictationTests.xctest */ = {{isa = PBXFileReference; "
        "explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = LocalDictationTests.xctest; "
        "sourceTree = BUILT_PRODUCTS_DIR; };"
    )

    groups = []
    app_tree.emit(groups)
    test_tree.emit(groups)
    groups.extend([
        f"\t\t{ROOT_GROUP_ID} = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        f"\t\t\t\t{app_tree.group_id()} /* LocalDictation */,",
        f"\t\t\t\t{test_tree.group_id()} /* LocalDictationTests */,",
        f"\t\t\t\t{PRODUCTS_GROUP_ID} /* Products */,",
        "\t\t\t);",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
        f"\t\t{PRODUCTS_GROUP_ID} /* Products */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        f"\t\t\t\t{APP_PRODUCT_ID} /* LocalDictation.app */,",
        f"\t\t\t\t{TESTS_PRODUCT_ID} /* LocalDictationTests.xctest */,",
        "\t\t\t);",
        "\t\t\tname = Products;",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
    ])

    def sources_phase(phase_id, paths):
        lines = [
            f"\t\t{phase_id} /* Sources */ = {{",
            "\t\t\tisa = PBXSourcesBuildPhase;",
            "\t\t\tbuildActionMask = 2147483647;",
            "\t\t\tfiles = (",
        ]
        for path in paths:
            name = os.path.basename(path)
            lines.append(f"\t\t\t\t{identifier('build', path)} /* {name} in Sources */,")
        lines.extend([
            "\t\t\t);",
            "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
            "\t\t};",
        ])
        return lines

    sources = sources_phase(APP_SOURCES_PHASE_ID, app_swift)
    sources.extend(sources_phase(TESTS_SOURCES_PHASE_ID, test_swift))

    def block(name, body_lines):
        return (
            f"/* Begin {name} section */\n"
            + "\n".join(body_lines)
            + f"\n/* End {name} section */\n"
        )

    output = [
        "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n\n",
        block("PBXBuildFile", build_files),
        "\n",
        f"/* Begin PBXContainerItemProxy section */\n{section(existing, 'PBXContainerItemProxy')}/* End PBXContainerItemProxy section */\n",
        "\n",
        block("PBXFileReference", file_refs),
        "\n",
        f"/* Begin PBXFrameworksBuildPhase section */\n{section(existing, 'PBXFrameworksBuildPhase')}/* End PBXFrameworksBuildPhase section */\n",
        "\n",
        block("PBXGroup", groups),
        "\n",
        f"/* Begin PBXNativeTarget section */\n{section(existing, 'PBXNativeTarget')}/* End PBXNativeTarget section */\n",
        "\n",
        f"/* Begin PBXProject section */\n{section(existing, 'PBXProject')}/* End PBXProject section */\n",
        "\n",
        f"/* Begin PBXResourcesBuildPhase section */\n{section(existing, 'PBXResourcesBuildPhase')}/* End PBXResourcesBuildPhase section */\n",
        "\n",
        block("PBXSourcesBuildPhase", sources),
        "\n",
        f"/* Begin PBXTargetDependency section */\n{section(existing, 'PBXTargetDependency')}/* End PBXTargetDependency section */\n",
        "\n",
        f"/* Begin XCBuildConfiguration section */\n{section(existing, 'XCBuildConfiguration')}/* End XCBuildConfiguration section */\n",
        "\n",
        f"/* Begin XCConfigurationList section */\n{section(existing, 'XCConfigurationList')}/* End XCConfigurationList section */\n",
        "\t};\n\trootObject = A50000000000000000000001 /* Project object */;\n}\n",
    ]

    with open(PBXPROJ, "w", encoding="utf-8") as handle:
        handle.write("".join(output))

    print(f"Wrote {PBXPROJ}")
    print(f"  app sources:   {len(app_swift)}")
    print(f"  test sources:  {len(test_swift)}")
    print(f"  other files:   {len(app_other) + len(test_other)}")


if __name__ == "__main__":
    sys.exit(main())
