#!/bin/bash

DEFAULT_REGION=global
DEFAULT_DATACENTER=dc1

set -e

usage() {
	cat <<'EOF'
Usage: mangosctl [GLOBAL OPTIONS] {install|updatectl|enroll}

  bootstrap        - bootstrap a Mangos installation
  enroll           - generate a private key and CSR for this machine
  updatectl        - update an existing Mangos installation

Global options:
  -b, --base-url=URL       Base URL to download Mangos components from.
  -c, --ca-cert=FILE       CA certificate to use when interacting with Mangos cluster
  -v, --version=VERSION    Version of Mangos to assume. Default is $IMAGE_VERSION /etc/os-release

SUBCOMMANDS

  SYNOPSIS
  
  mangosctl [OPTS] bootstrap [-r|--region REGION] [--datacenter DATACENTER] [--clean]

  PURPOSE
  
  Bootstraps a new Mangos cluster on this node.

  OPTIONS:
    -r, --region=REGION          Set the region for the mangos installation (default: global)
    -d, --datacenter=DATACENTER  Set the datacenter for the mangos installation (default: dc1)
    --clean                      Clean up any existing mangos installation before bootstrapping

-----------------------------------------------------------------------------------------------

  SYNOPSIS
  
  mangosctl [OPTS] enroll [-gGROUP|--group GROUP] [-r|--region REGION] [--datacenter DATACENTER]
  
  Enrolls this node into an existing Mangos cluster.

  OPTIONS:
    -gGROUP, --group=GROUP        Add this node to GROUP (can be specified multiple times)
    -rREGION, --region=REGION     Specify the region for this node
    -dDATACENTER, --dc=DATACENTER Specify the datacenter for this node

  Examples:

    Bootstrap cluster and enroll node:

      mangosctl bootstrap -r us-west1 -d dc1
      mangosctl enroll    -r us-west1 -d dc1 -g{vault-server,{nomad,consul}-{server,client}}s 127.0.0.1

-----------------------------------------------------------------------------------------------

  SYNOPSIS
  
  mangosctl [OPTS] updatectl <subsubcommand>

  Keep Mangos system up-to-date
  
  Subcommands:
    mangosctl updatectl enable-verification  Enable verification of updates
    mangosctl updatectl disable-verification Disable verification of updates
    mangosctl updatectl enable FEATURE       Enable a sysupdate feature
    mangosctl updatectl disable FEATURE      Disable a sysupdate feature
    mangosctl updatectl ARGS...              Call `updatectl ARGS...`, refresh sysext and
                                             confext afterwards

  
EOF
	exit 1
}

main() {
	args="$(getopt -o '+b:c:v:' --long 'base-url:,ca-cert:,version:' -n 'mangosctl' -- "$@")"
	if [ $? != 0 ]
	then
		echo "Error parsing arguments" >&2
		usage
	fi

	eval set -- "${args}"
	while true
	do
		case "$1" in
			-b|--base-url)
				BASE_URL="$2"
				shift 2
				;;
			-c|--ca-cert)
				CA_CERT="$2"
				shift 2
				;;
			-v|--version)
				MANGOS_VERSION="$2"
				shift 2
				;;
			--)
				shift
				break
				;;
			*)
				echo "Error parsing arguments" >&2
				usage
				;;
		esac
	done

	if [ -z "${MANGOS_VERSION}" ]
	then
		MANGOS_VERSION="$(. /etc/os-release; echo ${IMAGE_VERSION})"
	fi

	if [ -z "${BASE_URL}" ]
	then
		BASE_URL="$(. /etc/os-release ; echo ${MKOSI_SERVE_URL})"
	fi

	case "$1" in
		install)
			shift
			do_install
			;;
		updatectl)
			shift
			do_updatectl "$@"
			;;
		group)
			shift
			do_group "$@"
			;;
		entity)
			shift
			do_entity "$@"
			;;
		addext)
			shift
			do_addext "$@"
			;;
		enroll)
			shift
			do_enroll "$@"
			;;
		bootstrap)
			shift
			do_bootstrap "$@"
			;;
		adduser)
			shift
			username="$1"
			read -sp "Password for new user ${username}: " password
			echo
			read -sp "Confirm password: " password2
			echo
			pwdfile=$(mktemp)
			cat > "${pwdfile}" <<<"${password}"
			if [ "${password}" != "${password2}" ]
			then
				echo "Passwords do not match" >&2
				exit 1
			fi
			run_vault write auth/userpass/users/${username} password=@${pwdfile}
			rm ${pwdfile}
			;;
		vault)
			shift
			run_vault "$@"
			;;
		nomad)
			shift
			run_nomad "$@"
			;;
		terraform)
			shift
			VAULT_ADDR=https://127.0.0.1:8200/ \
			VAULT_TLS_SERVER_NAME=vault.service.consul \
			VAULT_CACERT=/var/lib/vault/ssl/ca.pem \
			VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
			CONSUL_HTTP_TOKEN=$(run_vault read -field=token consul/creds/management) \
			run_terraform "$@"
			;;
		"")
			echo "No subcommand specified"
			usage
			;;
		*)
			echo "Unknown subcommand $1"
			usage
			;;
	esac
}

