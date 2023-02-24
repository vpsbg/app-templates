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

# Begin LAMP installation
yum -y update

# Generate pass for MariaDB
MYSQL_USER_PASS=$(< /dev/urandom tr -dc _A-Za-z0-9 | head -c${1:-16};echo;);

DIST_RELEASE=$( cat /etc/*release | grep -oP "^NAME=\"\K.*?(?=\")" )
NUM_RELEASE=$(  cat /etc/*release | grep -oP "^VERSION_ID=\"\K.*?(?=\")" | cut -c1)

echo Distribution: $DIST_RELEASE
echo Release: $NUM_RELEASE

if [ "$NUM_RELEASE" = "7" ]; then # CentOS 7.9
	yum -y install http://rpms.remirepo.net/enterprise/remi-release-7.rpm
	yum -y install yum-utils
elif [ "$NUM_RELEASE" = "8" ]; then # AlmaLinux 8.x
	yum -y install http://rpms.remirepo.net/enterprise/remi-release-8.rpm
elif [ "$NUM_RELEASE" = "9" ]; then  # AlmaLinux 9.x
	yum -y install http://rpms.remirepo.net/enterprise/remi-release-9.rpm
fi

# Enable Remi for php82
if [ "$NUM_RELEASE" = "7" ]; then # CentOS 7.9
	yum-config-manager --enable remi-php82
else # AlmaLinux 8.x
	yum -y update
	yum -y module reset php
	yum -y module enable php:remi-8.2
fi

# Install Apache2 & Certbot
echo "Installing Apache..."
if [ "$NUM_RELEASE" = "7" ]; then
	yum -y install httpd certbot python2-certbot-apache
else
    yum -y install httpd certbot python3-certbot-apache
fi
systemctl enable httpd --now

# Install MariaDB and secure it
echo "Installing MariaDB and securing it..."
yum -y install mariadb-server
systemctl enable mariadb --now

mysql << EOF
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
CREATE USER 'default_user'@'localhost' IDENTIFIED BY '${MYSQL_USER_PASS}';
CREATE DATABASE default_database;
GRANT ALL ON default_database.* TO 'default_user'@'localhost';
FLUSH PRIVILEGES;
EOF

# Install PHP8 and common modules
echo "Installing PHP and common modules..."
if [ "$DIST_RELEASE" = "AlmaLinux" ]; then 
	yum -y install php php-{common,pear,cgi,curl,mbstring,gd,mysqlnd,gettext,bcmath,json,xml,intl,zip,opcache}
else
	yum -y install php php-{common,pear,cgi,curl,mbstring,gd,mysqlnd,gettext,bcmath,json,xml,intl,zip,imap,opcache}
fi

# Edit upload_max_filesize and post_max_filesize
sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 128M/g;s/post_max_size = 8M/post_max_size = 128M/g" /etc/php.ini

# Finalizing...
chown -R apache:apache /var/www
systemctl restart httpd

# Output credentials to a file
echo -e "MySQL username: default_user\nMySQL password: ${MYSQL_USER_PASS}\nDatabase: default_database" > /root/mysql_credentials.txt

# Install and enable PHP-FPM, required for Wordpress
yum -y install php-fpm

# Enable MPM event
# Comment the prefork module, if not commented
sed -i 's/^LoadModule mpm_prefork_module modules\/mod_mpm_prefork.so$/#LoadModule mpm_prefork_module modules\/mod_mpm_prefork.so/g' /etc/httpd/conf.modules.d/00-mpm.conf
# Remove comment of event module, if commented
sed -i 's/^#LoadModule mpm_event_module modules\/mod_mpm_event.so$/LoadModule mpm_event_module modules\/mod_mpm_event.so/g' /etc/httpd/conf.modules.d/00-mpm.conf

# Edit the PHP-FPM config for "www" pool
# Change from port to socket file
sed -i 's/listen = 127.0.0.1:9000/listen = \/var\/run\/php-fpm\/www.sock/' /etc/php-fpm.d/www.conf
# Change listen owner and group to apache
sed -i 's/;listen.owner = .*$/listen.owner = apache/g;s/;listen.group = .*$/listen.group = apache/g' /etc/php-fpm.d/www.conf 

# Start and enable php-fpm
systemctl enable php-fpm --now
systemctl restart httpd

# Download WP-CLI
wget https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -O /usr/local/bin/wp
chmod +x /usr/local/bin/wp

# Create the wordpress-install.sh script, which will run on login via .bashrc

cat > /root/wordpress-install.sh << EOWPINSTALL
echo "Finalizing WordPress installation..."

# Get the DB credentials from /root/mysql_credentials.txt
DB_NAME="default_database"
DB_USER="default_user"
DB_PASS=\$(cat /root/mysql_credentials.txt | grep -oP "MySQL password: \K.*\$")

# Get the current PHP-FPM sock location, as it differs between RHEL distros
PHP_FPM_SOCK_DIR=$(grep -oP "^listen = \K.*$" /etc/php-fpm.d/www.conf)

# Get user input for necessary website information
read -p "Enter your domain address without \"www\" or \"http(s)://\": " DOMAIN_NAME
read -p "Enter your email address: " EMAIL
read -p "Choose an admin username: " ADMIN_USER
read -p "Choose an admin password: " ADMIN_PASS

# Create the dir in /var/www, download WP files, edit wp-config.php and install an admin user
mkdir /var/www/html/\$DOMAIN_NAME
wp core download --allow-root --path=/var/www/html/\$DOMAIN_NAME/ --url=\$DOMAIN_NAME
wp config create --allow-root --path=/var/www/html/\$DOMAIN_NAME/ --dbname=\$DB_NAME --dbuser=\$DB_USER --dbpass=\$DB_PASS
wp core install --allow-root --path=/var/www/html/\$DOMAIN_NAME/ --url=\$DOMAIN_NAME --title=\$DOMAIN_NAME --admin_email=\$EMAIL --admin_user=\$ADMIN_USER --admin_password=\$ADMIN_PASS --skip-email

# Put the config in /etc/<apache_dir>/sites-available/
cat > /etc/httpd/conf.d/\$DOMAIN_NAME.conf << EOF
<VirtualHost *:80>
    ServerName \$DOMAIN_NAME
    DocumentRoot "/var/www/html/\$DOMAIN_NAME"
    <Directory "/var/www/html/\$DOMAIN_NAME">
        Require all granted
        DirectoryIndex index.php
        AllowOverride All
        FallbackResource /index.php
    </Directory>
    <Directory "/var/www/html/\$DOMAIN_NAME/wp-admin">
        FallbackResource disabled
    </Directory>
    ProxyPassMatch ^/(.*\.php(/.*)?)\$ unix:\$PHP_FPM_SOCK_DIR|fcgi://dummy/var/www/html/\$DOMAIN_NAME
</VirtualHost>
EOF

# Change perms
chown -R apache:apache /var/www/html/\$DOMAIN_NAME/

# Restart Apache2 to apply new config
systemctl restart httpd
echo Apache2 restarted.

# Run the SSL script
echo
/root/enable-ssl.sh

# Remove the script from autostarting
sed -i "/^. \/root\/wordpress-install.sh$/d" /root/.bashrc
EOWPINSTALL

# Make the script executable and append it to .bashrc
chmod +x /root/wordpress-install.sh
echo ". /root/wordpress-install.sh" >> /root/.bashrc

# Create enable-ssl.sh script
cat > /root/enable-ssl.sh << EOF
#!/bin/sh

# Get the required information
echo "Beggining SSL installation..."
read -p "Have you pointed your domain to this server's IP address? If not, then the SSL installation will fail. (yes/no) " YES_NO
if [ \$YES_NO = "yes" ]; then 
	read -p "Enter your domain address without \"www\" or \"http(s)://\": " DOMAIN_NAME
	read -p "Enter your email address: " EMAIL
	# Run the certbot command
	certbot --non-interactive --agree-tos --apache -m \$EMAIL --domains \$DOMAIN_NAME
else
    echo "You can re-run this script using "/root/enable-ssl.sh" in the console when your domain is pointed to the server"
	echo "Exiting..."
fi
EOF

# Make enable-ssl.sh executable
chmod +x /root/enable-ssl.sh

# Upon finishing remove the banner directive and reenable password prompt
sed -i "/^Match Host \*/d;/^\tBanner \/etc\/ssh\/refuse_banner$/d;/^\tForceCommand printf \"\"$/d" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" /etc/ssh/sshd_config

# Remove the banner file
rm /etc/ssh/refuse_banner

# Restart the SSH service
systemctl restart sshd