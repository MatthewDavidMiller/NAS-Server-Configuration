#!/bin/bash

# Copyright (c) Matthew David Miller. All rights reserved.
# Licensed under the MIT License.

# Compilation of functions for the Nas Server.

function lock_root() {
    passwd --lock root
}

function get_username() {
    user_name=$(logname)
}

function get_interface_name() {
    interface="$(ip route get 8.8.8.8 | sed -nr 's/.*dev ([^\ ]+).*/\1/p')"
    echo "Interface name is ${interface}"
}

function configure_network() {
    # Parameters
    local ip_address=${1}
    local network_address=${2}
    local subnet_mask=${3}
    local gateway_address=${4}
    local dns_address=${5}
    local interface=${6}
    local ipv6_link_local_address=${7}

    # Configure ipv4 network
    # Add auto $interface if it is not in the file
    grep -q -E ".*auto ${interface}" '/etc/network/interfaces' || printf '%s\n' "auto ${interface}" >>'/etc/network/interfaces'

    # Replace iface $interface inet dhcp with iface $interface inet static
    sed -i -E -z "s,.*iface ${interface} inet dhcp.*,iface ${interface} inet static\naddress ${ip_address}\nnetwork ${network_address}\nnetmask ${subnet_mask}\ngateway ${gateway_address}\ndns-nameservers ${dns_address}," '/etc/network/interfaces'

    grep -q -E ".*iface ${interface} inet static.*" '/etc/network/interfaces' || cat <<EOF >>'/etc/network/interfaces'
iface ${interface} inet static
    address ${ip_address}
    network ${network_address}
    netmask ${subnet_mask}
    gateway ${gateway_address}
    dns-nameservers ${dns_address}
EOF

    grep -q -E ".*iface ${interface} inet6 static.*" '/etc/network/interfaces' || cat <<EOF >>'/etc/network/interfaces'

iface ${interface} inet6 static
    address ${ipv6_link_local_address}
    netmask 64
    scope link
EOF

    # Restart network interface
    ifdown "${interface}" && ifup "${interface}"
}

function fix_apt_packages() {
    dpkg --configure -a
}

function install_nas_packages() {
    apt-get update
    apt-get upgrade
    apt-get install -y wget vim git iptables iptables-persistent ntp ssh apt-transport-https openssh-server unattended-upgrades sudo
}

function configure_ssh() {
    # Turn off password authentication
    grep -q -E ".*PasswordAuthentication" '/etc/ssh/sshd_config' && sed -i -E "s,.*PasswordAuthentication.*,PasswordAuthentication no," '/etc/ssh/sshd_config' || printf '%s\n' 'PasswordAuthentication no' >>'/etc/ssh/sshd_config'

    # Do not allow empty passwords
    grep -q -E ".*PermitEmptyPasswords" '/etc/ssh/sshd_config' && sed -i -E "s,.*PermitEmptyPasswords.*,PermitEmptyPasswords no," '/etc/ssh/sshd_config' || printf '%s\n' 'PermitEmptyPasswords no' >>'/etc/ssh/sshd_config'

    # Turn off PAM
    grep -q -E ".*UsePAM" '/etc/ssh/sshd_config' && sed -i -E "s,.*UsePAM.*,UsePAM no," '/etc/ssh/sshd_config' || printf '%s\n' 'UsePAM no' >>'/etc/ssh/sshd_config'

    # Turn off root ssh access
    grep -q -E ".*PermitRootLogin" '/etc/ssh/sshd_config' && sed -i -E "s,.*PermitRootLogin.*,PermitRootLogin no," '/etc/ssh/sshd_config' || printf '%s\n' 'PermitRootLogin no' >>'/etc/ssh/sshd_config'

    # Enable public key authentication
    grep -q -E ".*AuthorizedKeysFile" '/etc/ssh/sshd_config' && sed -i -E "s,.*AuthorizedKeysFile\s*.ssh\/authorized_keys\s*.ssh\/authorized_keys2,AuthorizedKeysFile .ssh\/authorized_keys," '/etc/ssh/sshd_config' || printf '%s\n' 'AuthorizedKeysFile .ssh/authorized_keys' >>'/etc/ssh/sshd_config'
    grep -q -E ".*PubkeyAuthentication" '/etc/ssh/sshd_config' && sed -i -E "s,.*PubkeyAuthentication.*,PubkeyAuthentication yes," '/etc/ssh/sshd_config' || printf '%s\n' 'PubkeyAuthentication yes' >>'/etc/ssh/sshd_config'
}

