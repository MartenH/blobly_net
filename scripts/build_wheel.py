"""build_wheel.py — the `blobly` wheel PyPI gets: python/blobly with the platform's libblobly inside
it (blobly/_native/), versioned from v.mod, tagged py3-none-<platform>.

    python scripts/build_wheel.py --native build/libblobly.so [--native dep.dll ...]
                                  [--licenses dir] [--out build/wheels] [--release]

--native: the library, then (Windows) the runtime DLLs it loads, all beside it in the package.
--licenses: the bundled runtime's licence texts, one folder per package, carried in the wheel.
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


def linux_platform_tag(lib):
    """manylinux_<major>_<minor>_x86_64 from the newest GLIBC_ symbol version the library needs."""
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


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--native", action="append", required=True)
    ap.add_argument("--licenses")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "wheels"))
    ap.add_argument("--release", action="store_true")
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
        plat = "win_amd64"
    elif sys.platform.startswith("linux"):
        if os.path.basename(lib) != "libblobly.so":
            sys.exit("build_wheel: the first --native is libblobly.so on Linux")
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
        if args.licenses:
            shutil.copytree(args.licenses, os.path.join(native, "licenses"))
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
            shutil.copy(os.path.join(dist, w), args.out)
            print(os.path.join(args.out, w))


if __name__ == "__main__":
    main()
