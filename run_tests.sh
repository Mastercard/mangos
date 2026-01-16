#!/bin/bash

set -e

green() {
    echo -ne "\033[0;32m$*\033[0m"
}

red() {
    echo -ne "\033[0;31m$*\033[0m"
}

bold() {
    echo -ne "\033[1m$*\033[0m"
}

step() {
    bold " > ${*}... "
}

success() {
    green "Success"
    echo
}

failure() {
    red "Failure"
    echo
}

report_outcome() {
    if [ $? -eq 0 ]; then
        success
    else
        failure
    fi
}

usage() {
    cat << EOF
Usage: ${0} [OPTIONS]

Test Mangos build in a QEMU VM.

Verifies:

* Secure Boot enrollment,
* base OS installation,
* encrypted storage setup,
* node authentication to Vault,
* Consul DNS resolution,
* running a docker container through Nomad,
* issuing Consul and Vault tokens to Nomad workloads,
* username/password authentication to Vault,
* successful application of all Terraform code.

OPTIONS:
    -h, --help              Show this help message and exit
    --test-id=ID            Specify a test ID (default: PID of $0)
    --gui                   Enable GUI mode (default: headless)
    --blockdev-type=TYPE    Specify block device type (virtio-blk-pci or nvme,
                            default: virtio-blk-pci)
    --no-self-test          Do not run self_test.sh after installation, only
                            check that we can SSH in.
    --no-asciinema          Disable asciinema recording (default: enabled if
                            asciinema is installed)
EOF
}

cols=120
rows=40
testid=$$
run_self_test=1
asciinema_rec=()
blockdev_type="virtio-blk-pci"

set -x
if which asciinema > /dev/null 2>&1
then
        asciinema_rec=("asciinema" "rec" "--append" "--cols" "${cols}" "--rows" "${rows}" "mangos-${testid}.acast" "-c")
fi

GUI=0

if ! args="$(getopt -o '+h,B' --long 'help,no-build,build,test-id:,gui,blockdev-type:,no-self-test,no-asciinema' -n "${0}" -- "$@")"
then
	echo "Error parsing arguments" >&2
	usage
fi

install_target="/dev/vdb"

eval set -- "${args}"
while true
do
	case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --blockdev-type)
            case "$2" in
                virtio-blk-pci)
                    install_target=/dev/vdb
                    ;;
                nvme)
                    install_target=/dev/nvme1n1
                    ;;
                *)
                    echo "Invalid block device type: $2" >&2
                    exit 1
                    ;;
            esac
            blockdev_type="${2}"
            shift 2
            ;;
        --test-id=)
            testid="${2}"
            shift 2
            ;;
        --gui)
            GUI=1
            shift
            ;;
        --no-asciinema)
            asciinema_rec=()
            shift
            ;;
        --no-self-test)
            run_self_test=0
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error parsing arguments!" >&2
            usage
            exit 1
            ;;
    esac
done

slice="mangos-test-${testid}.slice"

systemd_run() {
    systemd-run --user --slice "${slice}" "$@"
}

cleanup=()
# shellcheck disable=SC2154
trap 'echo exit code: $?; for cmd in "${cleanup[@]}"; do ${cmd}; done;' EXIT


cleanup+=("systemctl --user stop mangos-test-${testid}.slice")
cleanup+=("journalctl --no-pager --user -u ${slice}")

step 'Publish build to sysupdate dir'
SYSUPDATE_DISTDIR=$(pwd)/dist/sysupdate resources/publish-build
report_outcome

step 'Launch web server (mkosi serve)'
systemd_run -u "mangos-test-${testid}-serve" -q --working-directory "$(pwd)/dist" -- python3 -m http.server 8081
report_outcome

tmpdir="$(mktemp -d)"
cleanup+=("rm -rf ${tmpdir:?}")

cp /usr/share/OVMF/OVMF_VARS_4M.fd "${tmpdir}/efivars.fd"

tpmdir="${tmpdir}/tpm"
mkdir -p "${tpmdir}"

step "Prepping the TPM"
systemd_run -u "mangos-test-${testid}-tpm-prep" -q -d --wait -- \
    mkosi sandbox -- \
    swtpm_setup --tpm-state "${tpmdir}" \
        --tpm2 --pcr-banks sha256 \
        --display --config /dev/null
report_outcome

# Create a uuid for the VM's serial. It's used to generate the machine id.
# The machine ID is in turn used to generate partition UUID's for swap,
# /var, and /var/tmp, so it needs to remain consistent throughout the test.
uuid="$(uuidgen)"

target_disk="${tmpdir}/target_disk.raw"

