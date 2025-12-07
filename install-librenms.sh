#!/bin/bash

# LibreNMS Complete Installation Script
# Usage: Run with NAT first, then switch to Bridge Adapter
# Author: Claude AI Assistant
# Date: 2024

set -e

echo
echo "###############################################"
echo "#                                             #"
echo "#   LibreNMS Complete Installation Script    #"
echo "#   with LDAP Authentication                  #"
echo "#                                             #"
echo "###############################################"
echo
echo "IMPORTANT NOTES:"
echo "1. This VM MUST have internet access (NAT) during installation"
echo "2. After installation, you will switch to Bridge Adapter"
echo "3. LDAP Server: 192.168.1.15"
echo
read -p "Press Enter to continue or Ctrl+C to cancel..."
echo

# ==========================================
# SECTION 1: Collect Configuration
# ==========================================

echo "=========================================="
echo "SECTION 1: Configuration Input"
echo "=========================================="
echo

# Database password
while true; do
    read -sp "Enter MySQL database password for librenms user: " DATABASEPASSWORD
    echo
    read -sp "Confirm MySQL database password: " DATABASEPASSWORD2
    echo
    if [ "$DATABASEPASSWORD" = "$DATABASEPASSWORD2" ]; then
        break
    else
        echo "Passwords do not match. Please try again."
        echo
    fi
done

# Web server hostname
read -p "Enter web server hostname (e.g., librenms.local): " WEBSERVERHOSTNAME
echo

# LDAP Configuration
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

read -p "User filter (default: uid=, or use cn= or sAMAccountName=): " LDAP_USERFILTER
LDAP_USERFILTER=${LDAP_USERFILTER:-uid=}

read -p "Group DN (optional, press enter to skip): " LDAP_GROUPDN

read -p "Admin Group CN (optional, e.g., librenms-admins): " LDAP_ADMIN_GROUP

# Save current network info
CURRENT_IP=$(hostname -I | awk '{print $1}')
CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)

echo
echo "Configuration Summary:"
echo "  Database: librenms"
echo "  Web Host: $WEBSERVERHOSTNAME"
echo "  LDAP Server: $LDAP_SERVER:$LDAP_PORT"
echo "  LDAP Base DN: $LDAP_BASEDN"
echo "  Current IP (NAT): $CURRENT_IP"
echo
read -p "Is this correct? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Installation cancelled. Please run again."
    exit 1
fi

# ==========================================
# SECTION 2: System Update & Package Install
# ==========================================

echo
echo "=========================================="
echo "SECTION 2: Installing System Packages"
echo "=========================================="
echo

apt-get update
apt-get install -y acl curl fping git graphviz imagemagick mariadb-client mariadb-server \
    mtr-tiny nginx-full nmap php-cli php-curl php-fpm php-gd php-gmp php-json php-mbstring \
    php-mysql php-snmp php-xml php-zip php-ldap rrdtool snmp snmpd unzip whois \
    python3-command-runner python3-pymysql python3-dotenv python3-redis python3-setuptools \
    python3-psutil python3-systemd python3-pip traceroute iputils-ping tcpdump vim cron ldap-utils

echo "✓ All packages installed"

# ==========================================
# SECTION 3: Create User & Clone Repository
# ==========================================

echo
echo "=========================================="
echo "SECTION 3: Setting up LibreNMS User"
echo "=========================================="
echo

useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
echo "✓ User 'librenms' created"

echo
echo "Cloning LibreNMS repository..."
cd /opt
git clone https://github.com/librenms/librenms.git
echo "✓ LibreNMS cloned"

# ==========================================
# SECTION 4: Permissions
# ==========================================

echo
echo "=========================================="
echo "SECTION 4: Setting Permissions"
echo "=========================================="
echo

chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
echo "✓ Permissions set"

# ==========================================
# SECTION 5: Composer Dependencies
# ==========================================

echo
echo "=========================================="
echo "SECTION 5: Installing PHP Dependencies"
echo "=========================================="
echo

su - librenms -c "/opt/librenms/scripts/composer_wrapper.php install --no-dev"
echo "✓ Composer dependencies installed"

# ==========================================
# SECTION 6: PHP & System Configuration
# ==========================================

echo
echo "=========================================="
echo "SECTION 6: Configuring PHP & System"
echo "=========================================="
echo

# Set timezone
sed -i 's/;date.timezone =/date.timezone = Asia\/Makassar/' /etc/php/8.3/fpm/php.ini
sed -i 's/;date.timezone =/date.timezone = Asia\/Makassar/' /etc/php/8.3/cli/php.ini

# Increase PHP limits
sed -i 's/max_execution_time = .*/max_execution_time = 300/' /etc/php/8.3/fpm/php.ini
sed -i 's/max_input_time = .*/max_input_time = 300/' /etc/php/8.3/fpm/php.ini
sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php/8.3/fpm/php.ini

timedatectl set-timezone Asia/Makassar

echo "✓ PHP & system timezone configured"

# ==========================================
# SECTION 7: MariaDB Configuration
# ==========================================

echo
echo "=========================================="
echo "SECTION 7: Configuring MariaDB"
echo "=========================================="
echo

