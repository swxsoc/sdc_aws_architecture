"""Write the widget HTML for the test fixture, to look at it in a browser.

Usage: ``python preview.py <output-dir>`` writes ``prod-dark.html``,
``prod-light.html`` and ``dev-dark.html`` wrapped in a minimal page. The
Terraform archive excludes this file; it is a development helper only.
"""

from __future__ import annotations

import pathlib
import sys

import test_widget
import widget

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pipeline status preview</title>
<style>body{{margin:0;background:{bg}}}</style>
</head><body>{body}</body></html>
"""


def main(target: str) -> None:
    out = pathlib.Path(target)
    out.mkdir(parents=True, exist_ok=True)
    for environment, theme in (("prod", "dark"), ("prod", "light"), ("dev", "dark")):
        snapshot = test_widget.snapshot(environment)
        body = widget.render(snapshot, theme, "us-east-1")
        page = PAGE.format(bg=widget.PALETTES[theme]["bg"], body=body)
        (out / f"{environment}-{theme}.html").write_text(page)
    body = widget.render_error("AccessDenied when calling DescribeAlarms", "dark")
    (out / "error-dark.html").write_text(
        PAGE.format(bg=widget.PALETTES["dark"]["bg"], body=body)
    )
    print(f"wrote previews to {out}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/status-preview")
