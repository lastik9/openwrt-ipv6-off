#!/bin/ash
# install.sh — установщик ipv6-off для OpenWrt
# Скачивает ipv6-off.sh, показывает краткую сводку (версия / размер / sha256 /
# что делает) вместо "простыни" кода, по желанию открывает исходник в пейджере,
# затем ставит и (опц.) запускает.
#
# Использование:
#   sh install.sh                # интерактивно
#   sh install.sh --yes          # без вопросов
#   sh install.sh --yes --run    # поставить и сразу запустить менеджер
#   sh install.sh --dest=/usr/bin/ipv6-off
set -u

RAW_URL="https://raw.githubusercontent.com/lastik9/openwrt-ipv6-off/main/ipv6-off.sh"
DEST="/root/ipv6-off.sh"
ASSUME_YES="0"
DO_RUN="0"

for a in "$@"; do
  case "$a" in
    --yes|-y)     ASSUME_YES="1" ;;
    --run)        DO_RUN="1" ;;
    --dest=*)     DEST="${a#--dest=}" ;;
    --url=*)      RAW_URL="${a#--url=}" ;;
    --help|-h)
      echo "install.sh — установщик ipv6-off"
      echo "  --yes         ставить без вопросов"
      echo "  --run         запустить менеджер после установки"
      echo "  --dest=PATH   куда положить (по умолчанию $DEST)"
      exit 0 ;;
  esac
done

if [ -t 1 ]; then
  RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"; YEL="$(printf '\033[33m')"
  BLU="$(printf '\033[34m')"; CYN="$(printf '\033[36m')"; GRY="$(printf '\033[90m')"
  BLD="$(printf '\033[1m')"; RST="$(printf '\033[0m')"
else
  RED=""; GRN=""; YEL=""; BLU=""; CYN=""; GRY=""; BLD=""; RST=""
fi

ok(){   printf "%s✅ %s%s\n" "$GRN" "$*" "$RST"; }
warn(){ printf "%s⚠️  %s%s\n" "$YEL" "$*" "$RST"; }
err(){  printf "%s❌ %s%s\n" "$RED" "$*" "$RST"; }
dim(){  printf "%s%s%s\n" "$GRY" "$*" "$RST"; }
rule(){ printf "%s══════════════════════════════════════════════%s\n" "$BLU" "$RST"; }

# Читает строку и срезает возможный \r (CRLF из некоторых SSH-клиентов/буфера)
read_line(){
  IFS= read -r __rl || true
  printf '%s' "$__rl" | tr -d '\r'
}

banner(){
  printf "\n"
  rule
  printf "  %s🚫 ipv6-off%s — установщик для OpenWrt\n" "$BLD" "$RST"
  dim   "  безопасное отключение IPv6: бэкап + автооткат по IPv4"
  rule
  printf "\n"
}

# Загрузка: uclient-fetch (умеет HTTPS на OpenWrt) → wget → curl
fetch(){
  url="$1"; out="$2"
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -qO "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
  fi
  return 1
}

view_code(){
  f="$1"
  if command -v less >/dev/null 2>&1; then less "$f"
  elif command -v more >/dev/null 2>&1; then more "$f"
  else cat "$f"; fi
}

do_install(){
  src="$1"
  mkdir -p "$(dirname "$DEST")" 2>/dev/null || true
  cp "$src" "$DEST" || { err "Не удалось записать $DEST"; return 1; }
  chmod +x "$DEST" 2>/dev/null || true
  return 0
}

main(){
  banner

  tmp="/tmp/ipv6-off.dl.$$"
  printf "Скачиваю %sipv6-off.sh%s...\n" "$CYN" "$RST"
  if ! fetch "$RAW_URL" "$tmp"; then
    err "Не удалось скачать скрипт."
    dim "Проверьте интернет и SSL. Если wget из BusyBox без SSL —"
    dim "поставьте wget-ssl/ca-bundle или используйте uclient-fetch."
    rm -f "$tmp" 2>/dev/null
    exit 1
  fi

  ver="$(grep -m1 '^VERSION=' "$tmp" 2>/dev/null | cut -d'"' -f2)"
  size="$(wc -c < "$tmp" 2>/dev/null)"
  lines="$(wc -l < "$tmp" 2>/dev/null)"
  sha="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')"

  # Краткая сводка вместо вывода всего кода
  printf "\n"
  ok "Скрипт получен"
  printf "  %sВерсия:%s   %s\n" "$BLD" "$RST" "${ver:-?}"
  printf "  %sРазмер:%s   %s байт, %s строк\n" "$BLD" "$RST" "${size:-?}" "${lines:-?}"
  printf "  %sSHA256:%s   %s\n" "$BLD" "$RST" "${sha:-?}"
  printf "  %sКуда:%s     %s\n" "$BLD" "$RST" "$DEST"
  printf "\n"
  dim "Что делает: бэкап текущих настроек → отключение IPv6"
  dim "(network/dhcp/firewall/odhcpd) → watchdog-откат по IPv4."
  dim "Ничего необратимого: восстановление из меню или --restore-last."
  printf "\n"

  # Неинтерактивно
  if [ "$ASSUME_YES" = "1" ]; then
    if do_install "$tmp"; then ok "Установлено: $DEST"; else rm -f "$tmp"; exit 1; fi
    rm -f "$tmp" 2>/dev/null
    if [ "$DO_RUN" = "1" ]; then printf "\n"; exec sh "$DEST"; fi
    printf "\nЗапуск: %ssh %s%s\n" "$CYN" "$DEST" "$RST"
    exit 0
  fi

  # Интерактивное меню — код показываем ТОЛЬКО по запросу, в пейджере
  while :; do
    printf "%s1)%s Установить   %s2)%s Показать код   %s3)%s Отмена\n" \
      "$GRN" "$RST" "$CYN" "$RST" "$RED" "$RST"
    printf "Ваш выбор [1-3]: "
    ans="$(read_line)"
    case "${ans:-}" in
      1)
        if do_install "$tmp"; then ok "Установлено: $DEST"; else rm -f "$tmp"; exit 1; fi
        rm -f "$tmp" 2>/dev/null
        printf "\n"
        printf "Запустить менеджер сейчас? [1 - да / Enter - нет]: "
        r="$(read_line)"
        case "${r:-}" in
          1|y|Y) exec sh "$DEST" ;;
          *) dim "Позже: sh $DEST" ; exit 0 ;;
        esac
        ;;
      2)
        view_code "$tmp"
        printf "\n"
        ;;
      3)
        dim "Отмена. Ничего не установлено."
        rm -f "$tmp" 2>/dev/null
        exit 0
        ;;
      "")
        dim "Ничего не выбрано — введите 1 (установить), 2 (код) или 3 (отмена)."
        ;;
      *)
        warn "Не понял. Введите 1, 2 или 3."
        ;;
    esac
  done
}

main "$@"
