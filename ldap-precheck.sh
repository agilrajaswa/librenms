#!/bin/bash

# Exit on any error
set -e

echo
echo "#################################"
echo "LibreNMS Installation with LDAP"
echo "#################################"
echo

# Input database password & hostname
read -sp "Enter MySQL database password for librenms user: " DATABASEPASSWORD
echo
read -p "Enter web server hostname: " WEBSERVERHOSTNAME
echo

# Input LDAP configuration
echo
echo "=== LDAP Configuration ==="
echo "LDAP Server: 192.168.1.15 (fixed)"
LDAP_SERVER="192.168.1.15"
read -p "LDAP Port (default 389): " LDAP_PORT
LDAP_PORT=${LDAP_PORT:-389}
read -p "Use LDAPS/TLS? (yes/no, default no): " LDAP_TLS
LDAP_TLS=${LDAP_TLS:-no}
read -p "Base DN (e.g., dc=example,dc=com): " LDAP_BASEDN
read -p "Bind User DN (e.g., cn=admin,dc=example,dc=com): " LDAP_BINDUSER
read -sp "Bind User Password: " LDAP_BINDPASS
echo
read -p "User DN/OU (e.g., ou=users,dc=example,dc=com): " LDAP_USERDN
read -p "User filter (default: uid=): " LDAP_USERFILTER
LDAP_USERFILTER=${LDAP_USERFILTER:-uid=}
read -p "Group DN (optional, press enter to skip): " LDAP_GROUPDN
read -p "Admin Group CN (optional, e.g., librenms-admins): " LDAP_ADMIN_GROUP

echo
echo "############################"
echo "Installing required packages"
echo "############################" 
echo

apt update
apt install -y acl curl fping git graphviz imagemagick mariadb-client mariadb-server mtr-tiny nginx-full nmap \
php-cli php-curl php-fpm php-gd php-gmp php-json php-mbstring php-mysql php-snmp php-xml php-zip php-ldap \
rrdtool snmp snmpd unzip python3-command-runner python3-pymysql python3-dotenv python3-redis \
python3-setuptools python3-psutil python3-systemd python3-pip whois traceroute iputils-ping tcpdump vim cron

echo
echo "######################"
echo "Creating librenms user"
echo "######################"
useradd librenms -d /opt/librenms -M -r -s "$(which bash)"

echo "###########################"
echo "Cloning LibreNMS repository"
echo "###########################"
cd /opt
git clone https://github.com/librenms/librenms.git

echo
echo "############################################"
echo "Setting permissions for LibreNMS directories"
echo "############################################"
chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/

echo "################################"
echo "Installing Composer dependencies"
echo "################################"
su - librenms -c "/opt/librenms/scripts/composer_wrapper.php install --no-dev"

echo
echo "########################"
echo "Configuring PHP timezone"
echo "########################"
sed -i 's/;date.timezone =/date.timezone = Asia\/Makassar/' /etc/php/8.3/fpm/php.ini
sed -i 's/;date.timezone =/date.timezone = Asia\/Makassar/' /etc/php/8.3/cli/php.ini

echo
echo "#############################################"
echo "Setting system timezone to Asia/Makassar"
echo "#############################################"
timedatectl set-timezone Asia/Makassar

echo "############################"
echo "Configuring MariaDB settings"
echo "############################"
sed -i '/\[mysqld\]/a \
innodb_file_per_table=1 \
lower_case_table_names=0' /etc/mysql/mariadb.conf.d/50-server.cnf

echo "###############################"
echo "Enabling and restarting MariaDB"
echo "###############################"
systemctl enable mariadb
systemctl restart mariadb

echo
echo "###################################"
echo "Creating LibreNMS database and user"
echo "###################################"
mysql -u root <<EOF
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'librenms'@'localhost' IDENTIFIED BY '$DATABASEPASSWORD';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF

echo
echo "#####################################"
echo "Configuring PHP-FPM pool for LibreNMS"
echo "#####################################"
cp /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's/user = www-data/user = librenms/' /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's/group = www-data/group = librenms/' /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's/\[www\]/\[librenms\]/' /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's|listen = /run/php/php8.3-fpm.sock|listen = /run/php-fpm-librenms.sock|' /etc/php/8.3/fpm/pool.d/librenms.conf

systemctl restart php8.3-fpm
sleep 2

echo
echo "##############################"
echo "Configuring Nginx for LibreNMS"
echo "##############################"
cat << EOF > /etc/nginx/conf.d/librenms.conf
server {
 listen      80;
 server_name $WEBSERVERHOSTNAME;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;

 location / {
  try_files \$uri \$uri/ /index.php?\$query_string;
 }

 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }

 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOF

echo
echo "####################################"
echo "Removing default Nginx configuration"
echo "####################################"
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

chown -R www-data:www-data /opt/librenms/html
chmod -R 755 /opt/librenms/html

nginx -t

echo
echo "Restarting Nginx..."
systemctl restart nginx

echo "#######################"
echo "Setting up lnms command"
echo "#######################"
ln -s /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

echo "################"
echo "Configuring SNMP"
echo "################"
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i 's/RANDOMSTRINGGOESHERE/public/' /etc/snmp/snmpd.conf
curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable snmpd
systemctl restart snmpd

cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms

echo
echo "#############################"
echo "Setting up LibreNMS scheduler"
echo "#############################"
cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

echo
echo "##################################"
echo "Configuring logrotate for LibreNMS"
echo "##################################"
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