sed -i '/\[mysqld\]/a \
innodb_file_per_table=1 \
lower_case_table_names=0' /etc/mysql/mariadb.conf.d/50-server.cnf

systemctl enable mariadb
systemctl restart mariadb

# Create database
mysql -u root <<EOF
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'librenms'@'localhost' IDENTIFIED BY '$DATABASEPASSWORD';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "✓ Database created and configured"

# ==========================================
# SECTION 8: PHP-FPM Pool Configuration
# ==========================================

echo
echo "=========================================="
echo "SECTION 8: Configuring PHP-FPM"
echo "=========================================="
echo

cat > /etc/php/8.3/fpm/pool.d/librenms.conf <<'POOLEOF'
[librenms]
user = librenms
group = librenms
listen = /run/php-fpm-librenms.sock
listen.owner = librenms
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 500

request_terminate_timeout = 300

php_admin_value[error_log] = /var/log/php8.3-fpm.log
php_admin_flag[log_errors] = on
POOLEOF

systemctl restart php8.3-fpm
sleep 3

# Verify socket created
if [ -S /run/php-fpm-librenms.sock ]; then
    echo "✓ PHP-FPM pool configured and socket created"
else
    echo "✗ ERROR: PHP-FPM socket not created!"
    systemctl status php8.3-fpm
    exit 1
fi

# ==========================================
# SECTION 9: Nginx Configuration
# ==========================================

echo
echo "=========================================="
echo "SECTION 9: Configuring Nginx"
echo "=========================================="
echo

