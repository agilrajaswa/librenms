#!/bin/bash

echo "=========================================="
echo "LibreNMS 502 Bad Gateway Troubleshooter"
echo "=========================================="
echo

# Check 1: PHP-FPM Service Status
echo "[1/8] Checking PHP-FPM service status..."
if systemctl is-active --quiet php8.3-fpm; then
    echo "✓ PHP-FPM is running"
else
    echo "✗ PHP-FPM is NOT running"
    echo "  Starting PHP-FPM..."
    systemctl start php8.3-fpm
    sleep 2
    if systemctl is-active --quiet php8.3-fpm; then
        echo "✓ PHP-FPM started successfully"
    else
        echo "✗ Failed to start PHP-FPM"
        echo "  Check error: systemctl status php8.3-fpm"
        exit 1
    fi
fi
echo

# Check 2: PHP-FPM Socket File
echo "[2/8] Checking PHP-FPM socket file..."
if [ -S /run/php-fpm-librenms.sock ]; then
    echo "✓ Socket file exists: /run/php-fpm-librenms.sock"
    ls -la /run/php-fpm-librenms.sock
else
    echo "✗ Socket file NOT found: /run/php-fpm-librenms.sock"
    echo "  This is the main problem!"
    echo
    echo "Checking PHP-FPM pool configuration..."
    if [ -f /etc/php/8.3/fpm/pool.d/librenms.conf ]; then
        echo "✓ Pool config exists"
        echo "  Socket path in config:"
        grep "listen = " /etc/php/8.3/fpm/pool.d/librenms.conf
    else
        echo "✗ Pool config NOT found"
        echo "  Creating librenms pool config..."
        
        cp /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.3/fpm/pool.d/librenms.conf
        sed -i 's/user = www-data/user = librenms/' /etc/php/8.3/fpm/pool.d/librenms.conf
        sed -i 's/group = www-data/group = librenms/' /etc/php/8.3/fpm/pool.d/librenms.conf
        sed -i 's/\[www\]/\[librenms\]/' /etc/php/8.3/fpm/pool.d/librenms.conf
        sed -i 's|listen = /run/php/php8.3-fpm.sock|listen = /run/php-fpm-librenms.sock|' /etc/php/8.3/fpm/pool.d/librenms.conf
        
        echo "✓ Pool config created"
    fi
    
    echo "  Restarting PHP-FPM..."
    systemctl restart php8.3-fpm
    sleep 3
    
    if [ -S /run/php-fpm-librenms.sock ]; then
        echo "✓ Socket file now exists!"
    else
        echo "✗ Socket file still not created"
        echo "  Checking PHP-FPM error log..."
        tail -20 /var/log/php8.3-fpm.log
        exit 1
    fi
fi
echo

# Check 3: Socket Permissions
echo "[3/8] Checking socket permissions..."
SOCKET_PERMS=$(stat -c "%a" /run/php-fpm-librenms.sock 2>/dev/null)
SOCKET_OWNER=$(stat -c "%U:%G" /run/php-fpm-librenms.sock 2>/dev/null)
echo "  Permissions: $SOCKET_PERMS"
echo "  Owner: $SOCKET_OWNER"

if [ "$SOCKET_PERMS" != "660" ] && [ "$SOCKET_PERMS" != "666" ]; then
    echo "  Warning: Permissions might be too restrictive"
    echo "  Fixing permissions..."
    chmod 660 /run/php-fpm-librenms.sock
fi
echo

# Check 4: Nginx Service Status
echo "[4/8] Checking Nginx service status..."
if systemctl is-active --quiet nginx; then
    echo "✓ Nginx is running"
else
    echo "✗ Nginx is NOT running"
    echo "  Starting Nginx..."
    systemctl start nginx
fi
echo

# Check 5: Nginx Configuration
echo "[5/8] Checking Nginx configuration..."
if nginx -t 2>&1 | grep -q "successful"; then
    echo "✓ Nginx configuration is valid"
else
    echo "✗ Nginx configuration has errors:"
    nginx -t
    exit 1
