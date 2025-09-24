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
else # AlmaLinux
	yum -y module reset php
	yum -y module enable php:remi-8.2
fi

# Install Nginx
echo "Installing Nginx and Certbot..."
yum -y install nginx certbot python3-certbot-nginx
systemctl enable nginx --now

# Install MariaDB and secure it
echo "Installing MariaDB and securing it..."
yum -y install mariadb-server
systemctl enable mariadb --now

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

# Install PHP8 and common modules
echo "Installing PHP and common modules..."
if [ "$DIST_RELEASE" = "AlmaLinux" ]; then 
	yum -y install php-fpm php-{common,pear,cgi,curl,mbstring,gd,mysqlnd,gettext,bcmath,json,xml,intl,zip,opcache}
else
	yum -y install php-fpm php-{common,pear,cgi,curl,mbstring,gd,mysqlnd,gettext,bcmath,json,xml,intl,zip,imap,opcache}
fi
systemctl enable php-fpm --now

# Edit upload_max_filesize and post_max_filesize
sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 128M/g;s/post_max_size = 8M/post_max_size = 128M/g" /etc/php.ini


# CentOS needs manual creation of PHP-FPM related files and edit of www pool config 
if [ "$DIST_RELEASE" = "CentOS Linux" ]; then
    cat > /etc/nginx/conf.d/php-fpm.conf <<'EOF'
# PHP-FPM FastCGI server
# network or unix domain socket configuration

upstream php-fpm {
        server unix:/run/php-fpm/www.sock;
}
EOF

    cat > /etc/nginx/default.d/php.conf <<'EOF'
# pass the PHP scripts to FastCGI server
#
# See conf.d/php-fpm.conf for socket configuration
#
index index.php index.html index.htm;

location ~ \.php$ {
    try_files $uri =404;
    fastcgi_intercept_errors on;
    fastcgi_index  index.php;
    include        fastcgi_params;
    fastcgi_param  SCRIPT_FILENAME  $document_root$fastcgi_script_name;
    fastcgi_pass   php-fpm;
}
EOF
fi
sed -i 's/^listen = 127.0.0.1:9000$/listen = \/run\/php-fpm\/www.sock/' /etc/php-fpm.d/www.conf
sed -i 's/^user = apache$/user = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^group = apache$/group = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^;listen.owner = nobody$/listen.owner = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^;listen.group = nobody$/listen.group = nginx/' /etc/php-fpm.d/www.conf

# Finalizing...
systemctl restart nginx php-fpm

# Upon finishing remove the banner directive and reenable password prompt
sed -i "/^Match Host \*/d;/^\tBanner \/etc\/ssh\/refuse_banner$/d;/^\tForceCommand printf \"\"$/d" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" /etc/ssh/sshd_config

# Remove the banner file
rm /etc/ssh/refuse_banner

# Restart the SSH service
systemctl restart sshd
