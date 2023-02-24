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
export DEBIAN_FRONTEND=noninteractive
apt --allow-releaseinfo-change update
apt -y upgrade

# Generate pass for MariaDB
MYSQL_USER_PASS=$(< /dev/urandom tr -dc _A-Za-z0-9 | head -c${1:-16};echo;);

apt -y install lsb-release ca-certificates apt-transport-https software-properties-common gnupg2

if [ $(lsb_release -is) = "Ubuntu" ]; then
	# Add Sury repository for Ubuntu
	echo Adding PHP repo
	add-apt-repository --yes ppa:ondrej/php
	echo Added PHP repo
else
	# Add Sury repository for Debian
	echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/sury-php.list
	wget -qO - https://packages.sury.org/php/apt.gpg | apt-key add -
fi
	
apt update

# Install Apache2 & Certbot
echo "Installing Apache..."
apt -y install apache2 apache2-doc libexpat1 ssl-cert certbot python3-certbot-apache

# Install MariaDB and secure it
echo "Installing MariaDB and securing it..."
apt -y install mariadb-server mariadb-client

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

apt -y install php php-common libapache2-mod-php php-curl php-dev php-gd php-imagick php-intl php-mbstring php-mysql php-pear php-pspell php-xml php-zip

# Edit upload_max_filesize and post_max_filesize
PHP_CURR_DIR=$(ls -d1v /etc/php/* | tail -1)
grep -nre "upload_max_filesize" $PHP_CURR_DIR | cut -d: -f1 | xargs sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 128M/g;s/post_max_size = 8M/post_max_size = 128M/g"

# Enable Apache & PHP modules
a2enmod rewrite
phpenmod mbstring

# Finalizing...
chown -R www-data:www-data /var/www
service apache2 restart

# Output credentials to a file
echo -e "MySQL username: default_user\nMySQL password: ${MYSQL_USER_PASS}\nDatabase: default_database" > /root/mysql_credentials.txt

# Remove default apache conf files
rm -f /etc/apache2/sites-available/* /etc/apache2/sites-enabled/*

# Install and enable PHP-FPM, required for Wordpress
apt -y install php-fpm
a2enmod proxy_fcgi setenvif
a2enconf php8.2-fpm

# Enable proxy_http for Apache, required to proxy php scripts to PHP-FPM
a2enmod proxy_http

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

# Get user input for necessary website information
read -p "Enter your domain address without \"www\" or \"http(s)://\": " DOMAIN_NAME
read -p "Enter your email address: " EMAIL
read -p "Choose an admin username: " ADMIN_USER
read -p "Choose an admin password: " ADMIN_PASS

# Create the dir in /var/www, download WP files, edit wp-config.php and install an admin user
mkdir /var/www/\$DOMAIN_NAME
wp core download --allow-root --path=/var/www/\$DOMAIN_NAME/ --url=\$DOMAIN_NAME
wp config create --allow-root --path=/var/www/\$DOMAIN_NAME/ --dbname=\$DB_NAME --dbuser=\$DB_USER --dbpass=\$DB_PASS
wp core install --allow-root --path=/var/www/\$DOMAIN_NAME/ --url=\$DOMAIN_NAME --title=\$DOMAIN_NAME --admin_email=\$EMAIL --admin_user=\$ADMIN_USER --admin_password=\$ADMIN_PASS --skip-email

# Put the config in /etc/<apache_dir>/sites-available/
cat > /etc/apache2/sites-available/\$DOMAIN_NAME.conf << EOF
<VirtualHost *:80>
    ServerName \$DOMAIN_NAME
    DocumentRoot "/var/www/\$DOMAIN_NAME"
    <Directory "/var/www/\$DOMAIN_NAME">
        Require all granted
        DirectoryIndex index.php
        AllowOverride All
        FallbackResource /index.php
    </Directory>
    <Directory "/var/www/\$DOMAIN_NAME/wp-admin">
        FallbackResource disabled
    </Directory>
    ProxyPassMatch ^/(.*\.php(/.*)?)\$ unix:/var/run/php/php-fpm.sock|fcgi://dummy/var/www/\$DOMAIN_NAME
</VirtualHost>
EOF

# Enable the website in /etc/<apache-dir>/sites-enabled/
a2ensite \$DOMAIN_NAME.conf

# Change perms
chown -R www-data:www-data /var/www/\$DOMAIN_NAME/

# Restart Apache2 to apply new config
systemctl restart apache2
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