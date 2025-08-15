#!/usr/bin/env python3
import re
from flask import Flask, redirect
from github import Github, Auth
import github

sha256sums = ''

def os_release_to_dict(fname='/usr/lib/os-release'):
    result = {}
    with open(fname, 'r') as fp:
        for l in fp:
            if '=' in l:
                key, value = l.split('=', 1)
                result[key.strip()] = value.strip().strip('"')
    return result

os_release = os_release_to_dict()
if 'MANGOS_GITHUB_URL' in os_release:
    github_url = os_release['MANGOS_GITHUB_URL']
    repo_full = '/'.join(github_url.split('/')[-2:])

app = Flask(__name__)

def get_github_client() -> Github:
    """
    Initialize and return a GitHub client.
    Replace 'your_token_here' with your actual GitHub token.
    """
    return Github()

@app.route('/SHA256SUMS')
def sha256_sums() -> str:
    global sha256sums
    if sha256sums:
        return sha256sums

    g = get_github_client()
    repo = g.get_repo(repo_full, lazy=True)
    releases = repo.get_releases()
    for release in releases:
        for asset in release.raw_data['assets']:
            digest = asset["digest"]
            name = asset["name"]
            if digest.startswith("sha256:"):
                sha256sums += f'{digest[7:]} *{name}\n'

    return sha256sums

@app.route('/<path:filename>')
def file_content(filename: str) -> str:
    version = filename.split('_')[1]
    for ext in ['.gz', '.zst']:
        if version.endswith(ext):
            version = version[:-len(ext)]
            break

    for ext in ['.efi', '.cyclonedx.json', '.github.json', '.raw', '.spdx.json', '.syft.json']:
        if version.endswith(ext):
            version = version[:-len(ext)]
            break

    version = re.sub(r'\.root-x86-64(-verity(-sig)?)?\.[a-z0-9]{32}$', '', version)

    return redirect(f'{github_url}/releases/download/v{version}/filename')

def main():
    app.run(host='0.0.0.0', port=1002)

if __name__ == "__main__":
    main()
