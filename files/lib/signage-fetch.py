#!/usr/bin/env python3
"""Fetch image candidates from a plain Apache/Nginx-style directory listing.

The script intentionally discovers candidate images by filename extension, then the
shell sync script validates the downloaded files with feh before promoting them.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import posixpath
import shutil
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path
from typing import Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urljoin, urlparse
from urllib.request import Request, urlopen

USER_AGENT = "digital-signage-fetch/0.1"


class DirectoryListingParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hrefs: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a":
            return
        for key, value in attrs:
            if key.lower() == "href" and value:
                self.hrefs.append(value)


def eprint(message: str) -> None:
    print(f"[signage-fetch] {message}", file=sys.stderr)


def read_url(url: str, timeout: int) -> bytes:
    req = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=timeout) as response:
            return response.read()
    except HTTPError as exc:
        eprint(f"HTTP error {exc.code} {exc.reason!s} while fetching {url}")
        raise SystemExit(10)
    except URLError as exc:
        eprint(f"URL error while fetching {url}: {exc.reason!s}")
        raise SystemExit(11)
    except TimeoutError:
        eprint(f"Timeout while fetching {url}")
        raise SystemExit(12)


def normalize_base_url(url: str) -> str:
    return url if url.endswith("/") else f"{url}/"


def parse_listing(base_url: str, html: bytes) -> list[str]:
    parser = DirectoryListingParser()
    try:
        parser.feed(html.decode("utf-8", errors="replace"))
    except Exception as exc:  # pragma: no cover - defensive guard
        eprint(f"Could not parse directory listing HTML: {exc}")
        raise SystemExit(13)
    return [urljoin(base_url, href) for href in parser.hrefs]


def extension_set(raw: str) -> set[str]:
    return {part.strip().lower().lstrip(".") for part in raw.split() if part.strip()}


def is_direct_child(base_url: str, candidate_url: str) -> bool:
    base = urlparse(base_url)
    candidate = urlparse(candidate_url)

    if candidate.scheme not in {"http", "https"}:
        return False
    if candidate.scheme != base.scheme or candidate.netloc != base.netloc:
        return False

    base_path = base.path if base.path.endswith("/") else f"{base.path}/"
    if not candidate.path.startswith(base_path):
        return False

    relative = candidate.path[len(base_path):]
    if not relative or relative.endswith("/"):
        return False
    return "/" not in relative.strip("/")


def filename_from_url(url: str) -> str:
    parsed = urlparse(url)
    name = unquote(posixpath.basename(parsed.path))
    if not name or name in {".", ".."}:
        raise ValueError("empty filename")
    if "/" in name or "\x00" in name or "\n" in name or "\r" in name:
        raise ValueError(f"unsafe filename: {name!r}")
    return name


def has_allowed_extension(url: str, extensions: set[str]) -> bool:
    suffix = posixpath.splitext(urlparse(url).path)[1].lower().lstrip(".")
    return suffix in extensions


def discover_candidates(base_url: str, html: bytes, extensions: set[str]) -> list[tuple[str, str]]:
    urls = parse_listing(base_url, html)
    candidates: list[tuple[str, str]] = []
    seen_names: set[str] = set()

    for url in urls:
        if not is_direct_child(base_url, url):
            continue
        if not has_allowed_extension(url, extensions):
            continue
        try:
            name = filename_from_url(url)
        except ValueError as exc:
            eprint(str(exc))
            raise SystemExit(14)
        key = name.casefold()
        if key in seen_names:
            eprint(f"Duplicate image filename in listing: {name}")
            raise SystemExit(15)
        seen_names.add(key)
        candidates.append((name, url))

    candidates.sort(key=lambda item: item[0].casefold())
    return candidates


def download_file(url: str, dest: Path, timeout: int) -> None:
    req = Request(url, headers={"User-Agent": USER_AGENT})
    tmp_path = dest.with_suffix(dest.suffix + ".partial")
    try:
        with urlopen(req, timeout=timeout) as response, tmp_path.open("wb") as out:
            shutil.copyfileobj(response, out)
        tmp_path.replace(dest)
    except HTTPError as exc:
        eprint(f"HTTP error {exc.code} {exc.reason!s} while downloading {url}")
        tmp_path.unlink(missing_ok=True)
        raise SystemExit(16)
    except URLError as exc:
        eprint(f"URL error while downloading {url}: {exc.reason!s}")
        tmp_path.unlink(missing_ok=True)
        raise SystemExit(17)
    except TimeoutError:
        eprint(f"Timeout while downloading {url}")
        tmp_path.unlink(missing_ok=True)
        raise SystemExit(18)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_fetch_manifest(dest: Path, candidates: Iterable[tuple[str, str]]) -> None:
    lines = []
    for name, url in candidates:
        path = dest / name
        if path.exists():
            lines.append(f"{sha256_file(path)}  {name}\t{url}")
    (dest / ".fetch-manifest.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch signage images from an HTTP directory listing.")
    parser.add_argument("--url", required=True, help="HTTP/HTTPS directory listing URL")
    parser.add_argument("--dest", required=True, help="Destination directory")
    parser.add_argument("--extensions", required=True, help="Space-separated filename extensions")
    parser.add_argument("--timeout", type=int, default=30, help="HTTP timeout in seconds")
    args = parser.parse_args()

    base_url = normalize_base_url(args.url)
    extensions = extension_set(args.extensions)
    if not extensions:
        eprint("No image extensions configured")
        return 19

    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)

    index_html = read_url(base_url, args.timeout)
    candidates = discover_candidates(base_url, index_html, extensions)
    if not candidates:
        eprint(f"No candidate image links found at {base_url}")
        return 20

    with tempfile.TemporaryDirectory(prefix="signage-fetch-", dir=str(dest.parent)) as tmp_dir_str:
        tmp_dir = Path(tmp_dir_str)
        for name, url in candidates:
            download_file(url, tmp_dir / name, args.timeout)
        write_fetch_manifest(tmp_dir, candidates)

        # Move files into the final destination only after all downloads succeed.
        for item in tmp_dir.iterdir():
            item.replace(dest / item.name)

    print(f"[signage-fetch] Downloaded {len(candidates)} candidate image file(s) from {base_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
