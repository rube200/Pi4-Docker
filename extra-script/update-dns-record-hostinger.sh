#!/bin/bash
set -euo pipefail

readonly HOSTINGER_API_BASE="https://developers.hostinger.com"

if [[ -z "${DNS_API:-}" ]]; then
    echo "DNS_API not set, skipping Hostinger DNS record update"
    exit 0
fi

if [[ -z "${SERVER_HOSTNAME}" ]]; then
    echo "Error: SERVER_HOSTNAME environment variable required"
    exit 1
fi

echo "Getting public IP..."
public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
            curl -s --max-time 5 https://icanhazip.com 2>/dev/null || \
            curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null)

if [[ ! "$public_ip" =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]; then
    echo "Error: Failed to get public IP"
    exit 1
fi

echo "Fetching DNS records..."
records_response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${DNS_API}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${HOSTINGER_API_BASE}/api/dns/v1/zones/${SERVER_HOSTNAME}" 2>&1) || true

http_code=$(echo "$records_response" | tail -n1)
records_body=$(echo "$records_response" | sed '$d')

if [[ "$http_code" != "200" ]]; then
    echo "Error: Failed to fetch DNS records. HTTP $http_code"
    echo "Response: ${records_body}"
    exit 1
fi

current_ip=""
records_list=$(echo "$records_body" | sed 's/^\[//;s/\]$//' | sed 's/},{/}\n{/g' 2>/dev/null || echo "$records_body")

for name in "@" "*"; do
    while IFS= read -r record_obj; do
        if echo "$record_obj" | grep -q '"type":"A"' && \
           echo "$record_obj" | grep -q "\"name\":\"${name}\""; then
            ip_candidate=$(echo "$record_obj" | grep -o '"content":"[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"' | \
                          head -1 | sed 's/"content":"\([^"]*\)"/\1/')
            if [[ -n "$ip_candidate" ]] && [[ "$ip_candidate" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                current_ip="$ip_candidate"
                break 2
            fi
        fi
    done <<< "$records_list"
done

if [[ -n "$current_ip" ]]; then
    if [[ "$current_ip" != "$public_ip" ]]; then
        echo "Updating A record: ${current_ip} -> ${public_ip}"
        json_payload="{\"overwrite\":true,\"zone\":[{\"name\":\"@\",\"records\":[{\"content\":\"${public_ip}\"}],\"ttl\":3600,\"type\":\"A\"},{\"name\":\"*\",\"records\":[{\"content\":\"${public_ip}\"}],\"ttl\":3600,\"type\":\"A\"}]}"
        response=$(curl -s -w "\n%{http_code}" \
            -X PUT \
            -H "Authorization: Bearer ${DNS_API}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$json_payload" \
            "${HOSTINGER_API_BASE}/api/dns/v1/zones/${SERVER_HOSTNAME}" 2>&1) || true
        http_code=$(echo "$response" | tail -n1)
        if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
            echo "Error: Failed to update A record. HTTP $http_code"
            echo "$response" | sed '$d'
            exit 1
        fi
        echo "A record updated successfully"
    else
        echo "A record is up to date (${current_ip})"
    fi
else
    echo "Creating A record..."
    json_payload="{\"overwrite\":true,\"zone\":[{\"name\":\"@\",\"records\":[{\"content\":\"${public_ip}\"}],\"ttl\":3600,\"type\":\"A\"},{\"name\":\"*\",\"records\":[{\"content\":\"${public_ip}\"}],\"ttl\":3600,\"type\":\"A\"}]}"
    response=$(curl -s -w "\n%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer ${DNS_API}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$json_payload" \
        "${HOSTINGER_API_BASE}/api/dns/v1/zones/${SERVER_HOSTNAME}" 2>&1) || true
    http_code=$(echo "$response" | tail -n1)
    if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
        echo "Error: Failed to create A record. HTTP $http_code"
        echo "$response" | sed '$d'
        exit 1
    fi
    echo "A record created successfully"
fi
