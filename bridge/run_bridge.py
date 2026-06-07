"""PyInstaller entry shim.

A frozen program is run as the top-level module, so the relative imports in
gbf_bridge/__main__.py would fail. Importing through the absolute package
path keeps them working in the bundled binary.
"""

from gbf_bridge.__main__ import main

if __name__ == "__main__":
    main()
