#!/bin/sh

# Informative message for users trying to connect before the recipe has finished
cat >> /etc/ssh/refuse_banner << EOF
Currently installing the app template you've selected, so any authentication would result in permission denied.
Please allow up to 20 minutes for it to finish and try again.
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

# Restart the SSH service
systemctl restart sshd

# Set HOME var, needed for the script
export HOME=/root
cd $HOME

cat > $HOME/recipe.sh << EORECIPE
# Run CyberPanel installation
wget -P $HOME https://cyberpanel.net/install.sh
chmod +x $HOME/install.sh
$HOME/install.sh -v ols -p r -a -m postfix powerdns pureftpd 2>&1 >> $HOME/cyberpanel.log


# Disable the service
systemctl disable cyberpanel-installation.service

# Upon finishing remove the banner directive and reenable password prompt
sed -i "/^Match Host \*/d;/^\tBanner \/etc\/ssh\/refuse_banner$/d;/^\tForceCommand printf \"\"$/d" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" /etc/ssh/sshd_config

# Remove the banner file
rm /etc/ssh/refuse_banner

# Clean up
rm -f $HOME/recipe.sh $HOME/environment.env $HOME/install.sh

# Restart the SSH service
systemctl restart sshd
EORECIPE

# Save the environment variables to a file
sudo -i
env | grep -v '^\s*#' > $HOME/environment.env

# Create a systemd service to run the script after reboot
cat > /etc/systemd/system/cyberpanel-installation.service << EOSYSTEMD
[Unit]
Description=Install CyberPanel after reboot
After=network.target

[Service]
User=root
Group=root
Type=oneshot
EnvironmentFile=$HOME/environment.env
ExecStart=/bin/bash $HOME/recipe.sh

[Install]
WantedBy=multi-user.target
EOSYSTEMD

# Enable the service and reboot the server
systemctl enable cyberpanel-installation.service
systemctl daemon-reload
sleep 5 && reboot &
