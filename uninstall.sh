#!/bin/sh
# openwrt-ipv6-off — uninstaller
# Снимает watchdog, удаляет менеджер отключения IPv6 и (опционально) его данные.
# Чистый ash/BusyBox, без зависимостей.
# MIT © 2026 lastik9  —  https://github.com/lastik9/openwrt-ipv6-off

VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Пути (совпадают с тем, что создаёт ipv6-off.sh)
# ---------------------------------------------------------------------------
DEST="/root/ipv6-off.sh"                       # установленный менеджер
DATA_DIR="/root/ipv6-off"                      # лог + backups/ + диагностика
SYSCTL_FILE="/etc/sysctl.d/99-ipv6-off.conf"   # артефакт жёсткого режима
WD_SH="/tmp/ipv6_watchdog.sh"                  # автономный watchdog
WD_PID="/tmp/ipv6_watchdog.pid"
LOCK="/tmp/ipv6-off.lock"

# ---------------------------------------------------------------------------
# Флаги
# ---------------------------------------------------------------------------
ASSUME_YES=0     # --yes        : без вопросов, безопасные значения по умолчанию
DO_PURGE=0       # --purge      : снести и DATA_DIR (бэкапы/лог/диагностика)
FORCE_RESTORE=0  # --restore    : принудительно вернуть IPv6 перед удалением
NO_RESTORE=0     # --no-restore : не возвращать IPv6, даже если он выключен

# ---------------------------------------------------------------------------
# Оформление
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_R="$(printf '\033[31m')"; C_G="$(printf '\033[32m')"
  C_Y="$(printf '\033[33m')"; C_B="$(printf '\033[1m')"; C_0="$(printf '\033[0m')"
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }

usage() {
  cat <<EOF
openwrt-ipv6-off — деинсталлятор v$VERSION

Использование:
  sh uninstall.sh [флаги]

Флаги:
  --yes           не задавать вопросов (безопасные значения по умолчанию:
                  статус IPv6 не трогается, бэкапы сохраняются)
  --restore       перед удалением вернуть IPv6 из последнего бэкапа
  --no-restore    не предлагать возврат IPv6, даже если он выключен
  --purge         удалить и данные ($DATA_DIR: бэкапы, лог, диагностика)
  --dest=ПУТЬ     путь к установленному ipv6-off.sh (по умолчанию $DEST)
  --help          эта справка

Что удаляется всегда: watchdog ($WD_SH), сам менеджер ($DEST),
lock-файл, и sysctl-артефакт жёсткого режима ($SYSCTL_FILE), если он есть.
EOF
}

# ---------------------------------------------------------------------------
# Разбор аргументов
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --yes|-y)      ASSUME_YES=1 ;;
    --purge)       DO_PURGE=1 ;;
    --restore)     FORCE_RESTORE=1 ;;
    --no-restore)  NO_RESTORE=1 ;;
    --dest=*)      DEST="${arg#--dest=}" ;;
    --help|-h)     usage; exit 0 ;;
    *) err "Неизвестный аргумент: $arg"; usage; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Хелперы
# ---------------------------------------------------------------------------
# confirm "вопрос" default(y/n) -> код 0 = да
confirm() {
  _p="$1"; _def="$2"
  if [ "$ASSUME_YES" = 1 ]; then
    [ "$_def" = y ] && return 0 || return 1
  fi
  if [ "$_def" = y ]; then _hint="[1=да / 2=нет, Enter=да]"; else _hint="[1=да / 2=нет, Enter=нет]"; fi
  printf '%s %s ' "$_p" "$_hint"
  read -r _ans
  case "$_ans" in
    1|y|Y|д|Д|да) return 0 ;;
    2|n|N|н|Н|нет) return 1 ;;
    "") [ "$_def" = y ] && return 0 || return 1 ;;
    *) [ "$_def" = y ] && return 0 || return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. Сводка
# ---------------------------------------------------------------------------
say ""
say "${C_B}openwrt-ipv6-off — удаление (v$VERSION)${C_0}"
say "--------------------------------------------------"
say "Будет остановлено/удалено:"
say "  • watchdog:      $WD_SH (+ pid)"
say "  • менеджер:      $DEST"
say "  • lock:          $LOCK"
[ -f "$SYSCTL_FILE" ] && say "  • sysctl (hard): $SYSCTL_FILE"
if [ "$DO_PURGE" = 1 ]; then
  say "  • данные:        $DATA_DIR ${C_R}(бэкапы/лог/диагностика — БУДУТ УДАЛЕНЫ)${C_0}"
else
  say "  • данные:        $DATA_DIR ${C_G}(сохраняются)${C_0}"