green() {
    echo -ne "\033[0;32m$*\033[0m"
}

greenln() {
    green "$@"
    echo
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


# Determine if this system is booted in EFI mode
is_efi() {
	test -d /sys/firmware/efi
}

# Convert a CIDR prefix length to a netmask. E.g.:
# 32 -> 255.255.255.255
# 31 -> 255.255.255.254
# ...
# 0  -> 0.0.0.0
prefix_to_netmask() {
	bits=$(($1))
	rv=''

	bits_to_mask=(0 128 192 224 240 248 252 254 255)

	octets=0
	while [ $octets -lt 4 ]
	do
		octets=$(($octets + 1))

		if [ $bits -ge 8 ]
		then
			rv="${rv}255."
		elif [ $bits -le 0 ]
		then
			rv="${rv}0."
		else
			rv="${rv}${bits_to_mask[$bits]}."
		fi
		bits=$(($bits - 8))
	done
	echo "${rv%.}"
}

# Generate an "ip=" argument suitable for passing to the kernel command line
ip_arg_for_default_interface() {
	read _ _ gw _ dev _ ip _ < <(ip -o route get 8.8.8.8)
	prefix="$(ip -o addr show dev $dev | grep ' inet ' | head -n 1 | grep -Eo '/[0-9]+' | cut -f2 -d/)"
	netmask=$(prefix_to_netmask $prefix)
	printf '%s::%s:%s:%s:%s:none' "${ip}" "${gw}" "${netmask}" "$(hostname)" "${dev}"
}

# Extract the first nameserver from /etc/resolv.conf
nameserver() {
	grep nameserver /etc/resolv.conf | awk -- '{ print $2 }'
}

# Install mangos on a BIOS (i.e. non-EFI) system
#
# Downloads Mangos kernel and initrd, shoves an entry in to grub, and reboots.
#
# A lot of unsound assumptions are made here (e.g. the grub directory). Please adjust to
# accommodate other layouts and configurations.
bios_install() {
	wget "${BASE_URL}/mangos-installer_${MANGOS_VERSION}.vmlinuz" -O /boot/mangos.vmlinuz
	wget "${BASE_URL}/mangos-installer_${MANGOS_VERSION}.initrd" -O /boot/mangos.initrd
	cat >> /etc/grub.d/40_custom <<EOF
menuentry "mangos-install" {
    echo "Loading kernel"
    linux /mangos.vmlinuz ip=$(ip_arg_for_default_interface) nameserver=$(nameserver) mangos_install_target=ask mangos_install_source=${BASE_URL}/mangos_${MANGOS_VERSION}.raw.gz
    echo "Loading initrd"
    initrd /mangos.initrd
    echo "Booting"
}
EOF
	grub2-mkconfig | tee /boot/grub2/grub.cfg
	grub2-reboot mangos-install
	echo "Sleeping 5 seconds before rebooting into mangos-install. CTRL-C to abort."
	sleep 5
	sync; sync; systemctl reboot
}

do_step() {
	step "$1"
	shift
	"$@"
	if [ $? -eq 0 ]
	then
		success
	else
		failure
		exit 1
	fi
}

do_install() {
	if is_efi
	then
		efi_install
	else
		bios_install
	fi
}

# Enroll recovery keys for encrypted partitions and store them in Vault
enroll_recovery_keys() {
	local vault_token="$1"
	local machine_id="$(cat /etc/machine-id)"
	local found_any=0

	# Find all LUKS-encrypted partitions
	local devices=($(lsblk -ln -o NAME,TYPE,FSTYPE | awk '$2=="part" && $3=="crypto_LUKS" {print "/dev/"$1}'))

	for device in "${devices[@]}"; do
		local partlabel=$(lsblk -n -o PARTLABEL "$device" 2>/dev/null | tr -d ' \n\r\t')

		# Skip if no valid partition label
		if [ -z "$partlabel" ]; then
			continue
		fi

		# Skip if recovery key already exists in Vault
		if VAULT_TOKEN="${vault_token}" vault kv get "secrets/mangos/recovery-keys/${machine_id}/${partlabel}" >/dev/null 2>&1; then
			continue
		fi

		found_any=1
		step "Enrolling recovery key for ${partlabel}"

		# Generate and enroll recovery key (systemd-cryptenroll generates and prints the key)
		# Use TPM to unlock the device, then enroll a new recovery key
		local output=$(systemd-cryptenroll "${device}" --recovery-key --unlock-tpm2-device=auto 2>&1)

		# Extract recovery key - format: 6 lowercase alphanumeric groups of 8, separated by dashes
		# Example: etklvner-lblhnbgl-kdtnujtk-ikjlgbur-lnlrjrrc-iuikkidg-feientnn-dkjeeuft
		LUKS_RECOVERY_KEY_REGEX='[a-z0-9]{8}(-[a-z0-9]{8}){7}'
		local recovery_key=$(echo "$output" | grep -oE "${LUKS_RECOVERY_KEY_REGEX}" | head -n 1)

		if [ -n "$recovery_key" ] && [[ "$recovery_key" =~ ^${LUKS_RECOVERY_KEY_REGEX}$ ]]; then
			VAULT_TOKEN="${vault_token}" vault kv put "secrets/mangos/recovery-keys/${machine_id}/${partlabel}" \
				key="${recovery_key}" hostname="${HOSTNAME}" device="${device}" created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			if [ $? -eq 0 ]; then
				greenln Success
			else
				red "Failed to store in Vault"
				echo
			fi
		else
			red "Failed to enroll or extract recovery key"
			echo
		fi
	done

	if [ $found_any -eq 0 ]; then
		echo " > All recovery keys already enrolled"
	else
		echo " > Recovery keys enrolled and stored in Vault"
	fi
}

do_enroll() {
	declare -A groups

	if [ -z "${REGION}" ]
	then
		REGION="$(. /etc/environment.d/20-mangos.conf ; echo ${NOMAD_REGION})"
	fi

	if [ -z "${DATACENTER}" ]
	then
		DATACENTER="$(. /etc/environment.d/20-mangos.conf ; echo ${NOMAD_DATACENTER})"
	fi

	args="$(getopt -o 'g:r:d:' --long 'group:,region:,dc:,datacenter:' -n 'mangosctl enroll' -- "$@")"
	if [ $? != 0 ]
	then
		echo "Error parsing arguments" >&2
		usage
	fi

	eval set -- "${args}"
	while true
	do
		case "$1" in
			-g|--group)
				groups[$2]=1
				shift 2
				;;
			-r|--region)
				REGION="$2"
				shift 2
				;;
			-d|--dc|--datacenter)
				DATACENTER="$2"
				shift 2
				;;
			--)
				shift
				break
				;;
			*)
				echo "Error parsing arguments" >&2
				usage
				;;
		esac
	done

	if [ $# -ne 1 ]
	then
		echo "Usage: $0 enroll [[--group GROUP] [--group GROUP]...] CONSUL_RETRY_JOIN" >&2
		exit 1
	fi

	confext_dir="/var/lib/confexts/${HOSTNAME}"

	mkdir -p ${confext_dir}/etc/{extension-release,environment}.d
	echo 'ID=_any' > ${confext_dir}/etc/extension-release.d/extension-release.${HOSTNAME}

	echo CONSUL_DATACENTER=${REGION}-${DATACENTER} >> ${confext_dir}/etc/environment.d/20-mangos.conf
	echo NOMAD_DATACENTER=${DATACENTER}            >> ${confext_dir}/etc/environment.d/20-mangos.conf
	echo NOMAD_REGION=${REGION}                    >> ${confext_dir}/etc/environment.d/20-mangos.conf

	step "Adding Vault CA cert to system CA bundle"
	localcerts=$(mktemp -d)
	mkdir -p ${confext_dir}/etc/ssl/certs
	vault read -format=raw pki-root/ca/pem > ${localcerts}/pki-root.crt
	chronic update-ca-certificates --etccertsdir ${confext_dir}/etc/ssl/certs --localcertsdir ${localcerts}
	rm ${confext_dir}/etc/ssl/certs/pki-root.pem
	cp ${localcerts}/pki-root.crt ${confext_dir}/etc/ssl/certs/pki-root.pem
	rm -rf ${localcerts}
	greenln Success

	mkdir -p ${confext_dir}/etc/credstore
	mkdir -p ${confext_dir}/etc/credstore.encrypted

	keyfile="${confext_dir}/etc/credstore.encrypted/mangos.key"
	csr="${confext_dir}/etc/credstore/mangos.csr"
	if ! [ -s "${keyfile}" ]
	then
		do_step "Generating private key" sh -c "openssl genrsa -quiet 2048 | systemd-creds encrypt - ${keyfile}"
	fi

	if ! [ -s "${csr}" ]
	then
		step "Generating Certificate Signing Request (CSR) $csr"
		openssl req -key <(systemd-creds decrypt "${keyfile}") -new -subj "/CN=${HOSTNAME}.mangos/" -out "${csr}"
		greenln Success
	fi

	step "Submitting CSR to Vault for signing"
	mkdir -p /var/lib/mangos
	vault write -field=certificate pki-nodes/sign/node-cert \
		csr=@${confext_dir}/etc/credstore/mangos.csr \
		common_name=${HOSTNAME}.mangos \
		ttl=72h \
		format=pem > /var/lib/mangos/mangos.crt
	greenln Success

	step "Authenticating to Vault using TLS certificate"
	# Use the issued certificate to authenticate to Vault
	# This both verifies that the auth method works, the node can authenticate,
	# AND it creates the identity entity for this node.
	NODE_VAULT_TOKEN=$(vault login -method=cert -path=node-cert -client-cert=/var/lib/mangos/mangos.crt -client-key=<(systemd-creds decrypt ${confext_dir}/etc/credstore.encrypted/mangos.key) -token-only)
	greenln Success

	step "Getting mount accessor for node-cert"
	node_auth_accessor=$(vault read -field=accessor sys/auth/node-cert)
	echo $node_auth_accessor

	step "Looking up entity name for this node"
	entity_name=$(vault write -field=name identity/lookup/entity alias_name=${HOSTNAME}.mangos alias_mount_accessor=${node_auth_accessor})
	echo $entity_name

	step "Setting machine-id as entity metadata"
	machine_id=$(cat /etc/machine-id)
	vault write identity/entity/name/${entity_name} metadata=machine_id="${machine_id}"
	greenln Success

	for group in ${!groups[@]}
	do
		do_step "Adding host to group '${group}'" chronic do_entity addgroup ${entity_name} ${group}
	done

	step "Issuing certificates for Consul and Nomad"
	mkdir -p /var/lib/consul/ssl
	chown -R consul:consul /var/lib/consul

	mkdir -p /var/lib/nomad/ssl
	chown -R nomad:nomad /var/lib/nomad

	CONSUL_DATACENTER=${REGION}-${DATACENTER} \
	NOMAD_REGION=${REGION} \
	NOMAD_DATACENTER=${DATACENTER} \
	consul-template -vault-renew-token=false -once \
		-config /usr/share/consul-template/conf/consul-certs.hcl \
		-config /usr/share/consul-template/conf/nomad-certs.hcl
	greenln Success

	argv=()

	# If we already have a keyring, no need to inject the current key
	if ! [ -s "/var/lib/consul/data/serf/local.keyring" ]
	then
		enckey=$(mktemp --suffix .json)
		chown consul:consul $enckey
		step "Fetching Consul gossip encryption key from Vault"
		vault read -field=encryption_key secrets/mangos/consul/gossip | jq -R '{encrypt:.}' > ${enckey}
		greenln Success
		argv+=(-config-file=${enckey})
	fi

	# If there's already an agent recovery token, we don't need to add a new one
	if ! [ -s "${confext_dir}/etc/credstore.encrypted/consul.agent_recovery" ]
	then
		step "Generating Consul agent recovery token"
		agent_recovery_token=$(systemd-id128 -u new)
		systemd-creds -H encrypt - ${confext_dir}/etc/credstore.encrypted/consul.agent_recovery <<<${agent_recovery_token}
		greenln Success
	fi

	if ! [ -e "/var/lib/consul/data/raft" ]
	then
		step "Initializing Consul client"
		chronic systemd-run \
			-u consul-bootstrap \
			--uid=consul \
			--gid=consul \
			-p "Type=notify" \
			-p "StateDirectory=consul/data consul/ssl" \
			-p "Conflicts=consul.service" \
			/usr/bin/consul agent \
			-retry-join ${1} \
			-config-dir=/usr/share/consul/ \
			-datacenter "${REGION}-${DATACENTER}" \
			"$argv[@]"
		greenln Success
	fi

	do_step "Starting Consul agent" chronic systemctl start consul

	step "Acquiring Consul management token"
	consul_mgmt_token=$(vault read -field=token consul/creds/management)
	greenln Success

	has_token() {
		jq -e ".$1" < /var/lib/consul/data/acl-tokens.json > /dev/null
	}

	if ! has_token agent
	then
		set_agent_token agent "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -node-identity $(hostname):${REGION}-${DATACENTER} -role-name=consul-agent -format=json |jq -r .SecretID)"
	fi

	if ! has_token default
	then
		set_agent_token default  "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-default -format=json | jq -r .SecretID)"
	fi

	if ! has_token replication
	then
		set_agent_token replication "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-replication -format=json | jq -r .SecretID)"
	fi

	if ! has_token config_file_service_registration
	then
		set_agent_token config_file_service_registration "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-registration -format=json | jq -r .SecretID)"
	fi

	if ! [ -s "${confext_dir}/etc/credstore.encrypted/nomad.consul_token" ]
	then
		argv=()

		if [ "${groups[nomad-servers]}" = "1" ]
		then
			argv+=(-service-identity nomad-server -policy-name nomad-server)
		fi

		if [ "${groups[nomad-clients]}" = "1" ]
		then
			argv+=(-service-identity nomad-client -policy-name nomad-client)
		fi

		step "Creating Consul token for Nomad agent"
		CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create \
			"${argv[@]}" \
			-description "Nomad server and/or client on $(hostname)" \
			-format=json | jq .SecretID -r | systemd-creds -H encrypt - ${confext_dir}/etc/credstore.encrypted/nomad.consul_token
		greenln Success
	fi

	do_step "Reloading confexts" chronic systemd-confext refresh --mutable=auto

	step "Merging /etc/environment.d/20-mangos.conf into /etc/environment"
	cat /etc/environment /etc/environment.d/20-mangos.conf | sort -u > ${confext_dir}/etc/environment.new
	mv ${confext_dir}/etc/environment.new ${confext_dir}/etc/environment
	greenln Success

	do_step "Reloading confexts" chronic systemd-confext refresh --mutable=auto

	do_step "Enrolling recovery keys for encrypted partitions" enroll_recovery_keys "${NODE_VAULT_TOKEN}"
}

