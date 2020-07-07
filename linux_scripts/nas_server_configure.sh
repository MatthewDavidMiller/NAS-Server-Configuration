#!/bin/bash

# Copyright (c) Matthew David Miller. All rights reserved.
# Licensed under the MIT License.
# Run with sudo. Do not run while logged into root.
# Configuration script for the Nas server.

# Get needed scripts
wget -O 'nas_server_scripts.sh' 'https://raw.githubusercontent.com/MatthewDavidMiller/NAS-Server-Configuration/stable/linux_scripts/nas_server_scripts.sh'

# Source functions
source nas_server_scripts.sh

# Default variables
release_name='stretch'
key_name='nas_key'
ip_address='10.1.10.4'
network_address='10.1.10.0'
subnet_mask='255.255.255.0'
gateway_address='10.1.10.1'
dns_address='1.1.1.1'
user='mary'
network_prefix='10.0.0.0/8'
ipv6_link_local_address='fe80::4'

# Call functions
lock_root
get_username
get_interface_name
configure_network "${ip_address}" "${network_address}" "${subnet_mask}" "${gateway_address}" "${dns_address}" "${interface}" "${ipv6_link_local_address}"
fix_apt_packages
install_nas_packages
configure_ssh
generate_ssh_key "${user_name}" "y" "n" "n" "${key_name}"
iptables_setup_base
iptables_allow_ssh "${network_prefix}" "${interface}"
iptables_allow_https "${network_prefix}" "${interface}"
iptables_allow_smb "${network_prefix}" "${interface}"
iptables_allow_netbios "${network_prefix}" "${interface}"
iptables_allow_icmp "${network_prefix}" "${interface}"
iptables_allow_loopback
iptables_set_defaults
configure_nas_scripts
apt_configure_auto_updates "${release_name}"
configure_openmediavault
create_user "${user}"
configure_samba
