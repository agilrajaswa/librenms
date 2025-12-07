#!/bin/bash

echo "=========================================="
echo "Switch to Bridge Adapter Helper"
echo "=========================================="
echo
echo "This script will help you configure static IP"
echo "after switching from NAT to Bridge Adapter"
echo

# Detect network interface
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$INTERFACE" ]; then
    INTERFACE="ens33"
    echo "Could not detect interface, using default: $INTERFACE"
else
    echo "Detected network interface: $INTERFACE"
fi
echo

# Input static IP configuration
read -p "Enter static IP address (e.g., 192.168.1.20): " STATIC_IP
read -p "Enter subnet prefix (default 24 for /24): " PREFIX
PREFIX=${PREFIX:-24}
read -p "Enter gateway IP (e.g., 192.168.1.1): " GATEWAY
read -p "Enter DNS server (default 192.168.1.1): " DNS
DNS=${DNS:-$GATEWAY}

echo
echo "Configuration summary:"
echo "  Interface: $INTERFACE"
echo "  IP: $STATIC_IP/$PREFIX"
echo "  Gateway: $GATEWAY"
echo "  DNS: $DNS"
echo
read -p "Is this correct? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled. Please run the script again."
    exit 1
fi

# Backup existing netplan config
echo
echo "Backing up existing netplan config..."
cp /etc/netplan/*.yaml /etc/netplan/backup-$(date +%Y%m%d-%H%M%S).yaml 2>/dev/null || true

# Create new netplan config
NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
echo "Creating new netplan configuration..."

cat > $NETPLAN_FILE <<EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      addresses:
        - $STATIC_IP/$PREFIX
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS
          - 8.8.8.8
EOF

echo "✓ Netplan config created at: $NETPLAN_FILE"
echo

# Test netplan config
echo "Testing netplan configuration..."
if netplan try --timeout 10; then
    echo "✓ Netplan configuration is valid"
else
    echo "✗ Netplan configuration has errors"
    echo "Restoring backup..."
    cp /etc/netplan/backup-*.yaml $NETPLAN_FILE
    exit 1
fi

echo
echo "Applying network configuration..."
netplan apply

sleep 3

# Test connectivity
echo
echo "Testing connectivity..."
echo

echo "[1/3] Testing gateway..."
if ping -c 2 -W 2 $GATEWAY >/dev/null 2>&1; then
    echo "✓ Gateway ($GATEWAY) is reachable"
else
    echo "✗ Gateway ($GATEWAY) is NOT reachable"
fi

echo
echo "[2/3] Testing LDAP server (192.168.1.15)..."
if ping -c 2 -W 2 192.168.1.15 >/dev/null 2>&1; then
    echo "✓ LDAP server (192.168.1.15) is reachable"
else
    echo "✗ LDAP server (192.168.1.15) is NOT reachable"
    echo "  Check your network configuration and LDAP server"
fi

echo
echo "[3/3] Testing LDAP port 389..."
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/192.168.1.15/389" 2>/dev/null; then
    echo "✓ LDAP port 389 is accessible"
else
    echo "✗ LDAP port 389 is NOT accessible"
    echo "  Check firewall on LDAP server"
fi

echo
echo "=========================================="
echo "Network Configuration Complete"
echo "=========================================="
echo
echo "Current IP: $STATIC_IP"
echo "You can now access LibreNMS at: http://$STATIC_IP"
echo
echo "Next steps:"
echo "1. Open browser to: http://$STATIC_IP"
echo "2. Complete web installation wizard"
echo "3. Login with LDAP credentials"
echo
echo "If you need to test LDAP manually:"
echo "  ldapsearch -x -H ldap://192.168.1.15:389 -D \"cn=admin,dc=example,dc=com\" -w \"password\" -b \"dc=example,dc=com\""
echo