do_group() {
	case "$1" in
		list)
			vault list identity/group/name
			;;
		*)
			echo "Unknown subcommand $1" >&2
			exit 1
			;;
	esac
}

do_entity() {
	case "$1" in
		list)
			vault list identity/entity/name
			;;
		addgroup)
			entity_name="$2"
			group_name="$3"
			if [ -z "$entity_name" -o -z "$group_name" ]
			then
				echo "Usage: $0 entity addgroup ENTITY GROUP" >&2
				exit 1
			fi
			entity_id=$(vault read -field=id identity/entity/name/${entity_name})
			members="$(vault read -format=json identity/group/name/${group_name} | jq -r '.data.member_entity_ids | join(",")')"
			if [ -z "${members}" ]
			then
				members="${entity_id}"
			else
				members="${members},${entity_id}"
			fi
			vault write identity/group/name/${group_name} member_entity_ids="${members}"
			;;
		*)
			echo "Unknown subcommand $1" >&2
			exit 1
			;;
	esac
}

enable_sysupdate_feature() {
	for feature in "$@"
	do
		mkdir -p "/run/sysupdate.d/${feature}.feature.d"
		echo -e '[Feature]\nEnabled=yes' > "/run/sysupdate.d/${feature}.feature.d/enable.conf"
	done
}

