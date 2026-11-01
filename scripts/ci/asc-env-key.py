#!/usr/bin/env python3
"""Read an ASC API key from a fastlane-style env file without echoing secrets.

Usage: asc-env-key.py ENV_FILE KEY_OUT FIELD
Writes APPSTORE_KEY_CONTENT (literal \\n unescaped) to KEY_OUT (0600) and prints
only FIELD (key_id or issuer_id).
"""
import os
import re
import sys

env_file, key_out, field = sys.argv[1:4]
values = {}
with open(env_file, encoding="utf-8") as handle:
    for line in handle:
        match = re.match(r"(?:export\s+)?(APPSTORE_\w+)=(.*)", line.strip())
        if match:
            values[match.group(1)] = match.group(2).strip().strip("\"'")
fd = os.open(key_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as out:
    out.write(values["APPSTORE_KEY_CONTENT"].replace("\\n", "\n") + "\n")
print(values["APPSTORE_KEY_ID" if field == "key_id" else "APPSTORE_ISSUER_ID"])