function generate_ssh_key() {
    # Parameters
    local user_name=${1}
    local ecdsa_response=${2}
    local rsa_response=${3}
    local dropbear_response=${4}
    local key_name=${5}

    # Generate ecdsa key
    if [[ "${ecdsa_response}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
        # Generate an ecdsa 521 bit key
        ssh-keygen -f "/home/$user_name/${key_name}" -t ecdsa -b 521
    fi

    # Generate rsa key
    if [[ "${rsa_response}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
        # Generate an rsa 4096 bit key
        ssh-keygen -f "/home/$user_name/${key_name}" -t rsa -b 4096
    fi

    # Authorize the key for use with ssh
    mkdir "/home/$user_name/.ssh"
    chmod 700 "/home/$user_name/.ssh"
    touch "/home/$user_name/.ssh/authorized_keys"
    chmod 600 "/home/$user_name/.ssh/authorized_keys"
    cat "/home/$user_name/${key_name}.pub" >>"/home/$user_name/.ssh/authorized_keys"
    printf '%s\n' '' >>"/home/$user_name/.ssh/authorized_keys"
    chown -R "$user_name" "/home/$user_name"
    python -m SimpleHTTPServer 40080 &
    server_pid=$!
    read -r -p "Copy the key from the webserver on port 40080 before continuing: " >>'/dev/null'
    kill "${server_pid}"

    # Dropbear setup
    if [[ "${dropbear_response}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
        cat "/home/$user_name/${key_name}.pub" >>'/etc/dropbear/authorized_keys'
        printf '%s\n' '' >>'/etc/dropbear/authorized_keys'
        chmod 0700 /etc/dropbear
        chmod 0600 /etc/dropbear/authorized_keys
    fi
}

function configure_nas_scripts() {
    # Script to archive config files for backup
    wget 'https://raw.githubusercontent.com/MatthewDavidMiller/scripts/stable/linux_scripts/backup_configs.sh'
    mv 'backup_configs.sh' '/usr/local/bin/backup_configs.sh'
    chmod +x '/usr/local/bin/backup_configs.sh'

    # Configure cron jobs
    cat <<EOF >jobs.cron
* 0 * * 1 bash /usr/local/bin/backup_configs.sh &

EOF
    crontab jobs.cron
    rm -f jobs.cron
}

function apt_configure_auto_updates() {
    # Parameters
    local release_name=${1}

    sed -i -E -z "s,.*Unattended-Upgrade::Origins-Pattern.*\n.*\n.*\n.*\n.*,Unattended-Upgrade::Origins-Pattern {\n\"origin=Debian\,n=${release_name}\,l=Debian\";\n\"origin=Debian\,n=${release_name}\,l=Debian-Security\";\n\"origin=Debian\,n=${release_name}-updates\";\n};," '/etc/apt/apt.conf.d/50unattended-upgrades'
    grep -q -E ".*Unattended-Upgrade::Origins-Pattern.*" '/etc/apt/apt.conf.d/50unattended-upgrades' || cat <<EOF >>"/etc/apt/apt.conf.d/50unattended-upgrades"
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,n=${release_name},l=Debian";
        "origin=Debian,n=${release_name},l=Debian-Security";
        "origin=Debian,n=${release_name}-updates";
};
EOF

    sed -i -E "s,.*Unattended-Upgrade::Automatic-Reboot.*,Unattended-Upgrade::Automatic-Reboot \"true\";," '/etc/apt/apt.conf.d/50unattended-upgrades'
    grep -q -E ".*Unattended-Upgrade::Automatic-Reboot" '/etc/apt/apt.conf.d/50unattended-upgrades' || printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot "true";' >>'/etc/apt/apt.conf.d/50unattended-upgrades'

    sed -i -E "s,.*Unattended-Upgrade::Automatic-Reboot-Time.*,Unattended-Upgrade::Automatic-Reboot-Time \"04:00\";," '/etc/apt/apt.conf.d/50unattended-upgrades'
    grep -q -E ".*Unattended-Upgrade::Automatic-Reboot-Time" '/etc/apt/apt.conf.d/50unattended-upgrades' || printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' >>'/etc/apt/apt.conf.d/50unattended-upgrades'
}

function configure_openmediavault() {

    cat <<EOF >>'/etc/apt/sources.list.d/openmediavault.list'
deb https://packages.openmediavault.org/public usul main
# deb https://downloads.sourceforge.net/project/openmediavault/packages usul main
## Uncomment the following line to add software from the proposed repository.
# deb https://packages.openmediavault.org/public usul-proposed main
# deb https://downloads.sourceforge.net/project/openmediavault/packages usul-proposed main
## This software is not part of OpenMediaVault, but is offered by third-party
## developers as a service to OpenMediaVault users.
# deb https://packages.openmediavault.org/public usul partner
# deb https://downloads.sourceforge.net/project/openmediavault/packages usul partner

EOF

    cat <<\EOF >>'openmediavault_install.sh'

export LANG=C
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
apt-get update
apt-get --allow-unauthenticated install openmediavault-keyring
apt-get update
apt-get --yes --auto-remove --show-upgraded \
    --allow-downgrades --allow-change-held-packages \
    --no-install-recommends \
    --option Dpkg::Options::="--force-confdef" \
    --option DPkg::Options::="--force-confold" \
    install postfix openmediavault
# Initialize the system and database.
omv-initsystem

EOF
    bash 'openmediavault_install.sh'
}

function create_user() {
    # Parameters
    local user_name=${1}

    useradd -m "${user_name}"
    echo "Set the password for ${user_name}"
    passwd "${user_name}"
    mkdir -p "/home/${user_name}"
    chown "${user_name}" "/home/${user_name}"
}

# Customize based on use case
function configure_samba() {
    rm -f '/etc/samba/smb.conf'
    cat <<\EOF >>'/etc/samba/smb.conf'

[vm_backup]
path = /srv/dev-disk-by-label-Matthew_Backup/matt_files/vm_backup
guest ok = no
read only = no
browseable = yes
inherit acls = yes
inherit permissions = no
ea support = no
store dos attributes = no
vfs objects =
printable = no
create mask = 0664
force create mode = 0664
directory mask = 0775
force directory mode = 0775
hide special files = yes
follow symlinks = yes
hide dot files = yes
valid users = "matthew"
invalid users =
read list =
write list = "matthew"

[matt_files]
path = /srv/dev-disk-by-label-Matthew_Backup/matt_files
guest ok = no
read only = no
browseable = yes
inherit acls = yes
inherit permissions = no
ea support = no
store dos attributes = no
vfs objects =
printable = no
create mask = 0664
force create mode = 0664
directory mask = 0775
force directory mode = 0775
hide special files = yes
follow symlinks = yes
hide dot files = yes
valid users = "matthew"
invalid users =
read list =
write list = "matthew"

[maryicloudphotos]
path = /srv/dev-disk-by-label-Matthew_Backup/mary_backup/icloud photos
guest ok = no
read only = no
browseable = yes
inherit acls = yes
inherit permissions = no
ea support = no
store dos attributes = no
vfs objects =
printable = no
create mask = 0664
force create mode = 0664
directory mask = 0775
force directory mode = 0775
hide special files = yes
follow symlinks = yes
hide dot files = yes
valid users = "mary"
invalid users =
read list =
write list = "mary"

[maryiclouddrive]
path = /srv/dev-disk-by-label-Matthew_Backup/mary_backup/icloud drive
guest ok = no
read only = no
browseable = yes
inherit acls = yes
inherit permissions = no
ea support = no
store dos attributes = no
vfs objects =
printable = no
create mask = 0664
force create mode = 0664
directory mask = 0775
force directory mode = 0775
hide special files = yes
follow symlinks = yes
hide dot files = yes
valid users = "mary"
invalid users =
read list =
write list = "mary"

[public]
path = /srv/dev-disk-by-label-Matthew_Backup/public
guest ok = yes
guest only = yes
read only = no
browseable = yes
inherit acls = yes
inherit permissions = no
ea support = no
store dos attributes = no
vfs objects =
printable = no
create mask = 0664
force create mode = 0664
directory mask = 0775
force directory mode = 0775
hide special files = yes
follow symlinks = yes
hide dot files = yes

[matthew_versions]
path = /srv/dev-disk-by-label-Matthew_Backup/matthew_versions
guest ok = no
read only = no
browseable = yes
inherit acls = yes
inherit permissions = no
ea support = no
store dos attributes = no
vfs objects =
printable = no
create mask = 0664
force create mode = 0664
directory mask = 0775
force directory mode = 0775
hide special files = yes
follow symlinks = yes
hide dot files = yes
valid users = "matthew"
invalid users =
read list =
write list = "matthew"

[mary_versions]
path = /srv/dev-disk-by-label-Matthew_Backup/mary_versions
guest ok = no
read only = no
browseable = yes
inherit acls = yes
inherit permissions = no
ea support = no
store dos attributes = no
vfs objects =
printable = no
create mask = 0664
force create mode = 0664
directory mask = 0775
force directory mode = 0775
hide special files = yes
follow symlinks = yes
hide dot files = yes
valid users = "mary"
invalid users =
read list =
write list = "mary"

[mary_backup]
path = /srv/dev-disk-by-label-Matthew_Backup/mary_backup
guest ok = no
read only = no
browseable = yes
inherit acls = yes
inherit permissions = no
ea support = no
store dos attributes = no
vfs objects =
printable = no
create mask = 0664
force create mode = 0664
directory mask = 0775
force directory mode = 0775
hide special files = yes
follow symlinks = yes
hide dot files = yes
valid users = "mary"
invalid users =
read list =
write list = "mary"

EOF
}

function iptables_setup_base() {
    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Save rules
    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6
}

function iptables_set_defaults() {
    # Drop inbound by default
    iptables -P INPUT DROP
    ip6tables -P INPUT DROP

    # Allow outbound by default
    iptables -P OUTPUT ACCEPT
    ip6tables -P OUTPUT ACCEPT

    # Drop forwarding by default
    iptables -P FORWARD DROP
    ip6tables -P FORWARD DROP

    # Save rules
    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6
}

function iptables_allow_ssh() {
    # Parameters
    local source=${1}
    local interface=${2}
    local ipv6_link_local='fe80::/10'

    # Allow ssh from a source and interface
    iptables -A INPUT -p tcp --dport 22 -s "${source}" -i "${interface}" -j ACCEPT
    ip6tables -A INPUT -p tcp --dport 22 -s "${ipv6_link_local}" -i "${interface}" -j ACCEPT

    # Log new connection ips and add them to a list called SSH
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH
    ip6tables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH

    # Log ssh connections from an ip to 6 connections in 60 seconds.
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 6 --rttl --name SSH -j LOG --log-level info --log-prefix "Limit SSH"
    ip6tables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 6 --rttl --name SSH -j LOG --log-level info --log-prefix "Limit SSH"

    # Limit ssh connections from an ip to 6 connections in 60 seconds.
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 6 --rttl --name SSH -j DROP
    ip6tables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 6 --rttl --name SSH -j DROP

    # Save rules
    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6
}

function iptables_allow_https() {
    # Parameters
    local source=${1}
    local interface=${2}
    local ipv6_link_local='fe80::/10'

    # Allow https from a source and interface
    iptables -A INPUT -p tcp --dport 443 -s "${source}" -i "${interface}" -j ACCEPT
    ip6tables -A INPUT -p tcp --dport 443 -s "${ipv6_link_local}" -i "${interface}" -j ACCEPT

    # Save rules
    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6
}

function iptables_allow_smb() {
    # Parameters
    local source=${1}
    local interface=${2}
    local ipv6_link_local='fe80::/10'

    # Allow smb from a source and destination
    iptables -A INPUT -p tcp --dport 445 -s "${source}" -i "${interface}" -j ACCEPT
    ip6tables -A INPUT -p tcp --dport 445 -s "${ipv6_link_local}" -i "${interface}" -j ACCEPT

    # Save rules
    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6
}

function iptables_allow_netbios() {
    # Parameters
    local source=${1}
    local interface=${2}
    local ipv6_link_local='fe80::/10'

    # Allow netbios from a source and destination
    iptables -A INPUT -p tcp --dport 137:139 -s "${source}" -i "${interface}" -j ACCEPT
    ip6tables -A INPUT -p tcp --dport 137:139 -s "${ipv6_link_local}" -i "${interface}" -j ACCEPT

    # Save rules
    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6
}

function iptables_allow_icmp() {
    # Parameters
    local source=${1}
    local interface=${2}
    local ipv6_link_local='fe80::/10'

    # Allow icmp from a source and interface
    iptables -A INPUT -p icmp -s "${source}" -i "${interface}" -j ACCEPT
    ip6tables -A INPUT -p icmpv6 -s "${ipv6_link_local}" -i "${interface}" -j ACCEPT

    # Save rules
    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6
}

function iptables_allow_loopback() {
    iptables -A INPUT -s '127.0.0.0/8' -i 'lo' -j ACCEPT
    ip6tables -A INPUT -s '::1' -i 'lo' -j ACCEPT

    # Save rules
    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6
}

function log_rotate_configure() {
    # Parameters
    user_name=${1}

    apt-get install -y logrotate
    touch -a '/etc/logrotate.conf'
    mkdir -p "/home/$user_name/config_backups"
    cp '/etc/logrotate.conf' "/home/$user_name/config_backups/logrotate.conf.backup"
    grep -q -E "(^\s*[#]*\s*daily\s*$)|(^\s*[#]*\s*weekly\s*$)|(^\s*[#]*\s*monthly\s*$)" '/etc/logrotate.conf' && sed -i -E "s,(^\s*[#]*\s*daily\s*$)|(^\s*[#]*\s*weekly\s*$)|(^\s*[#]*\s*monthly\s*$),daily," '/etc/logrotate.conf' || printf '%s\n' 'daily' >>'/etc/logrotate.conf'
    grep -q -E "^\s*[#]*\s*minsize.*$" '/etc/logrotate.conf' && sed -i -E "s,^\s*[#]*\s*minsize.*$,minsize 100M," '/etc/logrotate.conf' || printf '%s\n' 'minsize 100M' >>'/etc/logrotate.conf'
    grep -q -E "^\s*[#]*\s*rotate\s*[0-9]*$" '/etc/logrotate.conf' && sed -i -E "s,^\s*[#]*\s*rotate\s*[0-9]*$,rotate 4," '/etc/logrotate.conf' || printf '%s\n' 'rotate 4' >>'/etc/logrotate.conf'
    grep -q -E "^\s*[#]*\s*compress\s*$" '/etc/logrotate.conf' && sed -i -E "s,^\s*[#]*\s*compress\s*$,compress," '/etc/logrotate.conf' || printf '%s\n' 'compress' >>'/etc/logrotate.conf'
    grep -q -E "^\s*[#]*\s*create\s*$" '/etc/logrotate.conf' && sed -i -E "s,^\s*[#]*\s*create\s*$,create," '/etc/logrotate.conf' || printf '%s\n' 'create' >>'/etc/logrotate.conf'
}

function create_swap_file() {
    # Parameters
    local swap_file_size=${1}

    # Create swapfile
    dd if=/dev/zero of=/swapfile bs=1M count="${swap_file_size}" status=progress
    # Set file permissions
    # chmod 600
    chmod u=rw,g-rwx,o-rwx '/swapfile'
    # Format file to swap
    mkswap /swapfile
    # Activate the swap file
    swapon /swapfile
    # Add to fstab
    grep -q -E ".*\/swapfile" '/etc/fstab' && sed -i -E "s,.*\/swapfile.*,\/swapfile none swap defaults 0 0," '/etc/fstab' || printf '%s\n' "/swapfile none swap defaults 0 0" >>'/etc/fstab'
}

function set_timezone() {
    ln -sf '/usr/share/zoneinfo/America/New_York' '/etc/localtime'
}

function set_language() {
    grep -q -E ".*LANG=" '/etc/locale.conf' && sed -i -E "s,.*LANG=.*,LANG=en_US\.UTF-8," '/etc/locale.conf' || printf '%s\n' 'LANG=en_US.UTF-8' >>'/etc/locale.conf'
}

function set_hostname() {
    # Parameters
    local device_hostname=${1}

    rm -f '/etc/hostname'
    printf '%s\n' "${device_hostname}" >>'/etc/hostname'
}

function setup_hosts_file() {
    # Parameters
    local device_hostname=${1}

    grep -q -E ".*127\.0\.0\.1 localhost" '/etc/hosts' && sed -i -E "s,.*127\.0\.0\.1 localhost.*,127\.0\.0\.1 localhost," '/etc/hosts' || printf '%s\n' '127.0.0.1 localhost' >>'/etc/hosts'
    grep -q -E ".*::1 localhost" '/etc/hosts' && sed -i -E "s,.*::1.*,::1 localhost," '/etc/hosts' || printf '%s\n' '::1 localhost' >>'/etc/hosts'
    grep -q -E ".*127\.0\.0\.1 ${device_hostname}\.localdomain ${device_hostname}" '/etc/hosts' && sed -i -E "s,.*127\.0\.0\.1 ${device_hostname}.*,127\.0\.0\.1 ${device_hostname}\.localdomain ${device_hostname}," '/etc/hosts' || printf '%s\n' "127.0.0.1 ${device_hostname}.localdomain ${device_hostname}" >>'/etc/hosts'
}

function create_user() {
    # Parameters
    local user_name=${1}

    useradd -m "${user_name}"
    echo "Set the password for ${user_name}"
    passwd "${user_name}"
    mkdir -p "/home/${user_name}"
    chown "${user_name}" "/home/${user_name}"
}

function add_user_to_sudo() {
    # Parameters
    local user_name=${1}

    grep -q -E ".*${user_name}" '/etc/sudoers' && sed -i -E "s,.*${user_name}.*,${user_name} ALL=\(ALL\) ALL," '/etc/sudoers' || printf '%s\n' "${user_name} ALL=(ALL) ALL" >>'/etc/sudoers'
}

function set_shell_bash() {
    # Parameters
    local user_name=${1}

    chsh -s /bin/bash
    chsh -s /bin/bash "${user_name}"
}
