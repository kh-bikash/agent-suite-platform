"""Apply ordered Supabase migrations without echoing the database URL.

Set DATABASE_URL in the environment. The script uses a subprocess argument list
and never prints the connection string, including when the CLI fails.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from urllib.parse import urlparse


def main() -> int:
    url = os.environ.get("DATABASE_URL", "")
    if not url.startswith(("postgres://", "postgresql://")):
        print("DATABASE_URL is missing or invalid", file=sys.stderr)
        return 2
    npx = shutil.which("npx.cmd" if os.name == "nt" else "npx")
    if not npx:
        print("npx is unavailable", file=sys.stderr)
        return 2
    args = [npx, "--yes", "supabase@latest", "db", "push", "--db-url", url, "--yes"]
    if "--dry-run" in sys.argv[1:]:
        args.append("--dry-run")
    result = subprocess.run(args, check=False, capture_output=True, text=True)
    password = urlparse(url).password or ""
    for output, stream in ((result.stdout, sys.stdout), (result.stderr, sys.stderr)):
        clean = output.replace(url, "[REDACTED DATABASE URL]")
        if password:
            clean = clean.replace(password, "[REDACTED PASSWORD]")
        if clean:
            print(clean, file=stream, end="")
    if result.returncode:
        print(
            f"Supabase migration command failed with status {result.returncode}",
            file=sys.stderr,
        )
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
