#!/usr/bin/env bash
##
## name:    Api_Get_Networks
## desc:    Script gets network groups from json api
## version: 0.1.0
##
## usage:
## agn OPTION
## options:
##   -l location: RU NL US
##   -g group: Clients, Hostkey etc
##   -c config file location
##   -j JSON output format
##   -h print this message
##
## script needs a configuration file with parameters:
##   api_uri, api_user, api_pass
##

DECMAIL_TO_IP() {
	local ip dec=$@
	for e in {3..0}
	do
		((octet = dec / (256 ** e) ))
		((dec -= octet * 256 ** e))
		ip+=$delim$octet
		delim=.
	done
	printf '%s\n' "$ip"
}

GET_CIDR() {
	local net_addr=$1
	local bcast_addr=$2
	local net_size=$(($bcast_addr - $net_addr + 1))
	local degree=1

	while [[ $net_size -ne 2 ]]; do
		remain=$((${net_size}%2))
		if [[ $remain -ne 0 ]];then
			degree=$(($degree-1))
			break
		fi
		net_size=$((${net_size}/2))
		degree=$(($degree+1))
	done
	local cidr=$((32-$degree))
	printf '%s\n' "$cidr"
}

API_DATA() {
	local location=$1
	local group=$2

	local api_data=$(curl -s "${api_uri}/ip.php" -X POST \
	--data "action=list_range_ip"\
	--data "token=$api_token"\
	--data "location=$location" |\
	jq ".[] | select(.hidden!=1) | select(.groups==\"$group\") | {id, network, broadcast}" |\
	tr "\n" " " | sed 's/"//g;s/,//g;s/  //g;s/{//g' | tr '}' '\n' | sed 's/^ \+//')

	printf '%s\n' "$api_data"
}

API_AUTH() {
	local action=$1
	case $action in
	get_token)
		curl -s "${api_uri}/auth.php" -X POST --data "action=ipalogin&user=$api_user&password=$api_pass" |
		jq -r '.result.token'
		if [[ $! -ne 0 ]];then
			echo "api connection failed"
			exit 1
		fi
		;;
	logout)
		local result=$(curl -s "${api_uri}/auth.php" -X POST --data "action=logout&token=$api_token")
		if [[ $! -eq 0 ]];then
			echo "API: token $api_token expared"
		else
			echo "$result"
		fi
		;;
	*)
		echo "API: wrong method $action"
		exit 1
		;;
	esac
}

API_GET_SUBNET() {
	local api_data=$(
		curl -s "${api_uri}/ip.php" -X POST \
		--data "action=get_range_subnets"\
		--data "token=$api_token"\
		--data "id=$1" |\
		jq ".[] | {id, network, broadcast, gateway, description, vlan}" |\
		tr "\n" " " | sed 's/"//g;s/,//g;s/  //g;s/{//g' | tr '}' '\n' | sed 's/^ \+//')

	local last_subnet=$(printf '%s\n' "$api_data" | tail -1 | grep -Po "id: \d+" | grep -Po '\d+')

	printf "["
	while read -r line;do
		local subnet_id=$(echo $line | grep -Po "id: \d+" | grep -Po '\d+')
		local subnet_net=$(echo $line | grep -Po "network: \d+" | grep -Po '\d+')
		local subnet_bcast=$(echo $line | grep -Po "broadcast: \d+" | grep -Po '\d+')
		local subnet_gateway=$(echo $line | grep -Po "broadcast: \d+" | grep -Po '\d+')
		local subnet_description=$(echo $line | grep -Po "description: .+ vlan:" | tr ' ' '\n' | sed -n 2p)
		local subnet_vlan=$(echo $line | grep -Po "vlan: \d+" | grep -Po '\d+')
		local subnet_gw=$(DECMAIL_TO_IP $subnet_gateway)
		local subnet_addr=$(DECMAIL_TO_IP $subnet_net)
		local subnet_cidr=$(GET_CIDR $subnet_net $subnet_bcast)
		local subnet_full=${subnet_addr}/${subnet_cidr}
		if [[ $subnet_id -ne $last_subnet ]];then
			printf "{\"network\": \"%s\", \"gateway\": \"%s\", \"description\": \"%s\", \"vlan\": \"%s\"}, " \
			"$subnet_full" "$subnet_gw" "$subnet_description" "$subnet_vlan"
		else
			printf "{\"network\": \"%s\", \"gateway\": \"%s\", \"description\": \"%s\", \"vlan\": \"%s\"} " \
			"$subnet_full" "$subnet_gw" "$subnet_description" "$subnet_vlan"
		fi
	done < <(printf '%s\n' "$api_data")
	printf "]"
}

OUTPUT_JSON() {
	local elems=${!network_data[@]}
	local last_elem=$(echo "$elems" | awk '{print $NF}')
	local data=$(
	for elem in $elems; do
		if [[ ! "$elem" == "$last_elem" ]];then
			printf "{\"id\": %s, \"network\": \"%s\", \"subnet\": %s},\n"\
			"$elem" "${network_data[$elem]}" "$(API_GET_SUBNET $elem)"
		else
			printf "{\"id\": %s, \"network\": \"%s\", \"subnet\": %s}\n"\
			"$elem" "${network_data[$elem]}" "$(API_GET_SUBNET $elem)"
		fi
		done)
	echo "{ \"$location\": [ $data ] }"
}
USAGE() {
	echo
	awk '/^## usage:$/,/^##$/' $0 | sed 's/^##//;s/^ //;/^$/d'
	echo
}
while getopts "l:g:c:jh" opt; do
	case $opt in
	l)
		if [[ -z $location ]];then
			location=$OPTARG
		else
			echo "ERROR: only one arg location enabled"
			exit 1
		fi
		;;
	g)
		if [[ -z $group ]];then
			group=$OPTARG
		else
			echo "ERROR: only one arg group enabled"
			exit 1
		fi
		;;
	c)
		if [[ -z $configfile ]];then
			configfile=$OPTARG
		else
			echo "ERROR: only one arg configfile enabled"
			exit 1
		fi
		;;
	j)
		jsonout=1
		;;
	h)
		USAGE
		exit 0
		;;
	?)
		USAGE
		exit 1
		;;
	esac
done
if [[ -z $configfile ]]||[[ -z $group ]]||[[ -z $location ]];then
	USAGE
	exit 1
fi
if [[ -f $configfile ]];then
	. $configfile
else
	echo "ERROR: there are no config file $configfile"
	exit 1
fi
api_token=$(API_AUTH get_token)
while read -r line;do
	network_id=$(echo $line | grep -Po "id: \d+" | grep -Po '\d+')
	network_net=$(echo $line | grep -Po "network: \d+" | grep -Po '\d+')
	network_bcast=$(echo $line | grep -Po "broadcast: \d+" | grep -Po '\d+')
	networks+=($network_id)
	net_addr=$(DECMAIL_TO_IP $network_net)
	net_cidr=$(GET_CIDR $network_net $network_bcast)
	network_full=${net_addr}/${net_cidr}
	network_data[${network_id}]=$network_full
done < <(API_DATA $location $group)
if [[ -z $jsonout ]];then
	echo ${network_data[*]}
else
	echo $(OUTPUT_JSON ${network_data[@]})
fi
if [[ ! -z $api_token ]];then
	logout=$(API_AUTH logout)
fi
