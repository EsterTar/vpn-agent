#!/usr/bin/env bash
# =============================================================================
# Помощник для выбора SNI-target
# Показывает ASN сервера и проверяет кандидатов на совместимость с Reality
# Запуск: bash find-sni.sh [домен-кандидат]
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com)
echo -e "${GREEN}Твой IP:${NC} ${SERVER_IP}"

# ASN сервера
SERVER_ASN=$(whois "$SERVER_IP" 2>/dev/null | grep -i -m1 'origin' | awk '{print $NF}')
echo -e "${GREEN}Твой ASN:${NC} ${SERVER_ASN:-не определён}"
echo ""

check_candidate() {
    local domain=$1
    echo -e "${YELLOW}Проверяю: ${domain}${NC}"

    # Резолвим IP
    local ip
    ip=$(dig +short "$domain" A 2>/dev/null | head -1)
    if [[ -z "$ip" ]]; then
        echo -e "  ${RED}✗${NC} Не удалось резолвить домен"
        return
    fi
    echo -e "  IP: ${ip}"

    # ASN кандидата
    local asn
    asn=$(whois "$ip" 2>/dev/null | grep -i -m1 'origin' | awk '{print $NF}')
    echo -e "  ASN: ${asn:-не определён}"

    if [[ "$asn" == "$SERVER_ASN" ]]; then
        echo -e "  ${GREEN}✓ Тот же ASN — хороший кандидат!${NC}"
    else
        echo -e "  ${RED}✗ Другой ASN — ТСПУ может заметить несоответствие${NC}"
    fi

    # Проверяем TLS 1.3 и H2
    local tls_info
    tls_info=$(echo | openssl s_client -connect "${domain}:443" -alpn h2 -tls1_3 2>/dev/null | head -20)

    if echo "$tls_info" | grep -q "TLSv1.3"; then
        echo -e "  ${GREEN}✓ TLS 1.3 поддерживается${NC}"
    else
        echo -e "  ${RED}✗ TLS 1.3 НЕ поддерживается${NC}"
    fi

    if echo "$tls_info" | grep -q "ALPN.*h2"; then
        echo -e "  ${GREEN}✓ HTTP/2 поддерживается${NC}"
    else
        echo -e "  ${YELLOW}? HTTP/2 не подтверждён${NC}"
    fi

    echo ""
}

if [[ $# -gt 0 ]]; then
    for domain in "$@"; do
        check_candidate "$domain"
    done
else
    echo "Использование:"
    echo "  bash find-sni.sh example.com another-site.com"
    echo ""
    echo "Как найти кандидатов в своём ASN (${SERVER_ASN:-???}):"
    echo "  Загугли: \"sites hosted on ${SERVER_ASN:-AS????}\" или используй bgp.tools"
fi