fi
say "--------------------------------------------------"

if ! confirm "Продолжить удаление?" y; then
  warn "Отменено пользователем."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Остановить watchdog (он мог бы мешать/перезаписывать конфиги)
# ---------------------------------------------------------------------------
stop_watchdog() {
  _stopped=0
  if [ -f "$WD_PID" ]; then
    _pid="$(cat "$WD_PID" 2>/dev/null)"
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
      kill "$_pid" 2>/dev/null
      sleep 1
      kill -0 "$_pid" 2>/dev/null && kill -9 "$_pid" 2>/dev/null
      _stopped=1
    fi
  fi
  # подстраховка: добить по имени, если pid-файл потерялся.
  # BusyBox не всегда имеет pgrep, поэтому парсим ps (SC2009 намеренно):
  # shellcheck disable=SC2009
  for _p in $(ps 2>/dev/null | grep 'ipv6_watchdog' | grep -v grep | awk '{print $1}'); do
    kill -9 "$_p" 2>/dev/null && _stopped=1
  done
  rm -f "$WD_SH" "$WD_PID"
  if [ "$_stopped" = 1 ]; then ok "Watchdog остановлен."; else ok "Watchdog не запущен (нечего останавливать)."; fi
}
stop_watchdog

# ---------------------------------------------------------------------------
# 3. Статус IPv6 и предложение вернуть его перед удалением
# ---------------------------------------------------------------------------
ipv6_is_off() {
  # ipv6-off.sh --check: код 0 = выключен, 1 = включён
  [ -f "$DEST" ] || return 2
  sh "$DEST" --check >/dev/null 2>&1
}

restore_ipv6() {
  if [ ! -f "$DEST" ]; then
    err "Не могу вызвать откат: $DEST не найден."
    return 1
  fi
  say "Возвращаю IPv6 из последнего бэкапа…"
  if sh "$DEST" --restore-last --yes; then
    ok "IPv6 восстановлен из бэкапа."
  else
    err "Откат завершился с ошибкой — проверьте вручную (бэкапы в $DATA_DIR/backups)."
  fi
}

if [ "$NO_RESTORE" = 1 ]; then
  :
elif [ "$FORCE_RESTORE" = 1 ]; then
  restore_ipv6
elif ipv6_is_off; then
  warn "Сейчас IPv6 ВЫКЛЮЧЕН этим инструментом."
  if [ "$ASSUME_YES" = 1 ]; then
    warn "Режим --yes: IPv6 оставлен выключенным. Бэкапы для ручного отката: $DATA_DIR/backups"
  elif confirm "Вернуть IPv6 перед удалением?" y; then
    restore_ipv6
  else
    warn "IPv6 останется выключенным. Бэкапы для отката: $DATA_DIR/backups"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Снять артефакт жёсткого режима (sysctl)
# ---------------------------------------------------------------------------
if [ -f "$SYSCTL_FILE" ]; then
  rm -f "$SYSCTL_FILE"
  ok "Удалён $SYSCTL_FILE"
  # если IPv6 вернули — снимем и runtime-запрет, чтобы не ждать перезагрузки
  if [ "$NO_RESTORE" != 1 ]; then
    for _k in all default lo; do
      sysctl -w "net.ipv6.conf.$_k.disable_ipv6=0" >/dev/null 2>&1
    done
  fi
  warn "Жёсткий режим использовал sysctl — при сомнениях перезагрузите роутер."
fi

# ---------------------------------------------------------------------------
# 5. Данные (бэкапы/лог/диагностика)
# ---------------------------------------------------------------------------
if [ -d "$DATA_DIR" ]; then
  if [ "$DO_PURGE" = 1 ]; then
    rm -rf "$DATA_DIR"
    ok "Удалены данные: $DATA_DIR"
  elif [ "$ASSUME_YES" = 1 ]; then
    ok "Данные сохранены: $DATA_DIR"
  elif confirm "Удалить данные (бэкапы, лог, диагностику) в $DATA_DIR?" n; then
    rm -rf "$DATA_DIR"
    ok "Удалены данные: $DATA_DIR"
  else
    ok "Данные сохранены: $DATA_DIR"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Сам менеджер + lock
# ---------------------------------------------------------------------------
rm -f "$LOCK"
if [ -f "$DEST" ]; then
  rm -f "$DEST" && ok "Удалён менеджер: $DEST"
else
  warn "Менеджер не найден по пути $DEST (уже удалён?)."
fi

say "--------------------------------------------------"
ok "Готово. openwrt-ipv6-off удалён."
[ -d "$DATA_DIR" ] && say "Бэкапы остались в: $DATA_DIR/backups"
say ""

exit 0
