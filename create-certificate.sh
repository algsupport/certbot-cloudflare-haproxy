#!/bin/bash

# Initialize variables to hold option values
domain=
email=

while getopts "d:e:" opt; do
  case $opt in
    d)
      domain="$OPTARG"
      ;;
    e)
      email="$OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

# Check for required options
if [ -z "$domain" ] || [ -z "$email" ]; then
  echo "Both -d and -e options are required."
  exit 1
fi

cert_dir="/etc/letsencrypt/live/$domain"

# Log file path
LOG_FILE="/var/log/certbot_script.log"

# Check if the log file exists, and create it if it doesn't
if [ ! -e "$LOG_FILE" ]; then
  touch "$LOG_FILE"
fi

# Redirect stdout and stderr to the log file
exec >> "$LOG_FILE" 2>&1

# Variable to track whether certificates were created or renewed
certificates_updated=false

# Check if a renewal is requested
if [ "$domain" = "renew" ]; then
  # Renew all certificates
  for domain_dir in /etc/letsencrypt/live/*; do
    if [ -d "$domain_dir" ]; then
      domain_to_renew=$(basename "$domain_dir")
      cert_expiration_date=$(certbot certificates | grep -A 4 "Certificate Name: $domain_to_renew" | grep "Expiry Date" | awk '{print $3}')
      cert_expiration_unix=$(date -d "$cert_expiration_date" +%s)
      current_unix=$(date +%s)
      threshold=$((30 * 24 * 60 * 60))  # 30 days in seconds
      # Check if the certificate needs renewal
      if [ $((cert_expiration_unix - current_unix)) -lt $threshold ]; then
        echo "Certificate for $domain_to_renew needs renewal."
        certbot renew \
          --cert-name domain_to_renew \
          --quiet \
          --deploy-hook "cat '$cert_dir/fullchain.pem' '$cert_dir/privkey.pem' > '/etc/haproxy/certs/$domain_to_renew.pem' && systemctl reload haproxy";
        certificates_updated=true
      else
        echo "Certificate for $domain_to_renew is still valid. No renewal needed."
      fi
    fi
  done
else
  # Create or renew the certificate for the specified domain
  certbot certonly \
    -n \
    --cert-name $domain \
    --agree-tos \
    --dns-cloudflare \
    -m $email \
    --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    -d "$domain, *.$domain" \
    --deploy-hook "cat '$cert_dir/fullchain.pem' '$cert_dir/privkey.pem' > '/etc/haproxy/certs/$domain.pem' && systemctl reload haproxy";
  certificates_updated=true
  echo "Certificate creation/renewal successful for domain: $domain."
  # Add or update the cron job for certificate renewal only once
  if ! crontab -l | grep -q "$0 -d renew -e $email"; then
    CRON_CMD="0 0 * * * $0 -d renew -e $email"
    (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
  fi
fi

# Reload HAProxy if certificates were created or renewed
if [ "$certificates_updated" = true ]; then
  systemctl reload haproxy
  if systemctl is-active --quiet haproxy; then
    echo "Service haproxy is running."
  else
    echo "Service haproxy is not running."
  fi
fi

echo "SSL certificate setup and renewal handling completed."
