#!/bin/bash
BASE_URL=${BASE_URL:-http://10.0.2.2:8081}
export BASE_URL

set -e

trap 'journalctl -n 1000 --no-pager' ERR
systemctl is-active systemd-veritysetup@root.service
systemctl is-active systemd-cryptsetup@swap.service
systemctl is-active systemd-cryptsetup@var.service
systemctl is-active systemd-cryptsetup@var\\x2dtmp.service
mangosctl bootstrap
mangosctl sudo enroll -g{vault-server,{nomad,consul}-{server,client}}s 127.0.0.1
mangosctl sudo -- nomad job run /usr/share/mangos/test.nomad
tries=10
while ! mangosctl sudo -- nomad alloc logs -namespace=admin -task server -job test | grep SUCCESS
do
        if [ $tries -le 0 ]
        then
                echo "Test job did not complete successfully"
                exit 1
        fi
        tries=$((tries - 1))
        echo "Sleeping 10 seconds."
        sleep 10
        echo "Trying again. $tries tries left"
done

echo "===> Validating Recovery Keys"
machine_id=$(cat /etc/machine-id)

# Auto-detect LUKS partitions
luks_partitions=$(lsblk -nlo NAME,TYPE,FSTYPE | awk '$2 == "part" && $3 == "crypto_LUKS" {print $1}' | tr '\n' ' ')

if [ -z "$luks_partitions" ]; then
    echo "No LUKS partitions found, skipping recovery key validation"
else
    # Test 1: Verify recovery keys exist in Vault
    for device in $luks_partitions; do
        partition=$(lsblk -nlo PARTLABEL /dev/$device | tr -d '\n')
        if ! mangosctl sudo -- vault kv get "secrets/mangos/recovery-keys/${machine_id}/${partition}" >/dev/null 2>&1; then
            echo "ERROR: Recovery key not found in Vault for ${partition}"
            exit 1
        fi
        echo "Recovery key for ${partition}: OK"
    done

    # Test 2: Verify LUKS has multiple keyslots (TPM + recovery)
    for device in $luks_partitions; do
        partition=$(lsblk -nlo PARTLABEL /dev/$device | tr -d '\n')
        slots=$(cryptsetup luksDump /dev/$device 2>/dev/null | grep -c "^  [0-9]: luks2" || echo 0)
        if [ "$slots" -lt 2 ]; then
            echo "ERROR: ${partition} has only ${slots} keyslot(s), expected at least 2 (TPM + recovery)"
            exit 1
        fi
        echo "LUKS keyslots for ${partition}: ${slots} OK"
    done

    echo "Recovery key validation: PASSED"
fi
