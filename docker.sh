#!/bin/sh


# Informative message for users trying to connect before the recipe has finished
cat > /etc/ssh/refuse_banner << 'EOF'
Currently installing the app template you've selected, so any authentication would result in permission denied.
Please allow up to 5 minutes for it to finish and try again.
VPSBG Team
EOF

# Detect SSH service name
SSH_SERVICE=""
if systemctl list-units --all | grep -q "sshd.service"; then
    SSH_SERVICE="sshd"
elif systemctl list-units --all | grep -q "ssh.service"; then
    SSH_SERVICE="ssh"
else
    echo "Warning: Could not detect SSH service name"
    SSH_SERVICE="sshd"  # fallback
fi

# Disable password prompt
sed -i "s/^PasswordAuthentication yes$/PasswordAuthentication no/g" /etc/ssh/sshd_config

# Display the banner
cat >> /etc/ssh/sshd_config << 'EOF'
Match Host *
	Banner /etc/ssh/refuse_banner
	ForceCommand printf ""
EOF

# Restart the SSH service
systemctl restart $SSH_SERVICE

# Docker recipe
curl -sSL https://get.docker.com | sh
systemctl enable docker --now

# Upon finishing remove the banner directive and reenable password prompt
sed -i "/^Match Host \*/d;/^\tBanner \/etc\/ssh\/refuse_banner$/d;/^\tForceCommand printf \"\"$/d" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" /etc/ssh/sshd_config

# Remove the banner file
rm /etc/ssh/refuse_banner

# Restart the SSH service
systemctl restart $SSH_SERVICE