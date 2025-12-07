#!/bin/bash

# Network Configuration Script for LibreNMS
# Run after switching from NAT to Bridge Adapter

set -e

echo
echo "###############################################"
echo "#                                             #"
echo "#   LibreNMS Network Configuration            #"
echo "#   Bridge Adapter Setup                      #"
echo "#                                             #"
echo "###############################################"
echo

# Detect current interface
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$INTERFACE" ]; then
    echo "Could not detect network interface automatically."
    echo "Available interfaces:"
    ip link show | grep -E "^[0-9]+" | awk '{print $2}' | sed 's/://g'
    echo
    read -p "Enter interface name (e.g., ens33, eth0): " INTERFACE
fi

echo "Using network interface: $INTERFACE"
echo

# Get current IP (if any)
CURRENT_IP=$(ip addr show $INTERFACE | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -1)
if [ -n "$CURRENT_IP" ]; then
    echo "Current IP: $CURRENT_IP"
fi
echo

# Input static IP configuration
echo "=========================================="
echo "Static IP Configuration"
echo "=========================================="
echo
echo "LDAP Server is at: 192.168.1.15"
echo "Choose an IP in the same network (192.168.1.x)"
echo

while true; do
    read -p "Enter static IP address (e.g., 192.168.1.17): " STATIC_IP
    
    # Validate IP format
    if [[ $STATIC_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        # Check if in same network as LDAP
        if [[ $STATIC_IP =~ ^192\.168\.1\. ]]; then
            break
        else
            echo "⚠ Warning: IP is not in 192.168.1.x network (same as LDAP server)"
            read -p "Continue anyway? (yes/no): " CONFIRM
            if [ "$CONFIRM" = "yes" ]; then
                break
            fi
        fi
    else
        echo "Invalid IP format. Please try again."
    fi
done

read -p "Enter subnet prefix (default 24 for /24): " PREFIX
PREFIX=${PREFIX:-24}

read -p "Enter gateway IP (e.g., 192.168.1.1): " GATEWAY

read -p "Enter primary DNS server (default: $GATEWAY): " DNS1
DNS1=${DNS1:-$GATEWAY}

read -p "Enter secondary DNS server (default: 8.8.8.8): " DNS2
DNS2=${DNS2:-8.8.8.8}

echo
echo "=========================================="
echo "Configuration Summary:"
echo "=========================================="
echo "  Interface: $INTERFACE"
echo "  IP Address: $STATIC_IP/$PREFIX"
echo "  Gateway: $GATEWAY"
echo "  DNS 1: $DNS1"
echo "  DNS 2: $DNS2"
echo "=========================================="
echo
read -p "Is this correct? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Configuration cancelled. Please run again."
    exit 1
fi

# Backup existing netplan config
echo
echo "Backing up existing configuration..."
mkdir -p /root/netplan-backup
cp /etc/netplan/*.yaml /root/netplan-backup/ 2>/dev/null || true
echo "✓ Backup created in /root/netplan-backup/"

# Find netplan config file
NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
if [ -z "$NETPLAN_FILE" ]; then
    NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
    echo "Creating new netplan config file..."
fi

echo "Using config file: $NETPLAN_FILE"

# Create netplan configuration
cat > $NETPLAN_FILE <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      addresses:
        - $STATIC_IP/$PREFIX
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS1
          - $DNS2
EOF

echo "✓ Netplan configuration created"

# Test netplan config
echo
echo "Testing netplan configuration..."
if netplan try --timeout 10; then
    echo "✓ Configuration test passed"
else
    echo "✗ Configuration test failed"
    echo "Restoring backup..."
    cp /root/netplan-backup/*.yaml $NETPLAN_FILE 2>/dev/null
    echo "Please check your network settings and try again."
    exit 1
fi

# Apply configuration
echo
echo "Applying network configuration..."
netplan apply

echo "✓ Network configuration applied"
echo
echo "Waiting for network to stabilize..."
sleep 5

# Verify new IP
NEW_IP=$(ip addr show $INTERFACE | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -1)
echo "Current IP: $NEW_IP"

# Test connectivity
echo
echo "=========================================="
echo "Testing Network Connectivity"
echo "=========================================="
echo

# Test 1: Gateway
echo "[1/4] Testing gateway ($GATEWAY)..."
if ping -c 3 -W 2 $GATEWAY >/dev/null 2>&1; then
    echo "  ✓ Gateway is reachable"
else
    echo "  ✗ Gateway is NOT reachable"
    echo "  Please check your network configuration"
fi

# Test 2: DNS
echo
echo "[2/4] Testing DNS resolution..."
if nslookup google.com $DNS1 >/dev/null 2>&1; then
    echo "  ✓ DNS resolution working"
else
    echo "  ⚠ DNS resolution may not be working"
fi

# Test 3: LDAP Server
echo
echo "[3/4] Testing LDAP server (192.168.1.15)..."
if ping -c 3 -W 2 192.168.1.15 >/dev/null 2>&1; then
    echo "  ✓ LDAP server is reachable"
else
    echo "  ✗ LDAP server (192.168.1.15) is NOT reachable"
    echo "  This will prevent LDAP authentication from working"
fi

# Test 4: LDAP Port
echo
echo "[4/4] Testing LDAP port (389)..."
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/192.168.1.15/389" 2>/dev/null; then
    echo "  ✓ LDAP port 389 is accessible"
else
    echo "  ✗ LDAP port 389 is NOT accessible"
    echo "  Please check firewall on LDAP server (192.168.1.15)"
fi

# Test LibreNMS services
echo
echo "=========================================="
echo "Checking LibreNMS Services"
echo "=========================================="
echo

systemctl is-active --quiet mariadb && echo "  ✓ MariaDB: Running" || echo "  ✗ MariaDB: Not running"
systemctl is-active --quiet php8.3-fpm && echo "  ✓ PHP-FPM: Running" || echo "  ✗ PHP-FPM: Not running"
systemctl is-active --quiet nginx && echo "  ✓ Nginx: Running" || echo "  ✗ Nginx: Not running"

# Check socket
if [ -S /run/php-fpm-librenms.sock ]; then
    echo "  ✓ PHP-FPM Socket: OK"
else
    echo "  ⚠ PHP-FPM Socket: Not found, restarting..."
    systemctl restart php8.3-fpm
    sleep 2
    if [ -S /run/php-fpm-librenms.sock ]; then
        echo "  ✓ PHP-FPM Socket: Created"
    else
        echo "  ✗ PHP-FPM Socket: Still not found"
    fi
fi

# Test HTTP
echo
echo "Testing HTTP response..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost/ || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "  ✓ HTTP Response: $HTTP_CODE (OK)"
elif [ "$HTTP_CODE" = "000" ]; then
    echo "  ⚠ HTTP Timeout (May be normal before web setup)"
else
    echo "  ⚠ HTTP Response: $HTTP_CODE"
fi

# Save configuration
cat > /root/network-config.txt <<EOF
LibreNMS Network Configuration
===============================

Date: $(date)

Network Configuration:
  Interface: $INTERFACE
  IP Address: $STATIC_IP/$PREFIX
  Gateway: $GATEWAY
  DNS 1: $DNS1
  DNS 2: $DNS2

LDAP Server: 192.168.1.15:389

Access URLs:
  Web Interface: http://$STATIC_IP
  Web Installer: http://$STATIC_IP/install.php

Netplan Config: $NETPLAN_FILE
Backup Location: /root/netplan-backup/

Installation Info: /root/librenms-install-info.txt
EOF

chmod 600 /root/network-config.txt

# Final message
echo
echo "###############################################"
echo "#                                             #"
echo "#   ✓ NETWORK CONFIGURATION COMPLETE!         #"
echo "#                                             #"
echo "###############################################"
echo
echo "Network info saved to: /root/network-config.txt"
echo
echo "=========================================="
echo "ACCESS LIBRENMS:"
echo "=========================================="
echo
echo "From your browser (on same network):"
echo
echo "  http://$STATIC_IP/install.php"
echo
echo "Complete the web installation wizard, then:"
echo
echo "  Login with your LDAP credentials"
echo "  Username: your_ldap_username"
echo "  Password: your_ldap_password"
echo
echo "=========================================="
echo "TROUBLESHOOTING:"
echo "=========================================="
echo
echo "If you cannot access the web interface:"
echo
echo "1. Check services are running:"
echo "   sudo systemctl status nginx php8.3-fpm mariadb"
echo
echo "2. Restart services if needed:"
echo "   sudo systemctl restart php8.3-fpm nginx"
echo
echo "3. Check logs:"
echo "   sudo tail -f /var/log/nginx/error.log"
echo "   sudo tail -f /opt/librenms/logs/librenms.log"
echo
echo "4. Test from VM itself:"
echo "   curl -I http://localhost"
echo
echo "5. Test LDAP connection:"
echo "   ldapsearch -x -H ldap://192.168.1.15:389 \\"
echo "     -D \"cn=admin,dc=example,dc=com\" \\"
echo "     -w \"password\" -b \"dc=example,dc=com\""
echo
echo "=========================================="
echo "FIREWALL (if needed):"
echo "=========================================="
echo
echo "If firewall is blocking, allow HTTP:"
echo "  sudo ufw allow 80/tcp"
echo "  sudo ufw allow from 192.168.1.0/24"
echo
echo "=========================================="
echo

exit 0