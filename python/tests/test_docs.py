"""The Python documentation against the package it describes:
  - every public class, method, property and attribute of `blobly` is named in the reference
    section of docs/scripting_python.md, so the reference cannot silently fall behind the code;
  - every Python block in the guide, in docs/agents.md, docs/vscode.md and python/README.md (the
    PyPI page) runs as written, from the repository root, and every YAML block there is a project
    that loads (and, when every row is an in-process bus, starts);
  - every link in those pages and in python/examples/README.md reaches a file of the repository,
    and an anchor a heading of it.
The public surface is what `blobly.__all__` exports: its functions, its classes, and each class's
methods, properties, __slots__ and `self.<name>` attributes, its package base classes' included;
and for a submodule it exports (blobly.e2e), the functions of that submodule's `__all__`."""
import ast
import contextlib
import io
import os
import re
import shutil
import types

import pytest

import blobly
from conftest import REPO

pytestmark = pytest.mark.usefixtures("engine")

GUIDE = os.path.join(REPO, "docs", "scripting_python.md")
RUN = [GUIDE, os.path.join(REPO, "docs", "agents.md"), os.path.join(REPO, "docs", "vscode.md"),
       os.path.join(REPO, "python", "README.md")]
LINKED = RUN + [os.path.join(REPO, "python", "examples", "README.md")]
GITHUB = "https://github.com/MartenH/blobly_net/"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def blocks(path, lang):
    return re.findall(r"^```" + lang + r"\n(.*?)^```", read(path), re.S | re.M)


def package_classes():
    """Every class defined in the package's source (python/blobly), by name."""
    src = os.path.join(REPO, "python", "blobly")
    out = {}
    for name in sorted(os.listdir(src)):
        if name.endswith(".py"):
            for node in ast.parse(read(os.path.join(src, name))).body:
                if isinstance(node, ast.ClassDef):
                    out[node.name] = node
    return out


def members(node, classes):
    """A class's public names: methods and properties, __slots__, and what its methods assign to
    self, with those of its base classes that the package defines."""
    names = set()
    for base in node.bases:
        if isinstance(base, ast.Subscript):  # a generic base: Named[Channel] is Named
            base = base.value
        if isinstance(base, ast.Name) and base.id in classes:
            names |= members(classes[base.id], classes)
    for item in node.body:
        if isinstance(item, ast.FunctionDef):
            names.add(item.name)
        elif isinstance(item, ast.Assign) and any(getattr(t, "id", None) == "__slots__" for t in item.targets):
            names |= {e.value for e in item.value.elts}
    for n in ast.walk(node):
        if (isinstance(n, ast.Attribute) and isinstance(n.ctx, ast.Store) and isinstance(n.value, ast.Name)
                and n.value.id == "self"):
            names.add(n.attr)
    return {n for n in names if not n.startswith("_")}


def reference():
    """The reference section's subsections: {heading: the code spans under it}."""
    text = read(GUIDE)
    m = re.search(r"^## \d+\. Reference\n(.*?)(?=^## )", text, re.S | re.M)
    if m is None:
        raise AssertionError("docs/scripting_python.md has no '## N. Reference' section")
    out = {}
    for part in re.split(r"^### ", m.group(1), flags=re.M)[1:]:
        heading, _, body = part.partition("\n")
        out[heading] = re.findall(r"`([^`]+)`", body)
    return out


def mentions(spans, name):
    return any(re.search(r"(?<![\w])" + re.escape(name) + r"(?![\w])", s) for s in spans)


def anchor(heading):
    """The anchor GitHub gives a heading."""
    slug = re.sub(r"[^\w\- ]", "", heading.strip().lower())
    return slug.replace(" ", "-")


