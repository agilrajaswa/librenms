#!/bin/bash

# ===========================================
# FIX LIBRENMS - File Not Found Error
# ===========================================

set -e

echo "============================================"
echo "🔧 Fixing LibreNMS Installation..."
echo "============================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 1. Verify LibreNMS files exist
echo -e "${YELLOW}[1/8] Checking LibreNMS files...${NC}"
if [ ! -d "/opt/librenms" ]; then
    echo -e "${RED}❌ LibreNMS not found in /opt/librenms${NC}"
    exit 1
fi

if [ ! -f "/opt/librenms/html/index.php" ]; then
    echo -e "${RED}❌ index.php not found!${NC}"
    echo "LibreNMS may not be installed correctly."
    exit 1
fi
echo -e "${GREEN}✓ LibreNMS files exist${NC}"

# 2. Fix ownership and permissions
echo -e "${YELLOW}[2/8] Fixing permissions...${NC}"
sudo chown -R librenms:librenms /opt/librenms
sudo chmod 771 /opt/librenms
sudo chmod -R 775 /opt/librenms/html
sudo chmod -R 775 /opt/librenms/storage
sudo chmod -R 775 /opt/librenms/bootstrap/cache
sudo chmod -R 775 /opt/librenms/logs
sudo chmod -R 775 /opt/librenms/rrd
sudo setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
sudo setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
echo -e "${GREEN}✓ Permissions fixed${NC}"

# 3. Create proper nginx config
echo -e "${YELLOW}[3/8] Configuring Nginx...${NC}"
sudo tee /etc/nginx/sites-available/librenms > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;
    root /opt/librenms/html;
    index index.php;

    charset utf-8;
    gzip on;
    gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ [^/]\.php(/|$) {
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include fastcgi.conf;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_connect_timeout 300;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    # Deny access to sensitive files
    location ~ /\.env {
        deny all;
    }

    location ~ /config.php {
        deny all;
    }
}
EOF

# Remove default site
sudo rm -f /etc/nginx/sites-enabled/default

# Enable LibreNMS site
sudo ln -sf /etc/nginx/sites-available/librenms /etc/nginx/sites-enabled/librenms

# Test nginx config
if ! sudo nginx -t; then
    echo -e "${RED}❌ Nginx configuration error!${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Nginx configured${NC}"

# 4. Configure PHP-FPM
echo -e "${YELLOW}[4/8] Configuring PHP-FPM...${NC}"
sudo sed -i 's/^user = .*/user = librenms/' /etc/php/8.2/fpm/pool.d/www.conf
sudo sed -i 's/^group = .*/group = librenms/' /etc/php/8.2/fpm/pool.d/www.conf
sudo sed -i 's/^listen.owner = .*/listen.owner = www-data/' /etc/php/8.2/fpm/pool.d/www.conf
sudo sed -i 's/^listen.group = .*/listen.group = www-data/' /etc/php/8.2/fpm/pool.d/www.conf

# Update PHP settings
for conf in /etc/php/8.2/fpm/php.ini /etc/php/8.2/cli/php.ini; do
    sudo sed -i 's/^max_execution_time = .*/max_execution_time = 300/' $conf
    sudo sed -i 's/^memory_limit = .*/memory_limit = 512M/' $conf
    sudo sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 16M/' $conf
    sudo sed -i 's/^post_max_size = .*/post_max_size = 16M/' $conf
done
echo -e "${GREEN}✓ PHP-FPM configured${NC}"

# 5. Setup LibreNMS config if not exists
echo -e "${YELLOW}[5/8] Checking LibreNMS config...${NC}"
if [ ! -f "/opt/librenms/config.php" ]; then
    echo -e "${YELLOW}Creating initial config.php...${NC}"
    sudo -u librenms tee /opt/librenms/config.php > /dev/null <<'PHPEOF'
<?php
// Database config - will be set during web install
$config['db_host'] = 'localhost';
$config['db_user'] = 'librenms';
$config['db_pass'] = 'LibreNMS_DB_Pass123!';
$config['db_name'] = 'librenms';

// Base URL
$config['base_url'] = '/';

// Enable installer
$config['install'] = true;
PHPEOF
    sudo chown librenms:librenms /opt/librenms/config.php
    sudo chmod 660 /opt/librenms/config.php
fi
echo -e "${GREEN}✓ Config checked${NC}"

# 6. Initialize database if needed
echo -e "${YELLOW}[6/8] Checking database...${NC}"
DB_EXISTS=$(sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = 'librenms'" | grep librenms || echo "")

if [ -z "$DB_EXISTS" ]; then
    echo -e "${YELLOW}Creating database...${NC}"
    sudo mysql <<SQLEOF
CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'librenms'@'localhost' IDENTIFIED BY 'LibreNMS_DB_Pass123!';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
SQLEOF
fi
echo -e "${GREEN}✓ Database ready${NC}"

# 7. Restart services
echo -e "${YELLOW}[7/8] Restarting services...${NC}"
sudo systemctl restart php8.2-fpm
sudo systemctl restart nginx
sleep 2
echo -e "${GREEN}✓ Services restarted${NC}"

# 8. Verify services
echo -e "${YELLOW}[8/8] Verifying services...${NC}"

# Check PHP-FPM
if ! sudo systemctl is-active --quiet php8.2-fpm; then
    echo -e "${RED}❌ PHP-FPM is not running!${NC}"
    sudo systemctl status php8.2-fpm
    exit 1
fi
echo -e "${GREEN}✓ PHP-FPM is running${NC}"

# Check Nginx
if ! sudo systemctl is-active --quiet nginx; then
    echo -e "${RED}❌ Nginx is not running!${NC}"
    sudo systemctl status nginx
    exit 1
fi
echo -e "${GREEN}✓ Nginx is running${NC}"

# Check if index.php is accessible
if [ ! -r "/opt/librenms/html/index.php" ]; then
    echo -e "${RED}❌ index.php is not readable!${NC}"
    exit 1
fi
echo -e "${GREEN}✓ index.php is accessible${NC}"

# 9. Show final info
echo ""
echo "============================================"
echo -e "${GREEN}✅ LibreNMS Fixed Successfully!${NC}"
echo "============================================"
echo ""
echo "📋 Next Steps:"
echo "1. Open browser and go to: http://$(hostname -I | awk '{print $1}')"
echo "2. If you see LibreNMS page, installation is working!"
echo ""
echo "🔍 If still getting errors, check logs:"
echo "   sudo tail -f /var/log/nginx/error.log"
echo "   sudo tail -f /opt/librenms/logs/librenms.log"
echo ""
echo "🌐 Your IP: $(hostname -I | awk '{print $1}')"
echo "============================================"