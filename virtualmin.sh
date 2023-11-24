#!/bin/sh

# Informative message for users trying to connect before the recipe has finished
cat >> /etc/ssh/refuse_banner << EOF
Currently installing the app template you've selected, so any authentication would result in permission denied.
Please allow up to 5 minutes for it to finish and try again.
VPSBG Team
EOF

# Disable password prompt
sed -i "s/^PasswordAuthentication yes$/PasswordAuthentication no/g" /etc/ssh/sshd_config

# Display the banner
cat >> /etc/ssh/sshd_config << EOF
Match Host *
	Banner /etc/ssh/refuse_banner
	ForceCommand printf ""
EOF

#Restart the SSH service
systemctl restart sshd

# Debian, Ubuntu and AlmaLinux have "/etc/os-release"
. /etc/os-release

if [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y ca-certificates
else
    # Do not let NetworkManager edit resolv.conf
    chattr +i /etc/resolv.conf
fi

# Download the Virtualmin setup script and run it
# Debian, Ubuntu and AlmaLinux have wget
wget -q https://software.virtualmin.com/gpl/scripts/virtualmin-install.sh -O setup-virtualmin.sh

# Install Virtualmin with some defaults
sh setup-virtualmin.sh -n virtualmin.tld -f

# Upon finishing remove the banner directive and reenable password prompt
sed -i "/^Match Host \*/d;/^\tBanner \/etc\/ssh\/refuse_banner$/d;/^\tForceCommand printf \"\"$/d" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" /etc/ssh/sshd_config

# Remove the banner file
rm /etc/ssh/refuse_banner

# Restart the SSH service
systemctl restart sshd
