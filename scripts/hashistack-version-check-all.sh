#!/bin/bash

fmt="%-17s %-8s %-8s %-14s %s\n"

args="$(getopt -o '+f' --long 'fix' -n "$0" -- "$@")"

eval set -- "${args}"
while true
do
	case "$1" in
		-f|--fix)
			APPLY_FIX=1
			shift
			;;
		--)
			shift
			break
			;;
		*)
			echo "Error parsing arguments" >&2
			exit 1
			;;
	esac
done

fix=()

printf "${fmt}" "Component" "Latest" "Binary" "mkosi.version"

for component in consul{,-template} nomad terraform vault
do
	latest_release="$(curl https://github.com/hashicorp/${component}/releases/latest -w '%header{location}' -o /dev/null -s | sed -e s%.*/v%%g)"

	binary_version="$(mkosi.images/${component}/bin/${component} --version |& head -n1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
	binary_version="${binary_version#v}"

	from_mkosi_version="$(sed -e s%-.*%%g mkosi.images/${component}/mkosi.version)"

	info=""

	if [ "${latest_release}" != "${from_mkosi_version}" ] || [ "${binary_version}" != "${from_mkosi_version}" ]
	then

		fix+=( "rm -f ./${component}_*.zip" "rm mkosi.images/${component}/bin/${component}" "echo ${latest_release}-1 > mkosi.images/${component}/mkosi.version" )
		info="MISMATCH"
	fi
	printf "${fmt}" "${component}" "${latest_release}" "${binary_version}" "${from_mkosi_version}" "${info}"
done

if [ -n "${fix}" ]
then
	fix+=("./hashiext-download.sh")
	if [ -n "${APPLY_FIX}" ]
	then
		echo "Fixing automatically as requested"
		set -x
		for cmd in "${fix[@]}"
		do
			bash -c "${cmd}"
		done
	else
		echo "To fix this, either run these commands or pass --fix to $0 and it'll happen automatically:"
		for cmd in "${fix[@]}"
		do
			echo "${cmd}"
		done
	fi
fi