class TestReference:
    def test_every_public_name_is_in_the_reference(self):
        classes, ref = package_classes(), reference()
        missing = []
        for name in blobly.__all__:
            obj = getattr(blobly, name)
            if isinstance(obj, types.ModuleType):
                spans = ref.get(f"Module `blobly.{name}`")
                if spans is None:
                    missing.append(f"a '### Module `blobly.{name}`' section")
                    continue
                missing += [f"blobly.{name}.{fn}" for fn in obj.__all__ if not mentions(spans, f"blobly.{name}.{fn}")]
                continue
            if not isinstance(obj, type):
                if not mentions(ref.get("Module `blobly`", []), "blobly." + name):
                    missing.append(f"blobly.{name}")
                continue
            sections = [spans for heading, spans in ref.items() if mentions([heading], name)]
            if not sections:
                missing.append(f"a '### {name}' section")
                continue
            for member in sorted(members(classes[name], classes)):
                if not any(mentions(spans, member) for spans in sections):
                    missing.append(f"{name}.{member}")
        if not mentions(ref.get("Module `blobly`", []), "blobly.__version__"):
            missing.append("blobly.__version__")
        assert missing == [], "named nowhere in the reference of docs/scripting_python.md"

    def test_the_enumeration_sees_what_the_package_has(self):
        # what the check above walks must be real: a parse that found nothing would pass it
        classes = package_classes()
        assert {"send", "recv", "look", "iface", "kind", "name"} <= members(classes["Channel"], classes)
        assert {"on_message", "run", "path", "started", "fault", "clear_faults"} <= members(classes["Project"], classes)
        assert blobly.e2e.__all__ == ["p01_crc", "p01_protect"]
        assert {"id", "ext", "dlc", "j1939", "channel"} <= members(classes["Message"], classes)
        assert {"raw_labels", "mux_value"} <= members(classes["Signal"], classes)
        assert "code" in members(classes["BloblyError"], classes)
        assert "keys" in members(classes["Messages"], classes)


class TestBlocks:
    def test_every_python_block_runs(self, monkeypatch):
        monkeypatch.chdir(REPO)  # the blocks run from the root of a checkout
        for doc in RUN:
            for i, code in enumerate(blocks(doc, "python")):
                with contextlib.redirect_stdout(io.StringIO()):
                    exec(compile(code, f"{doc}#{i + 1}", "exec"), {"__name__": "__doc_block__"})

    def test_every_yaml_block_is_a_project(self, tmp_path):
        # a project names its databases relative to itself: projects/ beside dbc/, as here
        shutil.copytree(os.path.join(REPO, "dbc"), tmp_path / "dbc")
        (tmp_path / "projects").mkdir()
        for doc in RUN:
            for i, text in enumerate(blocks(doc, "yaml")):
                where = f"{os.path.relpath(doc, REPO)} yaml block {i + 1}"
                path = os.fspath(tmp_path / "projects" / f"block{i}.blobnet")
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text)
                net = blobly.Project(path).load()
                assert len(net.channels) > 0, where
                if all(ch.iface.startswith("inproc") for ch in net.channels):
                    net.start()
                    assert net.stop(), where


class TestLinks:
    def test_every_link_reaches_a_file_and_a_heading(self):
        broken = []
        for doc in LINKED:
            for target in re.findall(r"\]\(([^)\s]+)\)", read(doc)):
                if target.startswith(GITHUB + "issues/"):
                    continue
                if target.startswith(GITHUB):
                    m = re.match(r"(?:blob|tree)/main/(.*)", target[len(GITHUB):])
                    path, _, frag = (m.group(1) if m else "\0").partition("#")
                    full = os.path.join(REPO, path) if path else REPO
                elif target.startswith(("http://", "https://", "mailto:")):
                    continue
                else:
                    path, _, frag = target.partition("#")
                    full = os.path.normpath(os.path.join(os.path.dirname(doc), path)) if path else doc
                if not os.path.exists(full):
                    broken.append(f"{os.path.relpath(doc, REPO)}: {target}")
                elif frag and full.endswith(".md"):
                    headings = re.findall(r"^#+ (.*)$", read(full), re.M)
                    if frag not in {anchor(h) for h in headings}:
                        broken.append(f"{os.path.relpath(doc, REPO)}: {target} (no such heading)")
        assert broken == []
