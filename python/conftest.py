# A pytest run from above python/ (the repository root's) collects python/tests and leaves
# python/examples out: that folder is a pytest suite of its own, with its own pytest.ini, and its
# conftest.py loads blobly's plugin with pytest_plugins, which pytest refuses from a conftest
# below the run's root. python/tests/test_examples.py runs it, as its own pytest process.
collect_ignore = ["examples"]
