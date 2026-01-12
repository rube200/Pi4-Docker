#!/bin/bash
set -euo pipefail

readonly HOSTINGER_API_BASE="https://api.hostinger.com"

if [[ -z "${DNS_API:-}" ]]; then
    echo "Error: DNS_API environment variable required"
    exit 1
fi

if [[ -z "${SERVER_HOSTNAME:-}" ]]; then
    echo "Error: SERVER_HOSTNAME environment variable required"
    exit 1
fi

echo "Getting public IP..."
public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
            curl -s --max-time 5 https://icanhazip.com 2>/dev/null || \
            curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null)

if [[ ! "$public_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Failed to get public IP"
    exit 1
fi

echo "Fetching DNS records..."
records_response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${DNS_API}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${HOSTINGER_API_BASE}/api/dns/v1/zones/${SERVER_HOSTNAME}")

http_code=$(echo "$records_response" | tail -n1)
records_body=$(echo "$records_response" | sed '$d')

if [[ "$http_code" != "200" ]]; then
    echo "Failed to fetch DNS records. HTTP $http_code"
    exit 1
fi

temp_file=$(mktemp)
trap "rm -f '$temp_file'" EXIT
echo "$records_body" > "$temp_file"

record_ids=($(grep -o "\"id\"[[:space:]]*:[[:space:]]*[0-9]*" "$temp_file" | grep -o "[0-9]*" | sort -u))

record_id=""
current_ip=""

for rid in "${record_ids[@]}"; do
    record_block=$(grep -A 10 "\"id\"[[:space:]]*:[[:space:]]*${rid}" "$temp_file" | head -n 10)

    if echo "$record_block" | grep -q "\"type\"[[:space:]]*:[[:space:]]*\"A\"" && \
       echo "$record_block" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"\@\""; then
        current_ip=$(echo "$record_block" | grep "\"value\"[[:space:]]*:" | \
            sed 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        record_id="$rid"
        break
    fi
done

rm -f "$temp_file"
trap - EXIT

if [[ -n "$record_id" ]] && [[ -n "$current_ip" ]]; then
    if [[ "$current_ip" != "$public_ip" ]]; then
        echo "Updating A record: ${current_ip} -> ${public_ip}"
        json_payload="{\"type\":\"A\",\"name\":\"\@\",\"value\":\"${public_ip}\",\"ttl\":3600}"

        update_response=$(curl -s -w "\n%{http_code}" \
            -X PUT \
            -H "Authorization: Bearer ${DNS_API}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$json_payload" \
            "${HOSTINGER_API_BASE}/api/dns/v1/zones/${SERVER_HOSTNAME}/records/${record_id}")

        http_code=$(echo "$update_response" | tail -n1)

        if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
            echo "Failed to update A record. HTTP $http_code"
            exit 1
        fi
        echo "A record updated successfully"
    else
        echo "A record is up to date (${current_ip})"
    fi
else
    json_payload="{\"type\":\"A\",\"name\":\"\@\",\"value\":\"${public_ip}\",\"ttl\":3600}"
    create_response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${DNS_API}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$json_payload" \
        "${HOSTINGER_API_BASE}/api/dns/v1/zones/${SERVER_HOSTNAME}/records")

    http_code=$(echo "$create_response" | tail -n1)
    if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
        echo "Failed to create A record. HTTP $http_code"
        exit 1
    fi

    echo "A record created successfully"
fi