cat > /etc/nginx/conf.d/librenms.conf <<NGINXEOF
server {
    listen      80;
    server_name $WEBSERVERHOSTNAME;
    root        /opt/librenms/html;
    index       index.php;

    charset utf-8;
    gzip on;
    gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;

    # Increase timeouts
    client_max_body_size 50M;
    client_body_timeout 300;
    keepalive_timeout 300;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ [^/]\.php(/|\$) {
        fastcgi_pass unix:/run/php-fpm-librenms.sock;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        include fastcgi.conf;
        
        # FastCGI timeouts
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_connect_timeout 300;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINXEOF

# Remove default site
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

# Set permissions
chown -R librenms:librenms /opt/librenms
chmod -R 755 /opt/librenms/html

# Test and restart
nginx -t
if [ $? -eq 0 ]; then
    systemctl restart nginx
    echo "✓ Nginx configured and restarted"
else
    echo "✗ ERROR: Nginx configuration invalid!"
    exit 1
fi

# ==========================================
# SECTION 10: Additional Tools Setup
# ==========================================

echo
echo "=========================================="
echo "SECTION 10: Setting up Additional Tools"
echo "=========================================="
echo

# lnms command
ln -sf /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

# SNMP
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i 's/RANDOMSTRINGGOESHERE/public/' /etc/snmp/snmpd.conf
curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable snmpd
systemctl restart snmpd

# Cron
cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms

# Scheduler
cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

# Logrotate
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

echo "✓ Additional tools configured"

# ==========================================
# SECTION 11: Configure .env File
# ==========================================

echo
echo "=========================================="
echo "SECTION 11: Configuring Environment"
echo "=========================================="
echo

sed -i "s/#DB_HOST=/DB_HOST=localhost/" /opt/librenms/.env
sed -i "s/#DB_DATABASE=/DB_DATABASE=librenms/" /opt/librenms/.env
sed -i "s/#DB_USERNAME=/DB_USERNAME=librenms/" /opt/librenms/.env
sed -i "s/#DB_PASSWORD=/DB_PASSWORD=$DATABASEPASSWORD/" /opt/librenms/.env

echo "✓ Environment configured"

# ==========================================
# SECTION 12: LDAP Configuration
# ==========================================

echo
echo "=========================================="
echo "SECTION 12: Configuring LDAP"
echo "=========================================="
echo

# Determine encryption setting
if [ "$LDAP_TLS" = "yes" ]; then
    LDAP_ENCRYPTION="'encryption' => 'tls',"
else
    LDAP_ENCRYPTION="'encryption' => false,"
fi

# Create config.php
cat > /opt/librenms/config.php <<PHPEOF
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

// Auto-create users on first login
\$config['auth_ldap_autocreate_users'] = true;

PHPEOF

# Add group configuration if provided
if [ -n "$LDAP_GROUPDN" ]; then
    cat >> /opt/librenms/config.php <<PHPEOF

// Group configuration
\$config['auth_ldap_groups']['$LDAP_BASEDN']['group_filter'] = '(objectClass=groupOfNames)';
\$config['auth_ldap_groups']['$LDAP_BASEDN']['group_member_attr'] = 'member';
\$config['auth_ldap_groups']['$LDAP_BASEDN']['group_member_type'] = 'fulldn';

PHPEOF
fi

# Add admin group if provided
if [ -n "$LDAP_ADMIN_GROUP" ]; then
    cat >> /opt/librenms/config.php <<PHPEOF

// Admin group mapping
\$config['auth_ldap_group'] = ['$LDAP_ADMIN_GROUP'];
\$config['auth_ldap_groupbase'] = '$LDAP_GROUPDN';

PHPEOF
fi

echo "?>" >> /opt/librenms/config.php

chown librenms:librenms /opt/librenms/config.php
chmod 640 /opt/librenms/config.php

echo "✓ LDAP configured"

# ==========================================
# SECTION 13: Wait for Log File
# ==========================================

echo
echo "=========================================="
echo "SECTION 13: Finalizing"
echo "=========================================="
echo

# Wait for log file
timeout=30
counter=0
while [ ! -f /opt/librenms/logs/librenms.log ] && [ $counter -lt $timeout ]; do
    echo "Waiting for log file to be created... ($counter/$timeout)"
    sleep 1
    counter=$((counter + 1))
done

if [ -f /opt/librenms/logs/librenms.log ]; then
    chown librenms:librenms /opt/librenms/logs/librenms.log
    echo "✓ Log file permissions set"
else
    echo "⚠ Log file not created yet (will be created on first access)"
fi

# ==========================================
# SECTION 14: Save Configuration
# ==========================================

cat > /root/librenms-install-info.txt <<EOF
========================================
LibreNMS Installation Summary
========================================

Installation Date: $(date)

Database Configuration:
  Database Name: librenms
  Database User: librenms
  Database Password: $DATABASEPASSWORD

Web Configuration:
  Hostname: $WEBSERVERHOSTNAME
  Web Root: /opt/librenms/html

LDAP Configuration:
  Server: $LDAP_SERVER:$LDAP_PORT
  Base DN: $LDAP_BASEDN
  Bind User: $LDAP_BINDUSER
  User DN: $LDAP_USERDN
  User Filter: $LDAP_USERFILTER
  Group DN: $LDAP_GROUPDN
  Admin Group: $LDAP_ADMIN_GROUP

Network During Installation (NAT):
  IP: $CURRENT_IP
  Gateway: $CURRENT_GATEWAY

Important Files:
  Config: /opt/librenms/config.php
  Env: /opt/librenms/.env
  Nginx: /etc/nginx/conf.d/librenms.conf
  PHP-FPM: /etc/php/8.3/fpm/pool.d/librenms.conf

========================================
EOF

chmod 600 /root/librenms-install-info.txt

# ==========================================
# SECTION 15: Final Check
# ==========================================

echo
echo "=========================================="
echo "SECTION 15: Final System Check"
echo "=========================================="
echo

# Check services
echo "Checking services..."
systemctl is-active --quiet mariadb && echo "  ✓ MariaDB: Running" || echo "  ✗ MariaDB: Not running"
systemctl is-active --quiet php8.3-fpm && echo "  ✓ PHP-FPM: Running" || echo "  ✗ PHP-FPM: Not running"
systemctl is-active --quiet nginx && echo "  ✓ Nginx: Running" || echo "  ✗ Nginx: Not running"

# Check socket
if [ -S /run/php-fpm-librenms.sock ]; then
    echo "  ✓ PHP-FPM Socket: Created"
else
    echo "  ✗ PHP-FPM Socket: Not found"
fi

# Test HTTP
echo
echo "Testing HTTP response..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost/ || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "  ✓ HTTP Response: $HTTP_CODE (OK)"
elif [ "$HTTP_CODE" = "000" ]; then
    echo "  ⚠ HTTP Response: Timeout (This is OK before web setup)"
else
    echo "  ⚠ HTTP Response: $HTTP_CODE"
fi

# ==========================================
# COMPLETION MESSAGE
# ==========================================

echo
echo "###############################################"
echo "#                                             #"
echo "#   ✓ INSTALLATION COMPLETE!                  #"
echo "#                                             #"
echo "###############################################"
echo
echo "Installation info saved to: /root/librenms-install-info.txt"
echo
echo "=========================================="
echo "NEXT STEPS:"
echo "=========================================="
echo
echo "1. SHUTDOWN this VM:"
echo "   sudo shutdown -h now"
echo
echo "2. SWITCH Network Adapter:"
echo "   VirtualBox/VMware: NAT → Bridge Adapter"
echo
echo "3. START VM and configure static IP:"
echo "   Run: sudo ./configure-network.sh"
echo "   (Upload this script to VM after restart)"
echo
echo "4. ACCESS LibreNMS:"
echo "   http://YOUR_NEW_IP/install.php"
echo
echo "5. COMPLETE web installation wizard"
echo
echo "6. LOGIN with LDAP credentials:"
echo "   Your LDAP username and password"
echo
echo "=========================================="
echo "Troubleshooting:"
echo "=========================================="
echo
echo "Check services:"
echo "  sudo systemctl status nginx php8.3-fpm mariadb"
echo
echo "Check logs:"
echo "  sudo tail -f /opt/librenms/logs/librenms.log"
echo "  sudo tail -f /var/log/nginx/error.log"
echo
echo "Validate installation:"
echo "  su - librenms"
echo "  ./validate.php"
echo
echo "Enable LDAP debug:"
echo "  sudo nano /opt/librenms/config.php"
echo "  Set: \$config['auth_ldap_debug'] = true;"
echo
echo "=========================================="
echo

exit 0