echo
echo "#######################"
echo "Fixing up the .env file"
echo "#######################"
sed -i "s/#DB_HOST=/DB_HOST=localhost/" /opt/librenms/.env
sed -i "s/#DB_DATABASE=/DB_DATABASE=librenms/" /opt/librenms/.env
sed -i "s/#DB_USERNAME=/DB_USERNAME=librenms/" /opt/librenms/.env
sed -i "s/#DB_PASSWORD=/DB_PASSWORD=$DATABASEPASSWORD/" /opt/librenms/.env

echo
echo "##############################"
echo "Configuring LDAP in config.php"
echo "##############################"

# Escape special characters for sed
LDAP_BINDPASS_ESCAPED=$(printf '%s\n' "$LDAP_BINDPASS" | sed 's/[[\.*^$/]/\\&/g')

# Determine encryption setting
if [ "$LDAP_TLS" = "yes" ]; then
    LDAP_ENCRYPTION="'encryption' => 'tls',"
else
    LDAP_ENCRYPTION="'encryption' => false,"
fi

# Create config.php with LDAP settings
cat << EOFCONFIG > /opt/librenms/config.php
<?php

\$config['auth_mechanism'] = 'ldap';

\$config['auth_ldap_version'] = 3;
\$config['auth_ldap_server'] = '$LDAP_SERVER';
\$config['auth_ldap_port'] = $LDAP_PORT;
\$config['auth_ldap_starttls'] = 'optional';
$LDAP_ENCRYPTION

\$config['auth_ldap_prefix'] = '';
\$config['auth_ldap_suffix'] = '';

\$config['auth_ldap_binduser'] = '$LDAP_BINDUSER';
\$config['auth_ldap_binddn'] = '$LDAP_BINDUSER';
\$config['auth_ldap_bindpassword'] = '$LDAP_BINDPASS';

\$config['auth_ldap_userdn'] = '$LDAP_USERDN';
\$config['auth_ldap_attr']['uid'] = '$LDAP_USERFILTER';

\$config['auth_ldap_debug'] = false;
\$config['auth_ldap_timeout'] = 5;
\$config['auth_ldap_cache_ttl'] = 300;

// Create users automatically on login
\$config['auth_ldap_autocreate_users'] = true;

EOFCONFIG

# Add group configuration if provided
if [ -n "$LDAP_GROUPDN" ]; then
    cat << EOFCONFIG >> /opt/librenms/config.php
// Group configuration
\$config['auth_ldap_groups']['$LDAP_BASEDN']['group_filter'] = '(objectClass=groupOfNames)';
\$config['auth_ldap_groups']['$LDAP_BASEDN']['group_member_attr'] = 'member';
\$config['auth_ldap_groups']['$LDAP_BASEDN']['group_member_type'] = 'fulldn';

EOFCONFIG
fi

# Add admin group if provided
if [ -n "$LDAP_ADMIN_GROUP" ]; then
    cat << EOFCONFIG >> /opt/librenms/config.php
// Admin group mapping
\$config['auth_ldap_group'] = ['$LDAP_ADMIN_GROUP'];
\$config['auth_ldap_groupbase'] = '$LDAP_GROUPDN';

EOFCONFIG
fi

# Close PHP tag
echo "?>" >> /opt/librenms/config.php

chown librenms:librenms /opt/librenms/config.php
chmod 640 /opt/librenms/config.php

echo
echo "#####################"
echo "Testing LDAP connection"
echo "#####################"

# Install ldap-utils for testing
apt-get install -y ldap-utils

echo "Testing LDAP bind..."
if ldapsearch -x -H ldap://$LDAP_SERVER:$LDAP_PORT -D "$LDAP_BINDUSER" -w "$LDAP_BINDPASS" -b "$LDAP_BASEDN" -s base >/dev/null 2>&1; then
    echo "✓ LDAP connection successful!"
else
    echo "✗ WARNING: LDAP connection test failed. Please verify your LDAP settings."
    echo "  You can test manually with:"
    echo "  ldapsearch -x -H ldap://$LDAP_SERVER:$LDAP_PORT -D \"$LDAP_BINDUSER\" -w \"password\" -b \"$LDAP_BASEDN\""
fi

echo
echo "#####################"
echo "Fixing log permission"
echo "#####################"
while true; do
  if [ -f /opt/librenms/logs/librenms.log ]; then
    chown librenms:librenms /opt/librenms/logs/librenms.log
    break
  else
    echo "Waiting until log file appears to change permission..."
    sleep 1
  fi
done

echo
echo "======================================"
echo "LibreNMS Installation Complete!"
echo "======================================"
echo
echo "LDAP Configuration Summary:"
echo "  Server: $LDAP_SERVER:$LDAP_PORT"
echo "  Base DN: $LDAP_BASEDN"
echo "  User DN: $LDAP_USERDN"
echo "  Bind User: $LDAP_BINDUSER"
if [ -n "$LDAP_GROUPDN" ]; then
    echo "  Group DN: $LDAP_GROUPDN"
fi
if [ -n "$LDAP_ADMIN_GROUP" ]; then
    echo "  Admin Group: $LDAP_ADMIN_GROUP"
fi
echo
echo "Next Steps:"
echo "1. Open http://$WEBSERVERHOSTNAME in your browser"
echo "2. Complete the web setup wizard"
echo "3. Try logging in with your LDAP credentials"
echo
echo "To enable debug mode for LDAP troubleshooting, edit /opt/librenms/config.php:"
echo "  \$config['auth_ldap_debug'] = true;"
echo
echo "Check LDAP debug logs:"
echo "  tail -f /opt/librenms/logs/librenms.log | grep -i ldap"
echo
echo "To validate the installation:"
echo "  su librenms -c '/opt/librenms/validate.php'"
echo

exit 0