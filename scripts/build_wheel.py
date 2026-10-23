"""build_wheel.py — the `blobly` wheel PyPI gets: python/blobly with the platform's libblobly inside
it (blobly/_native/), versioned from v.mod, tagged py3-none-<platform>.

    python scripts/build_wheel.py --native build/libblobly.so [--native dep.dll ...]
                                  [--licenses dir] [--v path/to/v] [--out build/wheels] [--release]
                                  [--canbridge path/to/canbridge]

--native: the library, then (Windows) the runtime DLLs it loads, all beside it in the package.
--licenses: the bundled runtime DLLs' licence texts, one folder per package, carried in the wheel.
--canbridge: (Windows, required there) the Linux canbridge the library starts inside WSL for a
     `bridge:` channel, beside the library in _native/, where transport.bridge_program finds it.
     A V program like the library, built by the same pinned V, so the V stdlib and Boehm GC
     notices below cover it; it links nothing else but the distribution's own glibc.
--v: the V that built the library (default $V, else `v` on PATH): V's standard library and the
     Boehm GC are compiled into it, and their notices come from that toolchain, as the app
     bundle's do (scripts/stage_bundle.sh). arxmodel's and flatxml's (the ARXML reader) are this
     repository's. Lua and the GUI's components are not in the library and their notices are not.
--release: the version is v.mod's alone, and must be the tag (GITHUB_REF_NAME) when one is set.
           Without it the version carries a local label (+git.<sha>), which PyPI refuses: a CI
           wheel cannot be published by mistake.

The running interpreter needs `wheel` (for `wheel tags`); the build itself fetches setuptools.
The Linux platform tag is derived from the library: the newest glibc symbol version it uses is the
manylinux floor, and a dependency beyond what manylinux allows refuses the build."""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# what a manylinux wheel may link without bundling it (PEP 600's allowed set, the part this uses)
MANYLINUX_LIBS = {"libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1",
                  "ld-linux-x86-64.so.2", "libgcc_s.so.1"}


def vmod_version():
    """v.mod's version, in PEP 440's spelling (no leading zeros in a release segment)."""
    text = open(os.path.join(ROOT, "v.mod"), encoding="utf-8").read()
    m = re.search(r"^\s*version:\s*'([^']+)'", text, re.M)
    if not m:
        sys.exit("build_wheel: no version in v.mod")
    raw = m.group(1)
    if not re.fullmatch(r"\d+(\.\d+)*", raw):
        sys.exit(f"build_wheel: v.mod's version {raw!r} is not N(.N)*")
    return raw, ".".join(str(int(p)) for p in raw.split("."))


