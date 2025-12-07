#!/bin/bash

# ===========================================
# INSTALL LIBRENMS - COMPLETE VERSION
# ===========================================

set -e

echo "=========================================="
echo "Installing LibreNMS"
echo "=========================================="
echo

# Input
read -sp "Enter MySQL password for librenms user: " DB_PASSWORD
echo
read -p "Enter hostname (default: librenms): " HOSTNAME
HOSTNAME=${HOSTNAME:-librenms}

echo
echo "[1/15] Updating system..."
sudo apt update
sudo apt upgrade -y

echo "[2/15] Installing packages..."
sudo apt install -y acl curl fping git graphviz imagemagick mariadb-client mariadb-server \
  mtr-tiny nginx-full nmap php-cli php-curl php-fpm php-gd php-gmp php-json php-mbstring \
  php-mysql php-snmp php-xml php-zip rrdtool snmp snmpd unzip python3-pymysql python3-dotenv \
  python3-redis python3-setuptools python3-systemd python3-pip whois ldap-utils

echo "[3/15] Creating librenms user..."
sudo useradd librenms -d /opt/librenms -M -r -s "$(which bash)" 2>/dev/null || echo "User exists"

echo "[4/15] Cloning LibreNMS..."
cd /opt
sudo rm -rf librenms 2>/dev/null || true

# Try multiple methods
if sudo git clone https://github.com/librenms/librenms.git; then
    echo "✓ Clone successful"
elif sudo git clone --depth 1 https://github.com/librenms/librenms.git; then
    echo "✓ Clone successful (shallow)"
else
    echo "✗ Git clone failed. Check internet connection."
    exit 1
fi

echo "[5/15] Setting permissions..."
sudo chown -R librenms:librenms /opt/librenms
sudo chmod 771 /opt/librenms
sudo setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
sudo setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/

echo "[6/15] Installing PHP dependencies..."
cd /opt/librenms
sudo -u librenms ./scripts/composer_wrapper.php install --no-dev

echo "[7/15] Setting timezone..."
sudo timedatectl set-timezone Asia/Jakarta
sudo sed -i 's/;date.timezone =/date.timezone = Asia\/Jakarta/' /etc/php/8.*/fpm/php.ini
sudo sed -i 's/;date.timezone =/date.timezone = Asia\/Jakarta/' /etc/php/8.*/cli/php.ini

echo "[8/15] Configuring MariaDB..."
sudo systemctl enable mariadb
sudo systemctl start mariadb

sudo mysql -e "CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS 'librenms'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
sudo mysql -e "GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

sudo tee /etc/mysql/mariadb.conf.d/50-librenms.cnf > /dev/null <<EOF
[mysqld]
innodb_file_per_table=1
lower_case_table_names=0
EOF

sudo systemctl restart mariadb

echo "[9/15] Configuring PHP-FPM..."
PHP_VERSION=$(php -v | head -n1 | cut -d' ' -f2 | cut -d'.' -f1,2)

sudo cp /etc/php/$PHP_VERSION/fpm/pool.d/www.conf /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf
sudo sed -i 's/\[www\]/[librenms]/' /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf
sudo sed -i 's/user = www-data/user = librenms/' /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf
sudo sed -i 's/group = www-data/group = librenms/' /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf
sudo sed -i "s|listen = /run/php/php$PHP_VERSION-fpm.sock|listen = /run/php-fpm-librenms.sock|" /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf

echo "[10/15] Configuring Nginx..."
sudo tee /etc/nginx/sites-available/librenms > /dev/null <<EOF
server {
    listen 80;
    server_name $HOSTNAME _;
    root /opt/librenms/html;
    index index.php;

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
        fastcgi_read_timeout 300;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/librenms /etc/nginx/sites-enabled/
sudo nginx -t

echo "[11/15] Creating lnms command..."
sudo ln -sf /opt/librenms/lnms /usr/bin/lnms
sudo cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

echo "[12/15] Configuring SNMP..."
sudo cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sudo sed -i 's/RANDOMSTRINGGOESHERE/public/' /etc/snmp/snmpd.conf
sudo curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
sudo chmod +x /usr/bin/distro
sudo systemctl enable snmpd
sudo systemctl restart snmpd

echo "[13/15] Setting up cron and scheduler..."
sudo cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms
sudo cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
sudo systemctl enable librenms-scheduler.timer
sudo systemctl start librenms-scheduler.timer

echo "[14/15] Configuring logrotate..."
sudo cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

echo "[15/15] Setting up .env file..."
sudo sed -i "s/#DB_HOST=/DB_HOST=localhost/" /opt/librenms/.env
sudo sed -i "s/#DB_DATABASE=/DB_DATABASE=librenms/" /opt/librenms/.env
sudo sed -i "s/#DB_USERNAME=/DB_USERNAME=librenms/" /opt/librenms/.env
sudo sed -i "s/#DB_PASSWORD=/DB_PASSWORD=$DB_PASSWORD/" /opt/librenms/.env

echo "Restarting services..."
sudo systemctl restart php$PHP_VERSION-fpm
sudo systemctl restart nginx

echo
echo "=========================================="
echo "✅ LibreNMS Installation Complete!"
echo "=========================================="
echo
echo "🌐 Open browser: http://$(hostname -I | awk '{print $1}')"
echo "📋 Complete web setup first"
echo "🔐 Database credentials:"
echo "   DB: librenms"
echo "   User: librenms"
echo "   Pass: $DB_PASSWORD"
echo "=========================================="

exit 0