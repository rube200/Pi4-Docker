#!/bin/bash
set -e

readonly HOSTINGER_API_BASE="https://developers.hostinger.com"
readonly ACME_CHALLENGE_NAME="_acme-challenge"

if [[ -z "${DNS_API:-}" ]]; then
    echo "DNS_API not set, skipping Hostinger DNS challenge" >&2
    exit 0
fi

if [[ -z "${CERTBOT_DOMAIN:-}" ]] || [[ -z "${CERTBOT_VALIDATION:-}" ]]; then
    echo "Error: CERTBOT_DOMAIN and CERTBOT_VALIDATION must be set" >&2
    exit 1
fi

domain="${CERTBOT_DOMAIN}"
validation="${CERTBOT_VALIDATION}"

if [[ "$domain" =~ ^\*\. ]]; then
    domain="${domain#*.}"
fi

flag_file="/tmp/certbot-${validation}.flag"
if [[ -f "$flag_file" ]]; then
    rm -f "$flag_file"

    echo "Deleting TXT record for ${ACME_CHALLENGE_NAME}.${domain}..."
    records_response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${DNS_API}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        "${HOSTINGER_API_BASE}/api/dns/v1/zones/${domain}")

    http_code=$(echo "$records_response" | tail -n1)
    records_body=$(echo "$records_response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        temp_file=$(mktemp)
        trap "rm -f '$temp_file'" EXIT
        echo "$records_body" > "$temp_file"
        record_ids=($(grep -o "\"id\"[[:space:]]*:[[:space:]]*[0-9]*" "$temp_file" | grep -o "[0-9]*" | sort -u))

        for rid in "${record_ids[@]}"; do
            record_block=$(grep -A 10 "\"id\"[[:space:]]*:[[:space:]]*${rid}" "$temp_file" | head -n 10)
            if echo "$record_block" | grep -q "\"type\"[[:space:]]*:[[:space:]]*\"TXT\"" && \
               echo "$record_block" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${ACME_CHALLENGE_NAME}\"" && \
               echo "$record_block" | grep -q "\"value\"[[:space:]]*:[[:space:]]*\"${validation}\""; then
                delete_response=$(curl -s -w "\n%{http_code}" \
                    -X DELETE \
                    -H "Authorization: Bearer ${DNS_API}" \
                    -H "Content-Type: application/json" \
                    "${HOSTINGER_API_BASE}/api/dns/v1/zones/${domain}/records/${rid}")
                delete_http_code=$(echo "$delete_response" | tail -n1)
                if [[ "$delete_http_code" == "200" || "$delete_http_code" == "204" ]]; then
                    echo "TXT record deleted successfully"
                fi
                break
            fi
        done
        rm -f "$temp_file"
        trap - EXIT
    fi
else
    touch "$flag_file"

    echo "Creating TXT record for ${ACME_CHALLENGE_NAME}.${domain}..."
    json_payload="{\"type\":\"TXT\",\"name\":\"${ACME_CHALLENGE_NAME}\",\"value\":\"${validation}\",\"ttl\":3600}"
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${DNS_API}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$json_payload" \
        "${HOSTINGER_API_BASE}/api/dns/v1/zones/${domain}/records")

    http_code=$(echo "$response" | tail -n1)
    if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
        rm -f "$flag_file"
        echo "Error: Failed to create TXT record. HTTP $http_code" >&2
        exit 1
    fi

    echo "TXT record created successfully"
    sleep 10
fi
