#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Сканер SNI-target для Reality
# Сканирует подсеть VPS и находит домены с TLS 1.3 + H2
# Запуск на VPS: bash scan-sni.sh
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com)
SUBNET=$(echo "$SERVER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')

log "Твой IP: ${SERVER_IP}"
log "Подсеть: ${SUBNET}"
echo ""

# --- Установка RealiTLScanner ---

SCANNER="./RealiTLScanner"

if [[ ! -f "$SCANNER" ]]; then
    log "Скачиваю RealiTLScanner..."

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_NAME="64" ;;
        aarch64) ARCH_NAME="arm64-v8a" ;;
        *)       echo "Неизвестная архитектура: $ARCH"; exit 1 ;;
    esac

    LATEST=$(curl -s https://api.github.com/repos/XTLS/RealiTLScanner/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
    URL="https://github.com/XTLS/RealiTLScanner/releases/download/${LATEST}/RealiTLScanner-linux-${ARCH_NAME}"

    curl -sL -o "$SCANNER" "$URL"
    chmod +x "$SCANNER"
    log "RealiTLScanner ${LATEST} установлен"
fi

# --- Сканирование ---

OUTPUT="sni_results.txt"

log "Сканирую ${SUBNET} (это займёт 1-3 минуты)..."
echo ""

$SCANNER -addr "$SUBNET" -thread 50 -timeout 5 -out "$OUTPUT" 2>/dev/null

echo ""
log "Результаты сохранены в ${OUTPUT}"
echo ""

# --- Фильтрация лучших кандидатов ---

if [[ -f "$OUTPUT" ]]; then
    log "Домены с TLS 1.3 в твоей подсети (все результаты = TLS 1.3 + H2):"
    echo "---"
    # CSV: IP,ORIGIN,CERT_DOMAIN,CERT_ISSUER,GEO_CODE
    # Убираем заголовок, wildcard-домены, IP-only и фейковые сертификаты
    tail -n +2 "$OUTPUT" 2>/dev/null \
        | awk -F',' '{print $3}' \
        | grep -v '^\*\.' \
        | grep -v '^[0-9]' \
        | grep -vi 'fake\|kubernetes\|ingress' \
        | sort -u \
        | head -20 || true
    echo "---"
    echo ""
    warn "Выбери домен из списка и проверь его:"
    echo "  bash find-sni.sh <домен>"
    echo ""
    warn "Хороший кандидат: не-российский, с реальным контентом, TLS 1.3, H2"
else
    warn "Файл результатов не создан. Попробуй запустить вручную:"
    echo "  $SCANNER -addr $SUBNET -thread 50 -timeout 5"
fi
