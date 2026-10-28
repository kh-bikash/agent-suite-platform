"""Configure a private Groq model key on named Vercel projects.

Reads the key from a local file and sends it to Vercel via stdin. Never prints
the key or places it in command-line arguments.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--vercel-cli", type=Path)
    parser.add_argument("projects", nargs="+")
    args = parser.parse_args()
    key = args.key_file.read_text(encoding="utf-8").strip()
    if not key.startswith("gsk_") or len(key) < 30:
        print("Key file has an invalid format", file=sys.stderr)
        return 2
    if args.vercel_cli:
        node = shutil.which("node")
        if not node or not args.vercel_cli.is_file():
            print("Node or Vercel CLI is unavailable", file=sys.stderr)
            return 2
        base = [node, str(args.vercel_cli), "env", "add"]
    else:
        npx = shutil.which("npx.cmd" if os.name == "nt" else "npx")
        if not npx:
            print("npx is unavailable", file=sys.stderr)
            return 2
        base = [npx, "--yes", "vercel@latest", "env", "add"]
    for project in args.projects:
        for name, value, secret in (
            ("OPENAI_API_KEY", key, True),
            ("OPENAI_BASE_URL", "https://api.groq.com/openai/v1", False),
            ("OPENAI_MODEL", "openai/gpt-oss-20b", False),
        ):
            cmd = base + [
                name,
                "--project",
                project,
                "--scope",
                args.scope,
                "--environment",
                "production,preview,development",
                "--force",
                "--yes",
            ]
            if secret:
                cmd.append("--sensitive")
            else:
                cmd.extend(["--value", value])
            result = subprocess.run(
                cmd,
                input=value if secret else None,
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode:
                clean = (result.stdout + result.stderr).replace(key, "[REDACTED KEY]")
                print(
                    f"Failed to configure {name} on {project}: {clean}", file=sys.stderr
                )
                return result.returncode
            print(f"Configured {name} on {project}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
