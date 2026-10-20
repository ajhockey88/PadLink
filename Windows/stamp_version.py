"""Build step: write the release version (from RELEASE_TAG) into padlink_receiver.py."""
import os
import re
import sys

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "padlink_receiver.py")
version = os.environ["RELEASE_TAG"].lstrip("v")
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    sys.exit(f"RELEASE_TAG does not look like vX.Y.Z: {os.environ['RELEASE_TAG']}")
source = open(path, encoding="utf-8").read()
if 'VERSION = "dev"' not in source:
    sys.exit("VERSION placeholder not found")
open(path, "w", encoding="utf-8").write(source.replace('VERSION = "dev"', f'VERSION = "{version}"', 1))
print("Stamped version", version)