fi
echo

# Check 6: Nginx Config for LibreNMS
echo "[6/8] Checking Nginx LibreNMS config..."
if [ -f /etc/nginx/conf.d/librenms.conf ]; then
    echo "✓ LibreNMS Nginx config exists"
    echo "  FastCGI pass setting:"
    grep "fastcgi_pass" /etc/nginx/conf.d/librenms.conf
    
    # Verify it points to correct socket
    if grep -q "unix:/run/php-fpm-librenms.sock" /etc/nginx/conf.d/librenms.conf; then
        echo "✓ FastCGI points to correct socket"
    else
        echo "✗ FastCGI socket path is incorrect"
        echo "  Fixing..."
        sed -i 's|fastcgi_pass unix:.*|fastcgi_pass unix:/run/php-fpm-librenms.sock;|' /etc/nginx/conf.d/librenms.conf
        nginx -t && systemctl reload nginx
        echo "✓ Fixed and reloaded Nginx"
    fi
else
    echo "✗ LibreNMS Nginx config NOT found"
    echo "  This needs to be created manually"
    exit 1
fi
echo

# Check 7: LibreNMS Directory Permissions
echo "[7/8] Checking LibreNMS directory permissions..."
if [ -d /opt/librenms/html ]; then
    HTML_OWNER=$(stat -c "%U:%G" /opt/librenms/html)
    echo "  /opt/librenms/html owner: $HTML_OWNER"
    
    # Fix ownership if needed
    if [ "$HTML_OWNER" != "librenms:librenms" ] && [ "$HTML_OWNER" != "www-data:www-data" ]; then
        echo "  Fixing ownership..."
        chown -R librenms:librenms /opt/librenms
        chmod 771 /opt/librenms
    fi
    
    # Ensure www-data can read html directory
    if [ ! -r /opt/librenms/html/index.php ]; then
        echo "  Making html readable by www-data..."
        chmod -R 755 /opt/librenms/html
    fi
    echo "✓ Directory permissions OK"
else
    echo "✗ /opt/librenms/html directory not found!"
    exit 1
fi
echo

# Check 8: Test with curl
echo "[8/8] Testing HTTP response..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
echo "  HTTP Status Code: $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Website is responding correctly!"
elif [ "$HTTP_CODE" = "502" ]; then
    echo "✗ Still getting 502 Bad Gateway"
    echo
    echo "Checking logs for more details..."
    echo
    echo "=== Nginx Error Log (last 20 lines) ==="
    tail -20 /var/log/nginx/error.log
    echo
    echo "=== PHP-FPM Error Log (last 20 lines) ==="
    tail -20 /var/log/php8.3-fpm.log
else
    echo "  HTTP code: $HTTP_CODE"
fi
echo

# Final restart
echo "=========================================="
echo "Performing final service restart..."
echo "=========================================="
systemctl restart php8.3-fpm
sleep 2
systemctl restart nginx
sleep 2

echo
echo "Testing again after restart..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
echo "HTTP Status Code: $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ]; then
    echo
    echo "=========================================="
    echo "✓ SUCCESS! 502 Error Fixed!"
    echo "=========================================="
    echo
    echo "You can now access LibreNMS at:"
    echo "  http://192.168.1.17"
    echo
else
    echo
    echo "=========================================="
    echo "Additional Troubleshooting Needed"
    echo "=========================================="
    echo
    echo "Please run these commands manually:"
    echo
    echo "1. Check PHP-FPM status:"
    echo "   systemctl status php8.3-fpm"
    echo
    echo "2. Check PHP-FPM logs:"
    echo "   tail -50 /var/log/php8.3-fpm.log"
    echo
    echo "3. Check Nginx error log:"
    echo "   tail -50 /var/log/nginx/error.log"
    echo
    echo "4. Verify socket exists:"
    echo "   ls -la /run/php-fpm-librenms.sock"
    echo
    echo "5. Test PHP-FPM manually:"
    echo "   su - librenms -c 'php /opt/librenms/html/index.php'"
    echo
fi

exit 0