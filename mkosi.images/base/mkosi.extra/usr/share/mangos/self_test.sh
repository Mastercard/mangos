#!/bin/bash
BASE_URL=${BASE_URL:-http://10.0.2.2:8081}
export BASE_URL

set -e
set -x

trap 'journalctl -n 1000 --no-pager' ERR
systemctl is-active systemd-veritysetup@root.service
systemctl is-active systemd-cryptsetup@swap.service
systemctl is-active systemd-cryptsetup@var.service
systemctl is-active systemd-cryptsetup@var\\x2dtmp.service
mangosctl bootstrap
mangosctl sudo enroll -g{vault-server,{nomad,consul}-{server,client}}s 127.0.0.1
mangosctl sudo -- nomad job run -detach /usr/share/mangos/test.nomad

echo "Waiting for job allocation to start..."
echo "Current time: $(date)"
tries=60
success=0

# Temporarily disable exit-on-error for polling loop
set +e

while [ $tries -gt 0 ]
do
        # Get allocation status first
        alloc_status=$(mangosctl sudo -- nomad job allocs -namespace=admin -json test 2>/dev/null | jq -r '.[0].ClientStatus // empty')
        
        if [ -n "$alloc_status" ]; then
                echo "[$(date +%H:%M:%S)] Allocation status: $alloc_status"
        else
                echo "[$(date +%H:%M:%S)] No allocation yet..."
        fi
        
        # Check if logs are available and contain SUCCESS
        if mangosctl sudo -- nomad alloc logs -namespace=admin -task server -job test 2>/dev/null | grep -q SUCCESS
        then
                echo "Test job completed successfully!"
                success=1
                break
        fi
        
        # If allocation failed, break early
        if [ "$alloc_status" = "failed" ]; then
                echo "Allocation failed, breaking loop"
                break
        fi
        
        tries=$((tries - 1))
        echo "[$(date +%H:%M:%S)] Waiting... ($tries attempts remaining)"
        sleep 10
done

# Re-enable exit-on-error
set -e

if [ $success -eq 0 ]
then
        echo "Test job did not complete successfully after 10 minutes"
        echo "=== Job Status ==="
        mangosctl sudo -- nomad job status -namespace=admin test || true
        echo "=== Allocation Logs ==="
        mangosctl sudo -- nomad alloc logs -namespace=admin -task server -job test 2>&1 || true
        echo "=== Allocation Status ==="
        alloc_id=$(mangosctl sudo -- nomad job allocs -namespace=admin -json test 2>/dev/null | jq -r '.[0].ID // empty')
        if [ -n "$alloc_id" ]; then
                mangosctl sudo -- nomad alloc status -namespace=admin "$alloc_id" || true
        else
                echo "No allocations found for job"
        fi
        exit 1
fi

echo "===> Validating Recovery Keys"
machine_id=$(cat /etc/machine-id)

# Auto-detect LUKS partitions
luks_partitions=$(lsblk -nlo NAME,TYPE,FSTYPE | awk '$2 == "part" && $3 == "crypto_LUKS" {print $1}')

if [ -z "$luks_partitions" ]; then
    echo "No LUKS partitions found, skipping recovery key validation"
else
    # Test 1: Verify recovery keys exist in Vault
    for device in $luks_partitions; do
        partition=$(lsblk -n -o PARTLABEL "/dev/$device" 2>/dev/null | tr -d ' \n\r\t')
        if ! mangosctl sudo -- vault kv get "secrets/mangos/recovery-keys/${machine_id}/${partition}" >/dev/null 2>&1; then
            echo "ERROR: Recovery key not found in Vault for ${partition}"
            exit 1
        fi
        echo "Recovery key for ${partition}: OK"
    done

    # Test 2: Verify LUKS has multiple keyslots (TPM + recovery)
    for device in $luks_partitions; do
        partition=$(lsblk -nlo PARTLABEL /dev/$device)
        slots=$(cryptsetup luksDump /dev/$device 2>/dev/null | grep -c "^  [0-9]: luks2" || echo 0)
        if [ "$slots" -lt 2 ]; then
            echo "ERROR: ${partition} has only ${slots} keyslot(s), expected at least 2 (TPM + recovery)"
            exit 1
        fi
        echo "LUKS keyslots for ${partition}: ${slots} OK"
    done

    echo "Recovery key validation: PASSED"
fi