def git_short():
    try:
        out = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short=7", "HEAD"],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def header_notice(src):
    """A notice kept in a source file's first comment, as stage_bundle.sh's header_notice reads it."""
    out = []
    for line in open(src, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if re.match(r"^ \*/", line):
            break
        line = re.sub(r"^/\*", "", line)
        line = re.sub(r"^ \* ?", "", line)
        out.append(line)
    return "\n".join(out) + "\n"


def stage_notices(dest, vbin):
    """The notices of what is compiled into the library: V's stdlib, Boehm GC, arxmodel, flatxml."""
    vroot = os.path.dirname(os.path.realpath(vbin))
    sources = {
        "v-stdlib-LICENSE.txt": os.path.join(vroot, "LICENSE"),
        "arxmodel-LICENSE.txt": os.path.join(ROOT, "arxmodel", "LICENSE"),
        "flatxml-LICENSE.txt": os.path.join(ROOT, "flatxml", "LICENSE"),
    }
    os.makedirs(dest, exist_ok=True)
    for name, src in sources.items():
        if not os.path.isfile(src) or os.path.getsize(src) == 0:
            sys.exit(f"build_wheel: no notice at {src}")
        shutil.copy(src, os.path.join(dest, name))
    gc = os.path.join(vroot, "thirdparty", "libgc", "gc.c")
    if not os.path.isfile(gc):
        sys.exit(f"build_wheel: no Boehm GC source at {gc}; is {vbin} the V that built the library?")
    notice = header_notice(gc)
    if "Copyright" not in notice:
        sys.exit(f"build_wheel: no copyright notice at the head of {gc}")
    with open(os.path.join(dest, "boehm-gc-LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write(notice)


def check_elf_x86_64(lib):
    """Refuses a library a manylinux x86_64 wheel cannot carry: not ELF64, or not x86-64."""
    head = subprocess.run(["readelf", "-h", lib], capture_output=True, text=True, check=True).stdout
    if not re.search(r"Class:\s+ELF64", head) or not re.search(r"Machine:\s+Advanced Micro Devices X86-64", head):
        sys.exit(f"build_wheel: {lib} is not an x86-64 ELF64 library")


def check_pe_x86_64(dll):
    """Refuses a DLL a win_amd64 wheel cannot carry: its PE machine is not x86-64 (0x8664)."""
    with open(dll, "rb") as f:
        data = f.read(4096)
    if data[:2] != b"MZ" or len(data) < 0x40:
        sys.exit(f"build_wheel: {dll} is not a PE file")
    pe = int.from_bytes(data[0x3C:0x40], "little")
    if data[pe:pe + 4] != b"PE\0\0" or int.from_bytes(data[pe + 4:pe + 6], "little") != 0x8664:
        sys.exit(f"build_wheel: {dll} is not an x86-64 DLL")


def check_canbridge(path):
    """Refuses a canbridge WSL cannot run: not an x86-64 ELF64 program. Read by its header, so
    the check runs on Windows, where there is no readelf."""
    with open(path, "rb") as f:
        head = f.read(20)
    if head[:4] != b"\x7fELF" or head[4] != 2 or head[5] != 1 or head[18:20] != b"\x3e\x00":
        sys.exit(f"build_wheel: {path} is not an x86-64 ELF64 program")


def linux_platform_tag(lib):
    """manylinux_<major>_<minor>_x86_64 from the newest GLIBC_ symbol version the library needs."""
    check_elf_x86_64(lib)
    needed = subprocess.run(["readelf", "-d", lib], capture_output=True, text=True, check=True)
    libs = set(re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", needed.stdout))
    extra = libs - MANYLINUX_LIBS
    if extra:
        sys.exit(f"build_wheel: {lib} links {sorted(extra)}, which a manylinux wheel may not")
    syms = subprocess.run(["objdump", "-T", lib], capture_output=True, text=True, check=True)
    versions = {tuple(int(x) for x in v.split(".")) for v in re.findall(r"GLIBC_(\d+\.\d+)", syms.stdout)}
    if not versions:
        sys.exit(f"build_wheel: {lib} names no GLIBC symbol version; cannot place it")
    major, minor = max(versions)
    return f"manylinux_{major}_{minor}_x86_64"


def check_contents(wheel, natives, canbridge):
    """Refuses a wheel missing what it was built to carry: every --native file, canbridge when
    given, its version file, and py.typed, PEP 561's marker that the package's annotations are
    complete (mypy ignores them without it)."""
    with zipfile.ZipFile(wheel) as z:
        names = set(z.namelist())
    want = {f"blobly/_native/{os.path.basename(f)}" for f in natives} | {"blobly/_version.py", "blobly/py.typed"}
    if canbridge:
        want.add("blobly/_native/canbridge")
    if want - names:
        sys.exit(f"build_wheel: {os.path.basename(wheel)} lacks {', '.join(sorted(want - names))}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--native", action="append", required=True)
    ap.add_argument("--licenses")
    ap.add_argument("--v", default=os.environ.get("V") or shutil.which("v"))
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "wheels"))
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--canbridge")
    args = ap.parse_args()

    raw, version = vmod_version()
    if args.release:
        tag = os.environ.get("GITHUB_REF_NAME")
        if tag and tag != f"v{raw}":
            sys.exit(f"build_wheel: tag {tag} is not v.mod's v{raw}")
    else:
        version = f"{version}+git.{git_short()}"

    lib = args.native[0]
    if sys.platform == "win32":
        if os.path.basename(lib) != "blobly.dll":
            sys.exit("build_wheel: the first --native is blobly.dll on Windows")
        for f in args.native:
            check_pe_x86_64(f)
        if not args.canbridge:
            sys.exit("build_wheel: a Windows wheel carries canbridge for the WSL bridge; pass --canbridge")
        check_canbridge(args.canbridge)
        plat = "win_amd64"
    elif sys.platform.startswith("linux"):
        if os.path.basename(lib) != "libblobly.so":
            sys.exit("build_wheel: the first --native is libblobly.so on Linux")
        if args.canbridge:
            sys.exit("build_wheel: canbridge is for the Windows wheel (a bridge is started from Windows into WSL)")
        plat = linux_platform_tag(lib)
    else:
        sys.exit(f"build_wheel: no wheel for {sys.platform}")

    with tempfile.TemporaryDirectory() as stage:
        pkg = os.path.join(stage, "blobly")
        shutil.copytree(os.path.join(ROOT, "python", "blobly"), pkg,
                        ignore=shutil.ignore_patterns("__pycache__", "_native", "_version.py"))
        for name in ("pyproject.toml", "README.md"):
            shutil.copy(os.path.join(ROOT, "python", name), stage)
        shutil.copy(os.path.join(ROOT, "LICENSE"), stage)
        native = os.path.join(pkg, "_native")
        os.makedirs(native)
        for f in args.native:
            shutil.copy(f, native)
        if args.canbridge:
            shutil.copy(args.canbridge, os.path.join(native, "canbridge"))
        if args.licenses:
            shutil.copytree(args.licenses, os.path.join(native, "licenses"))
        if not args.v:
            sys.exit("build_wheel: no V to take its notices from; pass --v or set V")
        stage_notices(os.path.join(native, "licenses"), args.v)
        with open(os.path.join(pkg, "_version.py"), "w", encoding="utf-8") as f:
            f.write(f'__version__ = "{version}"\n')
        dist = os.path.join(stage, "dist")
        subprocess.run([sys.executable, "-m", "pip", "wheel", "--no-deps", "-q", "--disable-pip-version-check",
                        "-w", dist, stage],
                       check=True)
        built = [os.path.join(dist, w) for w in os.listdir(dist) if w.endswith(".whl")]
        if len(built) != 1:
            sys.exit(f"build_wheel: expected one wheel, got {built}")
        subprocess.run([sys.executable, "-m", "wheel", "tags", "--python-tag", "py3",
                        "--abi-tag", "none", "--platform-tag", plat, "--remove", built[0]],
                       check=True, capture_output=True)
        os.makedirs(args.out, exist_ok=True)
        for w in os.listdir(dist):
            check_contents(os.path.join(dist, w), args.native, args.canbridge)
            shutil.copy(os.path.join(dist, w), args.out)
            print(os.path.join(args.out, w))


if __name__ == "__main__":
    main()
