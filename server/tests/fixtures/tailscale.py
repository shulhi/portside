#!/usr/bin/env python3
"""Test-only LocalAPI stand-in. Production always uses an installed Tailscale CLI."""
import json
from pathlib import Path
import sys

if sys.argv[1:3] == ["status", "--json"]:
    print(json.dumps({"BackendState": "Running", "Self": {"UserID": 7, "Tags": []}}))
elif sys.argv[1:3] == ["whois", "--json"]:
    peer_file = Path(__file__).with_suffix(".peer")
    peer = peer_file.read_text().strip() if peer_file.exists() else "7"
    if not peer.isdigit():
        sys.exit(1)
    print(json.dumps({"Node": {"StableID": "test-device", "User": int(peer), "Tags": []}, "UserProfile": {"ID": int(peer)}}))
else:
    sys.exit(1)
