"""The examples' pytest suite loads blobly's plugin here, from an installed blobly or else this
checkout's python/blobly. A suite of your own needs only the last line, in its root conftest.py."""
import os
import sys
from importlib.util import find_spec

# the repository root's blobly/ is the V engine's source, which Python takes for a namespace package
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir))

pytest_plugins = ["blobly.pytest_plugin"]
