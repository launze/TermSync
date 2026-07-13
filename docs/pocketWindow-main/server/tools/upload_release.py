from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import sys
import urllib.parse

import requests


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Upload a PocketWindow release package.')
    parser.add_argument('--server', required=True, help='Server origin, e.g. http://192.168.31.77:58080')
    parser.add_argument('--platform', required=True, choices=['android', 'windows'])
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', type=int, default=1)
    parser.add_argument('--channel', default='stable')
    parser.add_argument('--title', default='')
    parser.add_argument('--notes', default='')
    parser.add_argument('--file', required=True, dest='file_path')
    parser.add_argument('--file-name', default='')
    parser.add_argument('--min-supported-version', default='')
    parser.add_argument('--force-update', action='store_true')
    parser.add_argument('--sha256', default='', help='Optional expected sha256. If omitted, compute locally.')
    parser.add_argument('--timeout', type=int, default=1800, help='Request timeout in seconds.')
    return parser.parse_args()


def normalize_server(value: str) -> str:
    server = str(value or '').strip().rstrip('/')
    if not server:
      raise SystemExit('server is required')
    if not server.startswith(('http://', 'https://')):
      server = f'http://{server}'
    return server


def compute_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as file:
        while True:
            chunk = file.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest().lower()


def main() -> int:
    args = parse_args()
    file_path = os.path.abspath(args.file_path)
    if not os.path.exists(file_path):
        raise SystemExit(f'file not found: {file_path}')

    file_name = args.file_name.strip() or os.path.basename(file_path)
    content_type = mimetypes.guess_type(file_name)[0] or 'application/octet-stream'
    sha256 = args.sha256.strip().lower() or compute_sha256(file_path)

    params = {
        'platform': args.platform,
        'version': args.version.strip(),
        'build': str(max(1, int(args.build))),
        'channel': args.channel.strip() or 'stable',
        'title': args.title.strip() or f'{args.platform} {args.version.strip()}',
        'notes': args.notes,
        'file_name': file_name,
        'sha256': sha256,
        'min_supported_version': args.min_supported_version.strip(),
        'force_update': 'true' if args.force_update else 'false',
    }
    query = urllib.parse.urlencode({key: value for key, value in params.items() if value != ''})
    url = f"{normalize_server(args.server)}/admin/releases/upload?{query}"

    print(f'Uploading {file_name}')
    print(f'  platform: {args.platform}')
    print(f'  version : {args.version}')
    print(f'  build   : {args.build}')
    print(f'  sha256  : {sha256}')
    print(f'  target  : {url}')

    with open(file_path, 'rb') as file:
        response = requests.post(
            url,
            data=file,
            headers={'Content-Type': content_type},
            timeout=(30, max(30, int(args.timeout))),
        )

    response.raise_for_status()
    try:
        payload = response.json()
    except Exception:
        payload = {'raw': response.text}
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