# Current repart setup is something like:
# ESP: 1G
# GRUB partition: 1M (yes, M)
# 2 x root verity sets:
#   root-verity-sig: 16K (yes, K)
#   root-verity: 300M
#   root: 2G
# Swap: 4G
# /var/tmp: 4G minimum
# /var: 4G minimum
# Total: ~17.6GB
step Creating target disk
systemd_run -q -d --wait -- mkosi sandbox -- qemu-img create "${target_disk}" 30G
report_outcome

run() {
    blockdev_args=()
    sdrun_args=()
    smbios_args=()
    bootindex=1

    if ! args="$(getopt -o 'P' --long 'blockdev-type:,blockdev:,wait,smbios:' -- "$@")"
    then
        echo "Error parsing arguments" >&2
        exit 1
    fi

    eval set -- "${args}"

    while true
    do
        case "$1" in
            --blockdev)
                arg="${2}"
                src="${arg#*:}"
                id="${arg%%:*}"
                blockdev_args+=(
                    -blockdev "driver=raw,node-name=${id},discard=unmap,file.driver=file,file.filename=${src},file.aio=io_uring,cache.direct=yes,cache.no-flush=yes"
                    -device "${blockdev_type},drive=${id},serial=${id},bootindex=${bootindex}"
                )
                bootindex=$(( bootindex + 1 ))
                shift 2
                ;;
            --wait|-P)
                sdrun_args+=("$1")
                shift
                ;;
            --smbios)
                smbios_args+=("-smbios" "$2")
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Internal error! (${*})" >&2
                exit 1
                ;;
        esac
    done

    systemd_run -u "mangos-test-${testid}-swtpm" -q -d -- \
        mkosi sandbox -- \
        swtpm socket --tpmstate dir="${tpmdir}" --ctrl type=unixio,path="${tmpdir}/swtpm-sock" --tpm2

    # Give swtpm a chance to start?
    sleep 3

    # shellcheck disable=SC2054
    qemu_cmd=(
        mkosi box --
        qemu-system-x86_64
        -no-reboot
        -machine type=q35,smm=on,hpet=off
        -smp 2
        -m 2048M
        -object rng-random,filename=/dev/urandom,id=rng0
        -device virtio-rng-pci,rng=rng0,id=rng-device0
        -device virtio-balloon,free-page-reporting=on
        -no-user-config
        -nic user,model=virtio-net-pci
        -cpu host
        -accel kvm
        -device vhost-vsock-pci,guest-cid=42
    )

    cmdline_extra="systemd.wants=network.target module_blacklist=vmw_vmci systemd.tty.term.hvc0=xterm-256color systemd.tty.columns.hvc0=${cols} systemd.tty.rows.hvc0=${rows} ip=enc0:any ip=enp0s1:any ip=enp0s2:any ip=host0:any ip=none loglevel=4 SYSTEMD_SULOGIN_FORCE=1"

    if [ "${GUI}" -eq 0 ]
    then
        cmdline_extra="${cmdline_extra} systemd.tty.term.console=xterm-256color systemd.tty.columns.console=${cols} systemd.tty.rows.console=${rows} console=hvc0 TERM=xterm-256color"
        # shellcheck disable=SC2054
        qemu_cmd+=(
            -nographic
            -nodefaults
            -chardev stdio,mux=on,id=console,signal=off
            -device virtio-serial-pci,id=mkosi-virtio-serial-pci
            -device virtconsole,chardev=console
            -mon console
        )
    else
        # shellcheck disable=SC2054
        qemu_cmd+=(
            -device virtio-vga
            -nodefaults
            -display sdl,gl=on
            -audio driver=pipewire,model=virtio
        )
    fi

    # shellcheck disable=SC2054
    qemu_cmd+=(
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
        -drive if=pflash,format=raw,file="${tmpdir}/efivars.fd"
        -global ICH9-LPC.disable_s3=1
        -global driver=cfi.pflash01,property=secure,value=on
        -device virtio-scsi-pci,id=mkosi
    )

    qemu_cmd+=("${blockdev_args[@]}")

    # shellcheck disable=SC2054
    qemu_cmd+=(
        -chardev "socket,id=chrtpm,path=${tmpdir}/swtpm-sock"
        -tpmdev emulator,id=tpm0,chardev=chrtpm
        -device tpm-tis,tpmdev=tpm0
        -uuid "${uuid}"
        -smbios type=11,value=io.systemd.credential.binary:firstboot.locale=Qy5VVEYtOA==
        -smbios type=11,value=io.systemd.credential.binary:firstboot.timezone=QW1lcmljYS9Mb3NfQW5nZWxlcw==
        -smbios type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root="$(ssh-keygen -y -f mkosi.key | base64 -w 0)"
        -smbios type=11,value=io.systemd.credential.binary:vmm.notify_socket="$(echo -n vsock:2:23433 | base64 -w 0)"
        -smbios type=11,value=io.systemd.stub.kernel-cmdline-extra="${cmdline_extra}"
        -smbios type=11,value=io.systemd.boot.kernel-cmdline-extra="${cmdline_extra}"
        "${smbios_args[@]}"
    )

    printf '#!/bin/bash\n' > "${tmpdir}/qemu_cmd.sh"
    printf '%q ' "${qemu_cmd[@]}" >> "${tmpdir}/qemu_cmd.sh"
    chmod +x "${tmpdir}/qemu_cmd.sh"
    ls -l "${tmpdir}/qemu_cmd.sh"
    cat "${tmpdir}/qemu_cmd.sh"

    # sdrun_args may contain multiple arguments, so it needs to NOT be quoted
    # shellcheck disable=SC2086
    systemd_run -u "mangos-test-${testid}-qemu" -q -d --setenv={XAUTHORITY,DISPLAY,WAYLAND_DISPLAY} -E TERM=xterm-256color "${sdrun_args[@]}" -- \
        "${asciinema_rec[@]}" "${tmpdir}/qemu_cmd.sh"

    sleep 2
}

