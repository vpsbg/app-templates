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

# Restart the SSH service
systemctl restart sshd

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "Can't identify the OS"
    exit 1
fi

# Update packages/prepare for installation
case $NAME in
    *AlmaLinux*)
        dnf config-manager --enable appstream
    ;;
    *Ubuntu*)
        apt-get update
    ;;
    *Debian*)
        apt-get --allow-releaseinfo-change update
        echo 'mysql-apt-config mysql-apt-config/repo-codename select buster' | debconf-set-selections
        echo 'mysql-apt-config mysql-apt-config/select-product select Ok' | debconf-set-selections
        echo 'mysql-apt-config mysql-apt-config/select-server select mysql-8.0' | debconf-set-selections
        echo 'mysql-apt-config mysql-apt-config/unsupported-platform select abort' | debconf-set-selections
        echo 'mysql-apt-config mysql-apt-config/preview-component string' | debconf-set-selections
        echo 'mysql-apt-config mysql-apt-config/repo-url string http://repo.mysql.com/apt' | debconf-set-selections
        echo 'mysql-apt-config mysql-apt-config/tools-component string mysql-tools' | debconf-set-selections
        echo 'mysql-apt-config mysql-apt-config/repo-distro select debian' | debconf-set-selections
        echo 'mysql-apt-config mysql-apt-config/select-tools select Enabled' | debconf-set-selections
        echo 'mysql-apt-config mysql-apt-config/select-preview select Disabled' | debconf-set-selections
        wget https://dev.mysql.com/get/mysql-apt-config_0.8.25-1_all.deb
        DEBIAN_FRONTEND=noninteractive apt -y install ./mysql-apt-config_*_all.deb
        apt-get update
    ;;
    *CentOS*)
        yum update -y
        curl -sSLO https://dev.mysql.com/get/mysql80-community-release-el7-7.noarch.rpm
        rpm -ivh mysql*.rpm
    ;;
    *)
        echo "Unsupported OS"
        exit 1
    ;;
esac

# Install MySQL server
case $NAME in
    *AlmaLinux*)
        dnf install -y mysql-server
        systemctl enable --now mysqld
    ;;
    *Ubuntu*|*Debian*)
        DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server
    ;;
    *CentOS*)
        yum install -y mysql-server
        systemctl start mysqld
    ;;
esac

#  Update MySQL server configuration to listen to all interfaces
case $NAME in
    *Ubuntu*|*Debian*)
        grep -rl "127.0.0.1" /etc/mysql | while read -r file; do
            sed -i "s/127.0.0.1/0.0.0.0/g" "$file"
        done
    ;;
esac


# Ops before adding user
case $NAME in
    *Ubuntu*|*Debian*)
        service mysql restart
    ;;
    *CentOS*)
        service mysqld restart
        TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log | grep -oP "localhost: \K.*")
        # Add "!" to the root's password to comply with MySQL's security requirements
        NEW_PASS=$(echo `openssl rand -base64 16 | cut -c1-16`)
        mysql --connect-expired-password -u root -p"$TEMP_PASS" <<-EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASS}!';
SET GLOBAL validate_password.policy = 0;
EOF
    ;;
esac

# Create a new MySQL user with random password and grant privileges
MYSQL_USER="default_user"
MYSQL_PASSWORD=`openssl rand -base64 16 | cut -c1-16`
case $NAME in
    *Ubuntu*|*Debian*|*AlmaLinux*)
        mysql -u root <<-EOF
CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_USER'@'%' WITH GRANT OPTION;
EOF
    ;;
    *CentOS*)
        mysql --connect-expired-password -u root -p"$NEW_PASS"'!' <<-EOF
CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_USER'@'%' WITH GRANT OPTION;
EOF
    ;;
esac


# Save username and password
echo "Username: $MYSQL_USER" > /root/mysql_credentials.txt
echo "Password: $MYSQL_PASSWORD" >> /root/mysql_credentials.txt
if test -v NEW_PASS; then
    echo "Root password: ${NEW_PASS}!" >> /root/mysql_credentials.txt
fi

# Upon finishing remove the banner directive and reenable password prompt
sed -i "/^Match Host \*/d;/^\tBanner \/etc\/ssh\/refuse_banner$/d;/^\tForceCommand printf \"\"$/d" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" /etc/ssh/sshd_config

# Remove the banner file
rm /etc/ssh/refuse_banner

# Restart the SSH service
systemctl restart sshd
