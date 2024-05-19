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

cert_dir="/etc/letsencrypt/live/"

# Log file path
LOG_FILE="/var/log/certbot_script.log"

# Check if the log file exists, and create it if it doesn't
if [ ! -e "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  if [ $? -ne 0 ]; then
    echo "Failed to create log file: $LOG_FILE" >&2
    exit 1
  fi
fi

# Redirect stdout and stderr to the log file with date and time
exec > >(while IFS= read -r line; do echo "$(date '+%Y-%m-%d %H:%M:%S') $line"; done >> "$LOG_FILE") 2>&1

# Variable to track whether certificates were created or renewed
certificates_updated=false

# Function to log messages with date and time
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Function to reload HAProxy
reload_haproxy() {
  systemctl reload haproxy
  if systemctl is-active --quiet haproxy; then
    log "Service haproxy is running."
  else
    log "Service haproxy is not running."
  fi
}

# Function to copy certificates for a domain
copy_certificate() {
  local domain_to_copy=$1
  cat "$cert_dir$domain_to_copy/fullchain.pem" "$cert_dir$domain_to_copy/privkey.pem" > "/etc/haproxy/certs/$domain_to_copy.pem"
  if [ $? -eq 0 ]; then
    log "Certificate for $domain_to_copy copied successfully."
  else
    log "Failed to copy certificate for $domain_to_copy."
  fi
}

# Function to deploy certificates (copy and reload HAProxy)
deploy_certificate() {
  local domain_to_deploy=$1
  copy_certificate "$domain_to_deploy"
  reload_haproxy
}

# Placeholder for renewing certificates function
renew_certificate() {
  local domain_to_renew=$1
  # Example command; replace with actual renew command
  certbot renew --cert-name "$domain_to_renew" --quiet --deploy-hook "$0 -d copy -e $email"
  if [ $? -eq 0 ]; then
    certificates_updated=true
    log "Certificate renewed for domain: $domain_to_renew."
  else
    log "Failed to renew certificate for domain: $domain_to_renew."
  fi
}

# Check if a renewal or copy is requested
if [ "$domain" = "renew" ]; then
  # Renew all certificates
  for domain_dir in $cert_dir*; do
    if [ -d "$domain_dir" ]; then
      domain_to_renew=$(basename "$domain_dir")
      cert_expiration_date=$(certbot certificates | grep -A 4 "Certificate Name: $domain_to_renew" | grep "Expiry Date" | awk '{print $3}')
      cert_expiration_unix=$(date -d "$cert_expiration_date" +%s)
      current_unix=$(date +%s)
      threshold=$((30 * 24 * 60 * 60))  # 30 days in seconds
      # Check if the certificate needs renewal
      if [ $((cert_expiration_unix - current_unix)) -lt $threshold ]; then
        log "Certificate for $domain_to_renew needs renewal."
        renew_certificate "$domain_to_renew"
      else
        log "Certificate for $domain_to_renew is still valid. No renewal needed."
      fi
    fi
  done
elif [ "$domain" = "copy" ]; then
  # Copy certificates for HAProxy
  for domain_dir in $cert_dir*; do
    if [ -d "$domain_dir" ]; then
      domain_to_copy=$(basename "$domain_dir")
      deploy_certificate "$domain_to_copy"
    fi
  done
else
  # Create or renew the certificate for the specified domain
  certbot certonly \
    -n \
    --cert-name "$domain" \
    --agree-tos \
    --dns-cloudflare \
    -m "$email" \
    --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    -d "$domain" -d "*.$domain" \
    --deploy-hook "$0 -d copy -e $email"
  if [ $? -eq 0 ]; then
    certificates_updated=true
    log "Certificate creation/renewal successful for domain: $domain."
    # Add or update the cron job for certificate renewal only once
    if ! crontab -l 2>/dev/null | grep -F -q "$0 -d renew -e $email"; then
      CRON_CMD="0 0 * * * $0 -d renew -e $email"
      (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    fi
  else
    log "Failed to create/renew certificate for domain: $domain."
  fi
fi

# Reload HAProxy if certificates were created or renewed
if [ "$certificates_updated" = true ]; then
  reload_haproxy
fi

log "SSL certificate setup and renewal handling completed."
