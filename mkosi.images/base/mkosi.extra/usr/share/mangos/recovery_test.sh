#!/bin/bash

# set -e
set -x

machine_id=$(cat /etc/machine-id)

# Auto-detect first LUKS partition for testing
test_device=$(lsblk -nlo NAME,TYPE,FSTYPE | awk '$2 == "part" && $3 == "crypto_LUKS" {print $1; exit}')
if [ -z "$test_device" ]; then
    echo "No LUKS partitions found, skipping recovery test"
    exit 0
fi

test_partition=$(lsblk -nlo PARTLABEL /dev/$test_device | tr -d '\n')
mapper_name=$(lsblk -nlo NAME /dev/$test_device | awk 'NR==2')

echo "Testing recovery unlock for ${test_partition} (device: ${test_device}, mapper: ${mapper_name})..."

# Get recovery key from Vault
recovery_key=$(mangosctl sudo -- vault kv get -field=key "secrets/mangos/recovery-keys/${machine_id}/${test_partition}")

# Find TPM keyslot number
tpm_slot=$(cryptsetup luksDump /dev/$test_device | \
    awk '/Tokens:/,/Keyslots:/ {if (/systemd-tpm2/) found=1; if (found && /^  [0-9]+:/) {print $1; exit}}' | \
    tr -d ':')

echo "Removing TPM keyslot ${tpm_slot} (simulating TPM failure)..."
PASSWORD="$recovery_key" systemd-cryptenroll --wipe-slot=tpm2 /dev/$test_device


# Get mount point for this partition
mount_point=$(findmnt -n -o TARGET /dev/mapper/$mapper_name)

# Unmount and close
if [ -n "$mount_point" ]; then
    systemctl stop $(systemd-escape -p --suffix=mount "$mount_point")
fi
cryptsetup close $mapper_name

# THE CRITICAL TEST: Unlock with recovery key
echo "Unlocking with recovery key..."
echo -n "$recovery_key" | systemd-cryptsetup attach $mapper_name /dev/$test_device -

# Remount
if [ -n "$mount_point" ]; then
    mount /dev/mapper/$mapper_name "$mount_point"
fi

# Verify device is accessible
if [ ! -b /dev/mapper/$mapper_name ]; then
    echo "ERROR: Device not accessible after recovery"
    exit 1
fi

echo "Data accessible after recovery: OK"

# Re-enroll TPM (cleanup for future tests)
echo "Re-enrolling TPM keyslot..."
echo -n "$recovery_key" | systemd-cryptenroll /dev/$test_device \
    --tpm2-device=auto \
    --tpm2-pcrs=7 \
    --tpm2-public-key-pcrs=11 \
    --unlock-key-file=/dev/stdin

echo "Recovery test: PASSED"
