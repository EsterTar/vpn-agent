#!/usr/bin/env bash
# =============================================================================
# Помощник для выбора SNI-target
# Показывает ASN/org сервера и проверяет кандидатов на совместимость с Reality
# Запуск: bash find-sni.sh [домен-кандидат]
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

get_org() {
    local ip=$1
    curl -s --max-time 3 "https://ipinfo.io/${ip}/org" 2>/dev/null || true
}

SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com)
SERVER_ORG=$(get_org "$SERVER_IP")
echo -e "${GREEN}Твой IP:${NC} ${SERVER_IP}"
echo -e "${GREEN}Твой провайдер:${NC} ${SERVER_ORG:-не определён}"
echo ""

check_candidate() {
    local domain=$1
    echo -e "${YELLOW}Проверяю: ${domain}${NC}"

    local ip
    ip=$(dig +short "$domain" A 2>/dev/null | head -1)
    if [[ -z "$ip" ]]; then
        echo -e "  ${RED}✗${NC} Не удалось резолвить домен"
        return
    fi
    echo -e "  IP: ${ip}"

    local org
    org=$(get_org "$ip")
    echo -e "  Провайдер: ${org:-не определён}"

    if [[ -z "$org" || -z "$SERVER_ORG" ]]; then
        echo -e "  ${YELLOW}? Провайдер не определён — проверь вручную${NC}"
    else
        # Извлекаем номер ASN для точного сравнения, затем сравниваем имя org
        local server_asn candidate_asn server_name candidate_name
        server_asn=$(echo "$SERVER_ORG" | awk '{print $1}')
        candidate_asn=$(echo "$org" | awk '{print $1}')
        server_name=$(echo "$SERVER_ORG" | cut -d' ' -f2- | tr '[:upper:]' '[:lower:]')
        candidate_name=$(echo "$org" | cut -d' ' -f2- | tr '[:upper:]' '[:lower:]')

        if [[ "$server_asn" == "$candidate_asn" ]]; then
            echo -e "  ${GREEN}✓ Тот же ASN (${server_asn}) — отличный кандидат!${NC}"
        elif echo "$server_name $candidate_name" | grep -qiE "yandex|sber|vk |mail\.ru|mts|beeline|megafon|rostelecom"; then
            # Проверяем совпадение по имени организации (один холдинг)
            local server_brand candidate_brand
            server_brand=$(echo "$server_name" | grep -ioE "yandex|sber|vk|mail\.ru|mts|beeline|megafon|rostelecom" | head -1)
            candidate_brand=$(echo "$candidate_name" | grep -ioE "yandex|sber|vk|mail\.ru|mts|beeline|megafon|rostelecom" | head -1)
            if [[ -n "$server_brand" && "$server_brand" == "$candidate_brand" ]]; then
                echo -e "  ${GREEN}✓ Тот же холдинг (${server_asn} / ${candidate_asn}, оба ${server_brand}) — хороший кандидат${NC}"
            else
                echo -e "  ${RED}✗ Другой провайдер (${server_asn} vs ${candidate_asn}) — ТСПУ может заметить несоответствие${NC}"
            fi
        else
            echo -e "  ${RED}✗ Другой провайдер (${server_asn} vs ${candidate_asn}) — ТСПУ может заметить несоответствие${NC}"
        fi
    fi

    local tls_info
    tls_info=$(echo | openssl s_client -connect "${domain}:443" -alpn h2 2>&1)

    if echo "$tls_info" | grep -q "TLSv1.3"; then
        echo -e "  ${GREEN}✓ TLS 1.3 поддерживается${NC}"
    elif echo "$tls_info" | grep -qE "connect:|errno|refused|timeout|handshake"; then
        echo -e "  ${RED}✗ Соединение не установлено${NC}"
        echo -e "  $(echo "$tls_info" | grep -E 'connect:|errno|error' | head -1)"
    else
        echo -e "  ${RED}✗ TLS 1.3 НЕ поддерживается (согласовано: $(echo "$tls_info" | grep -oE 'TLSv[0-9.]+' | head -1))${NC}"
    fi

    if echo "$tls_info" | grep -q "ALPN.*h2\|alpn.*h2"; then
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
    echo "Как найти кандидатов в своём ASN (${SERVER_ORG:-???}):"
    echo "  Загугли: \"sites hosted on $(echo "${SERVER_ORG}" | awk '{print $1}')\" или используй bgp.tools"
fi
