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

export DEBIAN_FRONTEND=noninteractive
apt --allow-releaseinfo-change update

# Generate pass for MariaDB
MYSQL_USER_PASS=$(< /dev/urandom tr -dc _A-Za-z0-9 | head -c${1:-16};echo;)

apt -y install lsb-release ca-certificates apt-transport-https software-properties-common gnupg2 gnutls-bin curl

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

# Install Nginx
echo "Installing Nginx..."
apt -y install nginx

# Install MariaDB and secure it
echo "Installing MariaDB and securing it..."
apt -y install mariadb-server mariadb-client

MYSQL_USER="default_user"
MYSQL_DATABASE="default_database"
mysql << EOF
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
CREATE USER '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_USER_PASS}';
CREATE DATABASE ${MYSQL_DATABASE};
GRANT ALL ON ${MYSQL_DATABASE}.* TO '${MYSQL_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Output credentials to a file
echo "MySQL username: $MYSQL_USER" > /root/mysql_credentials.txt
echo "MySQL password: $MYSQL_USER_PASS" >> /root/mysql_credentials.txt
echo "Database: $MYSQL_DATABASE" >> /root/mysql_credentials.txt

# Install PHP and PHP-FPM
echo "Installing PHP and PHP-FPM..."
apt -y install php php-mysql php-fpm php-common php-curl php-dev php-gd php-imagick php-intl php-mbstring php-mysql php-pear php-pspell php-xml php-zip

# Edit upload_max_filesize and post_max_size
PHP_CURR_DIR=$(ls -d1v /etc/php/* | tail -1)
grep -nre "upload_max_filesize" $PHP_CURR_DIR | cut -d: -f1 | xargs sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 128M/g;s/post_max_size = 8M/post_max_size = 128M/g"

# Create Nginx server block
echo "Creating Nginx server block..."
cat > /etc/nginx/sites-available/laravel_app <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/laravel_app/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    index index.html index.htm index.php;

    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

# Create symbolic link to enable the site
ln -sf /etc/nginx/sites-available/laravel_app /etc/nginx/sites-enabled/

# Fix perms
chown -R www-data: /var/www/

# Remove index.html (as it is default Apache2 file on Ubuntu systems) and the "default" config files
rm -f /var/www/html/index.html /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

# Install NPM
apt -y install npm

# Install Composer
export HOME="/root"
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
chmod +x /usr/local/bin/composer

# Install Laravel and add it to PATH
export COMPOSER_ALLOW_SUPERUSER=1
export PATH="$PATH:/root/.config/composer/vendor/bin"
composer global require laravel/installer
echo 'export PATH="$PATH:/root/.config/composer/vendor/bin"' > /root/.bashrc

# Create new laravel project
cd /var/www
laravel new laravel_app --no-interaction
chown -R www-data: laravel_app/

# Restart Nginx to apply pending changes
systemctl restart nginx

# Upon finishing remove the banner directive and reenable password prompt
sed -i "/^Match Host \*/d;/^\tBanner \/etc\/ssh\/refuse_banner$/d;/^\tForceCommand printf \"\"$/d" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" /etc/ssh/sshd_config

# Remove the banner file
rm /etc/ssh/refuse_banner

# Restart the SSH service
systemctl restart sshd
