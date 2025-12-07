#!/bin/bash

echo "=========================================="
echo "LibreNMS 504 Gateway Timeout Fix"
echo "=========================================="
echo

# Check 1: Database Connection
echo "[1/6] Testing database connection..."
if mysql -u librenms -e "USE librenms; SELECT 1;" >/dev/null 2>&1; then
    echo "✓ Database connection OK (no password)"
else
    echo "Testing with password from .env..."
    DB_PASS=$(grep DB_PASSWORD /opt/librenms/.env | cut -d'=' -f2)
    if [ -n "$DB_PASS" ]; then
        if mysql -u librenms -p"$DB_PASS" -e "USE librenms; SELECT 1;" >/dev/null 2>&1; then
            echo "✓ Database connection OK (with password)"
        else
            echo "✗ Database connection FAILED"
            echo "  This is likely the cause of 504 timeout"
            echo
            echo "Checking database status..."
            systemctl status mariadb
            echo
            echo "Try fixing database:"
            echo "  sudo mysql -u root"
            echo "  GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';"
            echo "  FLUSH PRIVILEGES;"
            exit 1
        fi
    else
        echo "✗ No DB password found in .env"
        exit 1
    fi
fi
echo

# Check 2: Increase PHP-FPM Timeouts
echo "[2/6] Increasing PHP-FPM timeout settings..."

# Backup pool config
cp /etc/php/8.3/fpm/pool.d/librenms.conf /etc/php/8.3/fpm/pool.d/librenms.conf.backup

# Add or update timeout settings
if grep -q "request_terminate_timeout" /etc/php/8.3/fpm/pool.d/librenms.conf; then
    sed -i 's/request_terminate_timeout.*/request_terminate_timeout = 300/' /etc/php/8.3/fpm/pool.d/librenms.conf
else
    echo "request_terminate_timeout = 300" >> /etc/php/8.3/fpm/pool.d/librenms.conf
fi

if grep -q "pm.max_children" /etc/php/8.3/fpm/pool.d/librenms.conf; then
    sed -i 's/pm.max_children.*/pm.max_children = 50/' /etc/php/8.3/fpm/pool.d/librenms.conf
else
    echo "pm.max_children = 50" >> /etc/php/8.3/fpm/pool.d/librenms.conf
fi

echo "✓ PHP-FPM timeout set to 300 seconds"
echo

# Check 3: Increase PHP max_execution_time
echo "[3/6] Increasing PHP max_execution_time..."

sed -i 's/max_execution_time = .*/max_execution_time = 300/' /etc/php/8.3/fpm/php.ini
sed -i 's/max_input_time = .*/max_input_time = 300/' /etc/php/8.3/fpm/php.ini
sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php/8.3/fpm/php.ini

echo "✓ PHP execution time set to 300 seconds"
echo "✓ PHP memory limit set to 512M"
echo

# Check 4: Increase Nginx Timeout
echo "[4/6] Increasing Nginx timeout settings..."

# Backup nginx config
cp /etc/nginx/conf.d/librenms.conf /etc/nginx/conf.d/librenms.conf.backup

# Add timeout settings if not exists
if ! grep -q "fastcgi_read_timeout" /etc/nginx/conf.d/librenms.conf; then
    # Insert timeout settings before fastcgi_pass line
    sed -i '/fastcgi_pass/i\  fastcgi_read_timeout 300;\n  fastcgi_send_timeout 300;\n  fastcgi_connect_timeout 300;' /etc/nginx/conf.d/librenms.conf
    echo "✓ Nginx fastcgi timeout set to 300 seconds"
else
    sed -i 's/fastcgi_read_timeout .*/fastcgi_read_timeout 300;/' /etc/nginx/conf.d/librenms.conf
    sed -i 's/fastcgi_send_timeout .*/fastcgi_send_timeout 300;/' /etc/nginx/conf.d/librenms.conf
    sed -i 's/fastcgi_connect_timeout .*/fastcgi_connect_timeout 300;/' /etc/nginx/conf.d/librenms.conf
    echo "✓ Nginx fastcgi timeout updated to 300 seconds"
fi

# Add proxy timeout in main server block if not exists
if ! grep -q "client_max_body_size" /etc/nginx/conf.d/librenms.conf; then
    sed -i '/server_name/a\  client_max_body_size 50M;\n  client_body_timeout 300;\n  keepalive_timeout 300;' /etc/nginx/conf.d/librenms.conf
