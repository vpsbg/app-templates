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

# Install git if not present
if ! command -v git &> /dev/null; then
    echo "Git not found, installing..."
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y git
    elif command -v yum &> /dev/null; then
        yum install -y git
    elif command -v dnf &> /dev/null; then
        dnf install -y git
    fi
fi

# Docker installation
curl -sSL https://get.docker.com | sh
systemctl enable docker --now

# Install docker-compose if not present
if ! command -v docker-compose &> /dev/null; then
    # Check if docker compose (v2) is available
    if ! docker compose version &> /dev/null; then
        echo "Installing docker-compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
fi

# Clone n8n repository
cd /root/
git clone https://github.com/n8n-io/n8n-docker-caddy.git

# Create Docker volumes
cd /root/n8n-docker-caddy/
docker volume create caddy_data
docker volume create n8n_data

# Create the one-time setup script
cat > /root/n8n-setup.sh << 'SETUP_SCRIPT'


echo ""
echo "=========================================="
echo "       n8n Docker Installation Setup"
echo "=========================================="
echo ""
echo "Welcome! This is the n8n recipe installation."
echo ""
echo "IMPORTANT: Before we continue, you need to have:"
echo "1. A domain that you own (e.g., example.com)"
echo "2. A subdomain 'n8n' created for this domain (e.g., n8n.example.com)"
echo "3. An A record in your DNS pointing n8n.yourdomain.com to this server's IP address"
echo ""
echo "The subdomain MUST be 'n8n' - this is required for the installation to work properly."
echo ""
echo "Examples of valid domains:"
echo "  ✓ n8n.example.com"
echo "  ✓ n8n.mycompany.org"
echo "  ✓ n8n.mydomain.net"
echo ""
echo "Examples of INVALID inputs:"
echo "  ✗ https://n8n.example.com (don't include https://)"
echo "  ✗ app.example.com (subdomain must be 'n8n')"
echo "  ✗ example.com (must include the 'n8n' subdomain)"
echo ""

# Function to validate domain
validate_domain() {
    local domain=$1

    # Check if domain starts with n8n.
    if [[ ! "$domain" =~ ^n8n\. ]]; then
        echo "Error: Domain must start with 'n8n.' subdomain"
        return 1
    fi

    # Check for common mistakes
    if [[ "$domain" =~ ^https?:// ]]; then
        echo "Error: Please don't include http:// or https://"
        return 1
    fi

    if [[ "$domain" =~ / ]]; then
        echo "Error: Domain should not contain forward slashes"
        return 1
    fi

    # Basic domain format check
    if [[ ! "$domain" =~ ^n8n\.[a-zA-Z0-9][a-zA-Z0-9-]*\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: Invalid domain format"
        return 1
    fi

    # Check DNS resolution
    echo "Checking DNS resolution for $domain..."
    if ! host "$domain" &> /dev/null; then
        echo "Warning: Could not resolve $domain"
        echo "Make sure your DNS A record is properly configured and propagated."
        read -p "Do you want to continue anyway? (yes/no): " continue_anyway
        if [[ "$continue_anyway" != "yes" ]]; then
            return 1
        fi
    else
        echo "✓ DNS resolution successful"
    fi

    return 0
}

# Get domain from user
while true; do
    echo ""
    read -p "Please enter your full n8n domain (e.g., n8n.example.com): " USER_DOMAIN

    if validate_domain "$USER_DOMAIN"; then
        # Extract the apex domain (everything after n8n.)
        APEX_DOMAIN="${USER_DOMAIN#n8n.}"
        echo ""
        echo "Configuration:"
        echo "  Full domain: $USER_DOMAIN"
        echo "  Apex domain: $APEX_DOMAIN"
        echo ""
        read -p "Is this correct? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            break
        fi
    else
        echo ""
        echo "Please try again with a valid domain."
    fi
done

echo ""
echo "Configuring n8n with your domain..."

# Update .env file
cd /root/n8n-docker-caddy/
sed -i "s|DATA_FOLDER=/.*|DATA_FOLDER=/root/n8n-docker-caddy|" .env
sed -i "s|DOMAIN_NAME=.*|DOMAIN_NAME=$APEX_DOMAIN|" .env

# Update Caddyfile
sed -i "s|n8n\..*{|$USER_DOMAIN {|" caddy_config/Caddyfile

# Start docker compose
echo "Starting n8n services..."
if command -v docker-compose &> /dev/null; then
    docker-compose up -d
else
    docker compose up -d
fi

echo ""
echo "=========================================="
echo "     n8n Installation Complete!"
echo "=========================================="
echo ""
echo "Your n8n instance should be available at:"
echo "  https://$USER_DOMAIN"
echo ""
echo "Please allow a few minutes for the SSL certificate to be generated."
echo ""
echo "For more complex deployments and configuration options,"
echo "please visit the official n8n documentation at:"
echo "  https://docs.n8n.io/"
echo ""
echo "VPSBG Team"
echo ""

# Remove this setup script from profile
sed -i '/n8n-setup.sh/d' ~/.bashrc
sed -i '/n8n-setup.sh/d' ~/.bash_profile
sed -i '/n8n-setup.sh/d' /etc/profile

# Remove the script itself
rm -f /root/n8n-setup.sh

SETUP_SCRIPT

chmod +x /root/n8n-setup.sh

# Add to login profiles to run once
echo "[ -f /root/n8n-setup.sh ] && /root/n8n-setup.sh" >> /root/.bashrc
echo "[ -f /root/n8n-setup.sh ] && /root/n8n-setup.sh" >> /root/.bash_profile
echo "[ -f /root/n8n-setup.sh ] && /root/n8n-setup.sh" >> /etc/profile

echo "n8n installation prepared. Domain configuration will be requested on first login."

# Upon finishing remove the banner directive and reenable password prompt
sed -i "/^Match Host \*/d;/^\tBanner \/etc\/ssh\/refuse_banner$/d;/^\tForceCommand printf \"\"$/d" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" /etc/ssh/sshd_config

# Remove the banner file
rm /etc/ssh/refuse_banner

# Restart the SSH service
systemctl restart $SSH_SERVICE