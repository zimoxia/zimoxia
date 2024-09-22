#!/bin/sh

if [ $# -ne 1 ]; then
    echo "Usage: sh ./extract_dkim.sh <domain>"
    exit 1
fi

domain=$1
dkim_file="/etc/pmta/$domain-dkim.txt"

if [ ! -f "$dkim_file" ]; then
    echo "DKIM file for domain $domain not found!"
    exit 1
fi

dkim_value=$(grep -oP '(?<=p=)[^"]+' $dkim_file)

if [ -n "$dkim_value" ]; then
    echo "v=DKIM1; k=rsa;p=$dkim_value"
else
    echo "No valid DKIM record found in $dkim_file"
fi