do_updatectl() {
	case "$1" in
		enable)
			shift
			enable_sysupdate_feature "$@"
			return
			;;
		disable-verification)
			for d in /usr/lib/sysupdate*.d/*.transfer
			do
				mkdir -p "/run/${d#/usr/lib/}.d"
				cat <<-EOF > "/run/${d#/usr/lib/}.d/no-verify.conf"
				[Transfer]
				Verify=no
				EOF
			done
			return
			;;
		add-overrides)
			for d in /usr/lib/sysupdate*.d/*.transfer
			do
				mkdir -p "/run/${d#/usr/lib/}.d"
				cat <<-EOF > "/run/${d#/usr/lib/}.d/source-path-override.conf"
				[Source]
				Path=${BASE_URL}/sysupdate$(grep 'Path=http:' ${d} | sed -e 's%\(.*\)/sysupdate%%g')
				EOF
			done
			return
			;;
		enable-verification)
			rm -f /run/sysupdate*.d/*.transfer.d/no-verify.conf
			return
			;;
	esac

	updatectl "$@"

	systemd-sysext refresh --mutable=auto
	systemd-confext refresh --mutable=auto
	systemctl daemon-reload

	if is_efi
	then
		return
	fi

	cat <<'EOF' > /boot/grub/grub.cfg
if [ -s $prefix/grubenv ]; then
  load_env
fi
if [ "${next_entry}" ] ; then
   set default="${next_entry}"
   set next_entry=
   save_env next_entry
   set boot_once=true
else
   set default="0"
fi
EOF

	# Add the snippets in reverse order.
	cat $(printf '%s\n' /boot/grub/mangos_*.grub.cfg | tac) >> /boot/grub/grub.cfg

	ip_arg="$(grep -oE 'ip=[^ ]+' /proc/cmdline)"
	nameserver_arg="$(grep -oE 'nameserver=[^ ]+' /proc/cmdline)"
	grub-editenv /boot/grub/grubenv set kernel_args="${ip_arg} ${nameserver_arg}"
}

chronic() {
	if [ "${VERBOSE}" != "" ]
	then
		"$@"
		return $?
	fi
	local tmp=$(mktemp)
	rv=0
	"$@" > ${tmp} 2>&1 || rv=$?

	if [ $rv -ne 0 ]
	then
		cat "${tmp}"
	fi
	rm -f ${tmp}
	return $rv
}

run_terraform() {
	VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
	nsenter -t $(pidof vault) -n \
	terraform -chdir=/var/lib/terraform "$@"
}

run_terraform_apply() {
	chronic run_terraform apply -input=false -auto-approve "$@"
}

do_bootstrap() {
	args="$(getopt -o 'g:r:d:' --long 'group:,region:,dc:,datacenter:,clean' -n 'mangosctl bootstrap' -- "$@")"

	# mangos.service Upholds the entire stack, so stop it while we bootstrap
	do_step "Stopping mangos service" chronic systemctl stop mangos

	eval set -- "${args}"
	while true
	do
		case "$1" in
			--region|-r)
				REGION="$2"
				shift 2
				;;
			--datacenter|--dc|-d)
				DATACENTER="$2"
				shift 2
				;;
			--clean)
				CLEANUP=1
				shift
				;;
			--)
				shift
				break
				;;
			*)
				echo "Unknown argument $1"
				usage
				exit 1
				;;
		esac
	done

	if [ -z "${REGION}" ]
	then
		REGION="${DEFAULT_REGION}"
	fi

	if [ -z "${DATACENTER}" ]
	then
		DATACENTER="${DEFAULT_DATACENTER}"
	fi

	export REGION DATACENTER

	# Clean up from previous runs
	if [ -n "$CLEANUP" ]
	then
		systemd-sysext unmerge
		systemd-confext unmerge
		systemctl daemon-reload
		systemctl stop vault vault-bootstrap consul consul-bootstrap nomad nomad-bootstrap || true
		shopt -s nullglob
		rm -rf /var/lib/{terraform,vault,consul,nomad,confexts} /var/lib/confexts/*/etc/credstore.encrypted/{consul,nomad,vault}.* /var/lib/private/{terraform,vault,consul,nomad}.* /run/{vault,nomad,consul}
		systemctl reset-failed
	fi

	echo "Downloading the full hashistack:"
	do_updatectl update host component:{consul,consul-template,nomad,terraform,vault}
	green Done
	echo 

	do_step "Merging Hashistack sysext" chronic systemd-sysext refresh --mutable=auto

	do_step "Reloading systemd" systemctl daemon-reload

	do_step "Reloading systemd-resolved" chronic systemctl reload systemd-resolved

	do_step "Bootstrapping vault" chronic systemd-run \
		-u vault-bootstrap \
		--uid=vault \
		--gid=vault \
		-p "Type=notify" \
		-p "StateDirectory=vault/raft vault/ssl" \
		-p "StateDirectoryMode=0700" \
		-p "RuntimeDirectory=vault" \
		-p "RuntimeDirectoryMode=0700" \
		-p "RuntimeDirectoryPreserve=yes" \
		-p "Conflicts=vault.service" \
		-p "PrivateNetwork=yes" \
		-p 'ExecStartPost=curl -X PUT -H "X-Vault-Request: true" -d "{\"secret_shares\":1,\"secret_threshold\":1}" http://127.0.0.1:8200/v1/sys/init -o ${RUNTIME_DIRECTORY}/init.json' \
		/usr/bin/vault server -config=/usr/share/vault-bootstrap

	confext_dir="/var/lib/confexts/${HOSTNAME}"
	mkdir -p ${confext_dir}/etc/extension-release.d
	echo 'ID=_any' > ${confext_dir}/etc/extension-release.d/extension-release.${HOSTNAME}
	mkdir -p ${confext_dir}/etc/credstore.encrypted

	do_step "Saving encrypted unseal key and root token" $SHELL <<-EOF
	jq -r '.keys[0]' /run/vault/init.json | systemd-creds -H encrypt - ${confext_dir}/etc/credstore.encrypted/vault.unseal_key
	jq -r '.root_token' /run/vault/init.json | systemd-creds -H encrypt - /var/lib/private/vault.root_token
	rm /run/vault/init.json
	EOF

	unseal_vault() {
		systemd-creds decrypt ${confext_dir}/etc/credstore.encrypted/vault.unseal_key | jq '{key:.}' -R | chronic curl --unix-socket /run/vault/vault.sock http://127.0.0.1:8200/v1/sys/unseal --data @- -X POST
	}
	do_step "Unsealing vault" unseal_vault

	do_step "Copying terraform files into place" $SHELL <<-EOF
	mkdir -p /var/lib/terraform
	cp /usr/share/terraform/* /var/lib/terraform
	EOF

	jq -n '{datacenter:env.DATACENTER,region:env.REGION}' > /var/lib/terraform/mangos.auto.tfvars.json

	do_step "Initializing terraform" chronic terraform -chdir=/var/lib/terraform init

	export VAULT_ADDR=http://127.0.0.1:8200

	do_step "Bootstrapping PKI infrastructure" run_terraform_apply -target=terraform_data.bootstrap-pki

	do_step "Issuing certificates for Vault, Consul, and Nomad" $SHELL <<-EOF

	mkdir -p /var/lib/vault/ssl
	chown -R vault:vault /var/lib/vault

	mkdir -p /var/lib/consul/ssl
	chown -R consul:consul /var/lib/consul

	mkdir -p /var/lib/nomad/ssl
	chown -R nomad:nomad /var/lib/nomad

	VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
	VAULT_ADDR=unix:///run/vault/vault.sock \
	CONSUL_DATACENTER=${REGION}-${DATACENTER} \
	CONSUL_SERVER=yes \
	VAULT_SERVER=yes \
	NOMAD_REGION=${REGION} \
	NOMAD_DATACENTER=${DATACENTER} \
	NOMAD_SERVER=yes \
	consul-template -vault-renew-token=false -once \
		-config /usr/share/consul-template/conf/vault-certs.hcl \
		-config /usr/share/consul-template/conf/consul-certs.hcl \
		-config /usr/share/consul-template/conf/nomad-certs.hcl
	EOF

	do_step "Refreshing confexts" chronic systemd-confext refresh --mutable=auto

	do_step "Restarting Vault in non-bootstrap mode" chronic systemctl start vault

	enckey=$(mktemp --suffix .json)
	do_step "Generating encryption key for Consul" $SHELL <<-EOF
	chown consul:consul $enckey
	consul keygen | jq -R '{encrypt:.}' > ${enckey}
	EOF

	do_step "Launching Consul in bootstrap mode" chronic systemd-run \
		-u consul-bootstrap \
		--uid=consul \
		--gid=consul \
		-p "Type=notify" \
		-p "StateDirectory=consul/data consul/ssl" \
		-p "Conflicts=consul.service" \
		/usr/bin/consul agent \
		-retry-join 127.0.0.1 \
		-config-dir=/usr/share/consul/ \
		-datacenter "${REGION}-${DATACENTER}" \
		-config-file=${enckey} -bootstrap -server

	mkdir -p ${confext_dir}/etc/environment.d
	echo CONSUL_DATACENTER=${REGION}-${DATACENTER} >> ${confext_dir}/etc/environment.d/20-mangos.conf
	echo NOMAD_DATACENTER=${DATACENTER}            >> ${confext_dir}/etc/environment.d/20-mangos.conf
	echo NOMAD_REGION=${REGION}                    >> ${confext_dir}/etc/environment.d/20-mangos.conf

	do_step "Waiting until this node is the Consul leader" $SHELL <<-EOF
	journalctl -u consul-bootstrap -f -I -n all | grep -q "cluster leadership acquired"
	EOF

	export VAULT_ADDR=https://127.0.0.1:8200
	export VAULT_TLS_SERVER_NAME=vault.service.consul
	export VAULT_CACERT=/var/lib/vault/ssl/ca.pem
	do_step "Bootstrapping Consul" chronic run_terraform_apply -target=terraform_data.consul-bootstrap

	step "Writing Consul gossip encryption key to Vault"
	jq -j .encrypt < ${enckey} | \
	VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
	chronic vault write secrets/mangos/consul/gossip encryption_key=-
	greenln Success

	step "Generating Consul agent recovery token"
	agent_recovery_token=$(systemd-id128 -u new)
	systemd-creds -H encrypt - ${confext_dir}/etc/credstore.encrypted/consul.agent_recovery <<<${agent_recovery_token}
	greenln Success

	do_step "Reloading confexts" chronic systemd-confext refresh --mutable=auto

	do_step "Launching Consul in non-bootstrap mode" chronic systemctl start consul

	step "Waiting until regaining Consul leadership"
	journalctl -u consul -f -I -n all | grep -q "cluster leadership acquired"
	greenln Success

	step "Acquiring Consul management token"
	consul_mgmt_token="$(VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) vault read -field=token consul/creds/management)"
	greenln Success

	step "Creating a base set of Consul ACL roles and policies"
	CONSUL_HTTP_TOKEN=${consul_mgmt_token} run_terraform_apply -target=terraform_data.consul-bootstrap-roles
	greenln Success

	set_agent_token agent                            "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -node-identity $(hostname):${REGION}-${DATACENTER} -role-name=consul-agent -format=json |jq -r .SecretID)"
	set_agent_token default                          "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-default -format=json | jq -r .SecretID)"
	set_agent_token replication                      "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-replication -format=json | jq -r .SecretID)"
	set_agent_token config_file_service_registration "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-registration -format=json | jq -r .SecretID)"

        step "Creating vault token" 
	CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create \
						-service-identity vault:${REGION}-${DATACENTER} \
						-format=json | jq -r .SecretID | systemd-creds -H encrypt - ${confext_dir}/etc/credstore.encrypted/vault.consul_token
	greenln Success

	echo VAULT_ADDR=https://vault.service.consul:8200 >> ${confext_dir}/etc/environment.d/20-mangos.conf

	do_step "Reloading confexts" chronic systemd-confext refresh --mutable=auto
	do_step "Restarting Vault" chronic systemctl restart vault

	step "Creating Consul token for Nomad server"
	CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create \
                        -service-identity nomad-server \
                        -service-identity nomad-client \
                        -policy-name nomad-server      \
                        -policy-name nomad-client      \
                        -description "Nomad Server/Client token on ${HOSTNAME}" \
                        -format=json | jq .SecretID -r | systemd-creds -H encrypt - ${confext_dir}/etc/credstore.encrypted/nomad.consul_token
	greenln Success

	do_step "Reloading confexts" chronic systemd-confext refresh --mutable=auto

	mkdir -p /run/nomad
	systemd-creds decrypt ${confext_dir}/etc/credstore.encrypted/nomad.consul_token | jq -R '{consul:{token:.}}' > /run/nomad/consul-agent.json

	chown nomad:nomad /run/nomad/consul-agent.json

	dc_and_region="$(mktemp --suffix .json)"
	chown nomad:nomad "${dc_and_region}"
	jq -n '{datacenter:env.DATACENTER,region:env.REGION}' > "${dc_and_region}"

	do_step "Launching Nomad in bootstrap mode" chronic systemd-run \
		-u nomad-bootstrap \
		--uid=nomad \
		--gid=nomad \
		-p "Type=notify" \
		-p "StateDirectory=nomad/data nomad/ssl" \
		-p "Conflicts=nomad.service" \
		/usr/bin/nomad agent -server -bootstrap-expect=1 \
			-config=/usr/share/nomad \
			-config=/run/nomad/consul-agent.json \
			-config="${dc_and_region}"

	step "Waiting until this node is the Nomad leader"
	journalctl -u nomad-bootstrap -f -I -n all | grep -q "cluster leadership acquired"
	greenln Success

	step "Waiting until Nomad is resolvable via Consul"
	while ! resolvectl query nomad.service.consul >/dev/null 2>&1
	do
		echo -n "."
		sleep 1
	done
	greenln Success

	echo   NOMAD_ADDR=https://nomad.service.consul:4646 >> ${confext_dir}/etc/environment.d/20-mangos.conf
	export NOMAD_ADDR=https://nomad.service.consul:4646
	export NOMAD_CACERT=/var/lib/nomad/ssl/ca.pem

	do_step "Reloading confexts" chronic systemd-confext refresh --mutable=auto

	do_step "Bootstrapping Nomad via Vault" chronic run_terraform_apply -target=vault_nomad_secret_role.management #vault_nomad_secret_backend.nomad

	do_step "Starting Nomad in non-bootstrap mode" chronic systemctl start nomad

	step "Waiting until Nomad is reachable again"

	while ! curl --cacert /var/lib/nomad/ssl/ca.pem -s https://nomad.service.consul:4646/ -o /dev/null
	do
		echo -n "."
		sleep 1
	done
	greenln Success

	nomad_mgmt_token="$(VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) vault read -field=secret_id nomad/creds/management)"
	NOMAD_TOKEN="${nomad_mgmt_token}" \
	CONSUL_HTTP_TOKEN=${consul_mgmt_token} \
	do_step "Final Terraform run" run_terraform_apply

	echo
	echo "Bootstrap complete! Next steps:"
	echo "  1. Run: mangosctl sudo enroll -g vault-server -g consul-server -g nomad-server 127.0.0.1"
	echo "  2. This will enroll the bootstrap node's identity and recovery keys"
	echo
}

set_agent_token() {
	do_step "Setting Consul $1 token" chronic consul acl set-agent-token -token-file <(systemd-creds decrypt /etc/credstore.encrypted/consul.agent_recovery) "$@"
}

run_vault() {
	VAULT_ADDR=https://127.0.0.1:8200/ \
	VAULT_TLS_SERVER_NAME=vault.service.consul \
	VAULT_CACERT=/var/lib/vault/ssl/ca.pem \
	VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
	vault "$@"
}

run_nomad() {
	set -e
	NOMAD_TOKEN=$(vault read -field=secret_id nomad/creds/${NOMAD_ROLE:-management}) nomad "$@"
}

do_addext() {
	args="$(getopt -o 'v:' --long 'version:' -n 'mangosctl addext' -- "$@")"
	if [ $? != 0 ]
	then
		echo "Error parsing arguments" >&2
		usage
	fi

	eval set -- "${args}"
	while true
	do
		echo "arg: $1"
		case "$1" in
			-v|--version)
				IMAGE_VERSION="$2"
				shift 2
				;;
			--)
				shift
				break
				;;
		esac
	done

	extname="$1"

	if [ -z "${extname}" ]
	then
		echo "No extension name specified" >&2
		usage
	fi

	if [ -z "${IMAGE_VERSION}" ]
	then
		image_file_name="${extname}.raw"
	else
		image_file_name="${extname}_${IMAGE_VERSION}.raw"
	fi

	wget --progress=dot:giga -O /var/lib/extensions/"${image_file_name}" "${BASE_URL}/${image_file_name}"
	systemd-sysext refresh --mutable=auto
}

if [ "$1" = "sudo" ]
then
	if [ -e "/var/lib/private/vault.root_token" ]
	then
		export VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token)
	else
		echo "Could not find root token" >&2
	fi

	if [ -e "/var/lib/vault/ssl/vault.crt" ]
	then
		export VAULT_CACERT=/var/lib/vault/ssl/ca.pem
		export NOMAD_CACERT=/var/lib/vault/ssl/ca.pem
	else
		echo "Could not find Vault CA certificate" >&2
	fi

	export VAULT_ADDR="${VAULT_ADDR:-https://vault.service.consul:8200/}"
	export NOMAD_ADDR="${NOMAD_ADDR:-https://nomad.service.consul:4646/}"

	if [ -n "$VAULT_TOKEN" ]
	then
		export CONSUL_HTTP_TOKEN=$(VAULT_TOKEN=$VAULT_TOKEN vault read -field=token consul/creds/management)
		export NOMAD_TOKEN=$(VAULT_TOKEN=$VAULT_TOKEN vault read -field=secret_id nomad/creds/management)
	fi
	shift
	if [ "$1" = "--" ]
	then
		shift
		exec "$@"
	fi
fi

main "$@"
