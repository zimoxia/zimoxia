#!/bin/sh
# Check input parameters
if [ $# -ne 4 ]; then
    echo "Usage: sh ./install.sh <domain> <ip> <email_prefix> <email_password>"
    exit 1
fi

# Get parameters
domain=$1
ip=$2
email_prefix=$3
email_password=$4
dkim_selector="default"

# Update the config file
config_file="./conf/config"

if [ ! -f "$config_file" ]; then
    echo "Config file not found!"
    exit 1
fi

# Replace domain, IP, email prefix, and password in the config file
sed -i "s/domain.com/$domain/g" $config_file
sed -i "s/192.168.1.13/$ip/g" $config_file
sed -i "s/admin/$email_prefix/g" $config_file
sed -i "s/vip250/$email_password/g" $config_file

echo "Config file updated with domain: $domain, IP: $ip, email prefix: $email_prefix, and email password."

# Install OpenDKIM
yum -y install opendkim

# Create DKIM keys
dkim_dir="/etc/pmta"
dkim_key_file="$dkim_dir/$domain-dkim.key"

if [ ! -d "$dkim_dir" ]; then
    mkdir -p $dkim_dir
fi

# Generate DKIM private and public keys using opendkim
opendkim-genkey -s $dkim_selector -d $domain
mv $dkim_selector.private $dkim_key_file
mv $dkim_selector.txt $dkim_dir/$domain-dkim.txt

echo "DKIM keys generated and stored in $dkim_key_file"

# Install dependencies
yum -y install httpd php mysql mysql-server php-mysql php-gd php-imap unzip

# Install PowerMTA
curl_dir=$(pwd)

cd $curl_dir
unzip pmta5.0r3.zip
cd pmta5.0r3
rpm -ivh PowerMTA-5.0r3.rpm

# Stop PMTA services
sleep 3s
service pmta stop
service pmtahttp stop

# Copy binaries and config files
\cp usr/sbin/pmtad /usr/sbin/pmtad
\cp usr/sbin/pmtahttpd /usr/sbin/pmtahttpd
\cp -rf license /etc/pmta/license
\cp $curl_dir/conf/config /etc/pmta/

# Set permissions and restart PMTA services
chown pmta:pmta /etc/pmta/ -R
service pmta restart
service pmtahttp restart

# Stop and disable iptables
service iptables stop
chkconfig iptables off

echo "PowerMTA installation and configuration complete."

# Extract and print DKIM public key for DNS configuration
dkim_public_key=$(cat $dkim_dir/$domain-dkim.txt)
echo "DKIM public key for DNS configuration:"
echo "$dkim_public_key"

