#!/bin/bash

VAULT_VERSION=${VAULT_VERSION:-latest}
CONSUL_VERSION=${CONSUL_VERSION:-latest}
NOMAD_VERSION=${NOMAD_VERSION:-latest}
CONSUL_TEMPLATE_VERSION=${CONSUL_TEMPLATE_VERSION:-latest}
TERRAFORM_VERSION=${TERRAFORM_VERSION:-latest}

get_latest_version() {
    curl -s "https://api.github.com/repos/hashicorp/$1/releases/latest" | jq .name -r
}

download() {
    local name="$1"
    local version="$2"

    if [ "${version}" = "latest" ]; then
        version=$(get_latest_version "$name")
    fi

    version="${version#v}"

    origdir="$(pwd)"
    tmpdir=$(mktemp -d)
    cd "$tmpdir" || exit 1

    local url="https://releases.hashicorp.com/${name}/${version}/${name}_${version}_linux_amd64.zip"
    local fname="${url##*/}"
    wget -O "${fname}" "${url}"

    sha256sums=https://releases.hashicorp.com/${name}/${version}/${name}_${version}_SHA256SUMS
    sha256sums_sig=https://releases.hashicorp.com/${name}/${version}/${name}_${version}_SHA256SUMS.sig

    wget -O SHA256SUMS "${sha256sums}"
    wget -O SHA256SUMS.sig "${sha256sums_sig}"

    if ! gpg --verify --no-default-keyring --keyring ${origdir}/resources/hashicorp-signing-key.72D7468F.gpg SHA256SUMS.sig SHA256SUMS
    then
        echo "GPG signature verification failed!"
        exit 1
    fi

    echo "Verifying checksums..."
    if ! grep -E "${fname}$" SHA256SUMS | sha256sum -c
    then
        echo "Checksum verification failed!"
        exit 1
    fi
    mv "${fname}" "${origdir}"
    cd "${origdir}"
    rm -rf "${tmpdir}"
}

for tool in terraform vault nomad consul consul-template ; do
    v="${tool^^}_VERSION"
    v="${v//-/_}"
    mkdir -p mkosi.images/${tool}/bin
    if [ -f "mkosi.images/${tool}/bin/${tool}" ]
    then
        echo "Binary mkosi.images/${tool}/bin/${tool} already exists, skipping download/unzip"
        continue
    fi
    download "$tool" "${!v}"
    unzip ${tool}_*.zip -d mkosi.images/${tool}/bin ${tool}
done