fi

echo

# Check 5: Test Nginx config
echo "[5/6] Testing Nginx configuration..."
if nginx -t 2>&1 | grep -q "successful"; then
    echo "✓ Nginx configuration is valid"
else
    echo "✗ Nginx configuration has errors:"
    nginx -t
    echo
    echo "Restoring backup..."
    cp /etc/nginx/conf.d/librenms.conf.backup /etc/nginx/conf.d/librenms.conf
    exit 1
fi
echo

# Check 6: Restart Services
echo "[6/6] Restarting services..."
systemctl restart php8.3-fpm
echo "✓ PHP-FPM restarted"
sleep 2

systemctl restart nginx
echo "✓ Nginx restarted"
sleep 2

echo
echo "=========================================="
echo "Testing LibreNMS..."
echo "=========================================="
echo

# Test with longer timeout
echo "Attempting to access homepage (may take a moment)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 60 http://localhost/)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ SUCCESS! HTTP 200 OK"
    echo
    echo "LibreNMS should now be accessible at:"
    echo "  http://192.168.1.17"
    echo
elif [ "$HTTP_CODE" = "504" ] || [ "$HTTP_CODE" = "000" ]; then
    echo "✗ Still timing out or taking too long"
    echo
    echo "Additional checks needed:"
    echo
    
    # Check if web installer needs to be run
    echo "Checking if web installer completed..."
    if [ ! -f /opt/librenms/.env.php ]; then
        echo "✗ Web installer NOT completed yet"
        echo
        echo "You need to complete web installation:"
        echo "1. Open: http://192.168.1.17/install"
        echo "2. Follow the installation wizard"
        echo "3. The timeout was likely because database is not initialized"
    else
        echo "✓ Web installer appears to be completed"
        echo
        echo "Checking for other issues..."
        
        # Check PHP-FPM processes
        PHP_PROCS=$(ps aux | grep php-fpm | grep -v grep | wc -l)
        echo "PHP-FPM processes: $PHP_PROCS"
        
        if [ $PHP_PROCS -lt 2 ]; then
            echo "✗ Not enough PHP-FPM processes running"
            echo "  Starting more processes..."
            systemctl restart php8.3-fpm
        fi
        
        # Check database tables
        TABLE_COUNT=$(mysql -u librenms -p"$DB_PASS" -D librenms -e "SHOW TABLES;" 2>/dev/null | wc -l)
        echo "Database tables: $TABLE_COUNT"
        
        if [ $TABLE_COUNT -lt 10 ]; then
            echo "✗ Database not fully initialized"
            echo "  Run web installer: http://192.168.1.17/install"
        fi
    fi
else
    echo "HTTP Status: $HTTP_CODE"
fi

echo
echo "=========================================="
echo "Diagnostic Information"
echo "=========================================="
echo

echo "Service Status:"
systemctl is-active php8.3-fpm && echo "  PHP-FPM: ✓ Running" || echo "  PHP-FPM: ✗ Not running"
systemctl is-active nginx && echo "  Nginx: ✓ Running" || echo "  Nginx: ✗ Not running"
systemctl is-active mariadb && echo "  MariaDB: ✓ Running" || echo "  MariaDB: ✗ Not running"

echo
echo "Recent errors (if any):"
echo "--- PHP-FPM Errors ---"
tail -10 /var/log/php8.3-fpm.log 2>/dev/null | grep -i error || echo "  No recent errors"

echo
echo "--- Nginx Errors ---"
tail -10 /var/log/nginx/error.log 2>/dev/null | grep -v "client intended" || echo "  No recent errors"

echo
echo "--- LibreNMS Logs ---"
tail -10 /opt/librenms/logs/librenms.log 2>/dev/null | grep -i error || echo "  No recent errors"

echo
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo
echo "1. Try accessing: http://192.168.1.17"
echo
echo "2. If you see installer page, complete the installation"
echo
echo "3. If still timeout, try accessing install page directly:"
echo "   http://192.168.1.17/install.php"
echo
echo "4. Monitor logs while accessing:"
echo "   sudo tail -f /opt/librenms/logs/librenms.log"
echo
echo "5. Check PHP errors:"
echo "   sudo tail -f /var/log/php8.3-fpm.log"
echo

exit 0