IMAGE_VERSION="$(mkosi summary --json | jq .Images[0].ImageVersion -r)"
installer="$(pwd)/out/mangos-installer_${IMAGE_VERSION}.raw"

step 'Run VM (Secure Boot enrollment)'
run --blockdev=installer:"${installer}" \
    --blockdev=persistent:"${target_disk}" --wait
report_outcome

step 'Verify Secure Boot is enabled'
mkosi box -- virt-fw-vars -i "${tmpdir}/efivars.fd" --output-json - | jq -e '.variables[] | select(.name=="SecureBootEnable") | .data=="01"'
report_outcome

varsjson="$(mktemp)"
jq -n '{variables:[{name:"LoaderEntryOneShot",guid:"4a67b082-0a4c-41cf-b6c7-440b29bb8c4f",attr:7,data:"'"$(echo "mangos_${IMAGE_VERSION}.efi@install" | tr -d '\n' | iconv -f utf-8 -t UCS2 | xxd -p | tr -d '\n' | tr 'a-f' 'A-F')"'0000"}]}' > "${varsjson}"
mkosi box -- virt-fw-vars --inplace "${tmpdir}/efivars.fd" --set-json "${varsjson}"
rm "${varsjson}"

step 'Run VM (install mangos)'
run --smbios "type=11,value=io.systemd.credential:mangos_install_target=${install_target}" \
    --blockdev=installer:"${installer}" \
    --blockdev=persistent:"${target_disk}" --wait
report_outcome

# Run/test
step 'Launch installed OS'
run --blockdev=persistent:"${target_disk}"
report_outcome

cat <<'EOF' > "${tmpdir}/is_ready.sh"
#!/bin/sh
if grep -q '^READY=1$'
then
    kill -2 ${SOCAT_PPID}
fi
exit 0
EOF
chmod +x "${tmpdir}/is_ready.sh"

# Exit status 130 means killed by signal 2 (SIGINT)
step 'Waiting for installed OS to be ready'
systemd_run -u "mangos-test-${testid}-socat" -d -p SuccessExitStatus=130 -q --wait -- \
    mkosi --debug sandbox -- socat VSOCK-LISTEN:23433,fork,socktype=5 EXEC:"${tmpdir}/is_ready.sh"
report_outcome

step ssh into VM

# Stream the remote self-test live to the workflow console
# Use direct ssh with forced pty and line-buffering to make output appear as it
# is produced. Run ssh in background and wait for it.
ssh_cmd=(ssh -tt -i ./mkosi.key
        -o UserKnownHostsFile=/dev/null
        -o StrictHostKeyChecking=no
        -o LogLevel=ERROR
        -o ProxyCommand="mkosi sandbox -- socat - VSOCK-CONNECT:42:%p"
        root@mkosi "if [ ${run_self_test} -eq 0 ]; then echo Skipping self test; exit 0 ; fi ; bash -lc 'stdbuf -oL mangosctl --base-url=http://10.0.2.2:8081 updatectl add-overrides ;  stdbuf -oL /usr/share/mangos/self_test.sh'")

# Run ssh in the foreground and stream directly to this process's stdout
stdbuf -oL "${ssh_cmd[@]}" 2>&1
ssh_rc=$?

if [ ${ssh_rc} -eq 0 ]; then
    success
    echo "Mangos test ${testid} succeeded" | systemd_run -q -u "mangos-test-${testid}-result" -- cat
else
    failure
    echo "Mangos test ${testid} failed" | systemd_run -q -u "mangos-test-${testid}-result" -- cat
    exit ${ssh_rc}
fi
