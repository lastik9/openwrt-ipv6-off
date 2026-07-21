#!/bin/ash
# ipv6-off.sh — менеджер отключения IPv6 для OpenWrt
# Версия: 2.1.4
# Лицензия: MIT
#
# Возможности:
#   - Точный бэкап "как было" (копия сырых /etc/config/*) + чистое восстановление
#   - Отключение IPv6 через UCI (network / dhcp / firewall) + опционально sysctl
#   - Самодостаточный watchdog отката по IPv4 (переживает разрыв SSH и любой способ запуска)
#   - Точная проверка статуса с указанием причин
#   - Диагностика одной командой
#   - Неинтерактивные флаги: --disable / --restore-last / --check / --status / --diag
#   - Ротация лога, lock-файл против параллельного запуска
#
# ВНИМАНИЕ: скрипт меняет сетевые настройки и перезапускает сеть.
# Запускайте с root. Сначала прочитайте код — не запускайте из недоверенных источников.

set -u

VERSION="2.1.4"

############################################
# UI
############################################
if [ -t 1 ]; then
  RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"; YEL="$(printf '\033[33m')"
  BLU="$(printf '\033[34m')"; GRY="$(printf '\033[90m')"; RST="$(printf '\033[0m')"
else
  RED=""; GRN=""; YEL=""; BLU=""; GRY=""; RST=""
fi

ui_clear(){ [ -t 1 ] && printf "\033[H\033[2J" || true; }
ui_sep(){ printf "%s────────────────────────────────────────────%s\n" "$GRY" "$RST"; }
ui_pause(){ printf "%sНажмите Enter для продолжения...%s " "$GRY" "$RST"; IFS= read -r _ || true; }
ui_ok(){   printf "%s✅ %s%s\n" "$GRN" "$*" "$RST"; }
ui_warn(){ printf "%s⚠️  %s%s\n" "$YEL" "$*" "$RST"; }
ui_err(){  printf "%s❌ %s%s\n" "$RED" "$*" "$RST"; }
ui_info(){ printf "%s%s%s\n" "$GRY" "$*" "$RST"; }
ui_confirm(){
  printf "%s [y/N]: " "$1"
  IFS= read -r a || true
  case "${a:-}" in
    y|Y|yes|YES|да|ДА) return 0 ;;
    *) return 1 ;;
  esac
}

############################################
# ПУТИ / КОНСТАНТЫ
############################################
BASE_DIR="/root/ipv6-off"
LOG="$BASE_DIR/ipv6-off.log"
BACKUP_ROOT="$BASE_DIR/backups"
LOCK_FILE="/tmp/ipv6-off.lock"
WATCHDOG_PID_FILE="/tmp/ipv6_watchdog.pid"
WATCHDOG_SCRIPT="/tmp/ipv6_watchdog.sh"
SYSCTL_FILE="/etc/sysctl.d/99-ipv6-off.conf"

# Конфиги, которые бэкапим/восстанавливаем целиком (сырые файлы)
CONFIGS="network dhcp firewall"

LOG_MAX_BYTES="409600"   # ~400 KB
WD_DELAY="25"            # пауза перед первой проверкой связи
WD_TRIES="6"             # число попыток
WD_INTERVAL="5"          # интервал между попытками
WD_PING_TIMEOUT="2"      # таймаут одного ping
# Хосты для проверки IPv4-связи (успех = ответил ХОТЯ БЫ ОДИН).
# Cloudflare/Google + Яндекс как подстраховка: за белыми списками
# 1.1.1.1/8.8.8.8 могут быть недоступны, а 77.88.8.8/77.88.8.1 обычно работают.
WD_PING_HOSTS="1.1.1.1 8.8.8.8 77.88.8.8 77.88.8.1"

# Флаги неинтерактивного режима
ASSUME_YES="0"
HARD_SYSCTL="0"

############################################
# LOCK (защита от параллельного запуска)
############################################
acquire_lock(){
  # watchdog-режим lock не берёт
  if [ -f "$LOCK_FILE" ]; then
    oldpid="$(cat "$LOCK_FILE" 2>/dev/null)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
      ui_err "Уже запущен другой экземпляр (pid=$oldpid). Выход."
      exit 1
    fi
  fi
  echo "$$" >"$LOCK_FILE" 2>/dev/null || true
}
release_lock(){ rm -f "$LOCK_FILE" 2>/dev/null || true; }

############################################
# ЛОГИ
############################################
log_init(){
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  [ -f "$LOG" ] || : >"$LOG" 2>/dev/null || true
}
log(){ printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }
run(){ "$@" >>"$LOG" 2>&1; }

rotate_log_if_needed(){
  [ -f "$LOG" ] || return 0
  size="$(wc -c < "$LOG" 2>/dev/null)"
  [ -n "$size" ] || return 0
  if [ "$size" -gt "$LOG_MAX_BYTES" ] 2>/dev/null; then
    mv -f "$LOG" "${LOG}.1" 2>/dev/null || true
    : >"$LOG" 2>/dev/null || true
    log "=== LOG rotated (был $size байт) ==="
  fi
}

ensure_dirs(){ mkdir -p "$BASE_DIR" "$BACKUP_ROOT" 2>/dev/null || true; }
uget(){ uci -q get "$1" 2>/dev/null; }

############################################
# ОПРЕДЕЛЕНИЕ ПОДКЛЮЧЕНИЯ (SSH)
############################################
get_lan_dev(){
  d="$(uget network.lan.device)"; [ -n "$d" ] && { printf "%s" "$d"; return; }
  d="$(uget network.lan.ifname)"; [ -n "$d" ] && { printf "%s" "$d"; return; }
  printf "br-lan"
}

conn_line_plain(){
  if [ -n "${SSH_CONNECTION:-}" ]; then
    cip="$(printf "%s" "$SSH_CONNECTION" | awk '{print $1}')"
    dev="$(ip route get "$cip" 2>/dev/null | head -n1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ -z "$dev" ] && dev="unknown"
    lan_dev="$(get_lan_dev)"
    if [ "$dev" = "$lan_dev" ]; then
      printf "SSH: %s через %s (LAN)\n" "$cip" "$dev"
    else
      printf "SSH: %s через %s (RISK)\n" "$cip" "$dev"
    fi
    return
  fi
  printf "SSH: не определено (локальная консоль?)\n"
}

watchdog_running(){
  [ -f "$WATCHDOG_PID_FILE" ] || return 1
  p="$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

watchdog_status_line(){
  if watchdog_running; then
    printf "%sЗащита отката: включена%s\n" "$BLU" "$RST"
  else
    printf "%sЗащита отката: нет%s\n" "$GRY" "$RST"
  fi
}

############################################
# БЫСТРЫЙ СТАТУС IPv6 (для шапки)
############################################
ipv6_quick_status(){
  ula="$(uget network.globals.ula_prefix)"
  ip6assign="$(uget network.lan.ip6assign)"
  reqaddr="$(uget network.wan.reqaddress)"
  reqpref="$(uget network.wan.reqprefix)"
  wan6="$(uci -q show network.wan6 2>/dev/null | head -n1)"
  dhcpv6="$(uget dhcp.lan.dhcpv6)"
  ra="$(uget dhcp.lan.ra)"
  ndp="$(uget dhcp.lan.ndp)"

  /etc/init.d/odhcpd enabled >/dev/null 2>&1; od_en=$?
  ips6_glob="$(ip -6 addr show scope global 2>/dev/null | grep -Ec 'inet6 ')"
  routes6_real="$(ip -6 route 2>/dev/null | grep -Ec '(^default| via )')"

  if [ -z "$ula" ] &&
     [ "${ip6assign:-}" = "0" ] &&
     { [ -z "$reqaddr" ] || [ "$reqaddr" = "none" ]; } &&
     { [ -z "$reqpref" ] || [ "$reqpref" = "no" ]; } &&
     [ -z "$wan6" ] &&
     [ "${dhcpv6:-}" = "disabled" ] &&
     [ "${ra:-}" = "disabled" ] &&
     [ "${ndp:-}" = "disabled" ] &&
     [ "$od_en" -ne 0 ] &&
     [ "$ips6_glob" -eq 0 ] &&
     [ "$routes6_real" -eq 0 ]; then
      printf "OFF"
  else
      printf "ON"
  fi
}

############################################
# HEADER / MENU
############################################
last_backup_name(){
  [ -d "$BACKUP_ROOT" ] || { printf ""; return; }
  ls -1 "$BACKUP_ROOT" 2>/dev/null | sort | tail -n 1
}

header(){
  ui_clear
  ensure_dirs
  rotate_log_if_needed

  st="$(ipv6_quick_status)"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  last_b="$(last_backup_name)"

  printf "%s🚫 Отключение IPv6 (v%s)%s\n" "$BLU" "$VERSION" "$RST"
  ui_info "Менеджер: бэкап / откат / проверка / диагностика"
  ui_sep

  if [ "$st" = "OFF" ]; then
    ui_ok "Состояние: IPv6 полностью отключён"
  else
    ui_err "Состояние: IPv6 активен"
  fi
  ui_info "Обновлено: $ts"
  ui_info "$(conn_line_plain | tr -d '\n')"
  watchdog_status_line
  if [ -n "$last_b" ]; then ui_info "Последний бэкап: $last_b"; else ui_info "Последний бэкап: -"; fi
  ui_info "Лог: $LOG"
  ui_sep
}

menu(){
  header
  printf "  1) 🛑 Отключить IPv6 (бэкап + защита отката)\n"
  printf "  2) 🔎 Проверка статуса IPv6 (точная)\n"
  printf "  3) 📦 Диагностика (сохранить в файл)\n"
  printf "  4) 📜 Показать лог\n"
  printf "  5) 🔄 Восстановить из бэкапа (последний / выбрать)\n"
  printf "  6) 📁 Бэкапы (список / удалить)\n"
  printf "\n"
  printf "  0) ❌ Выход\n"
  ui_sep
  printf "Ваш выбор [0-6]: "
}

############################################
# FIREWALL: чистка IPv6-правил
# (обратный порядок удаления — иначе индексы сползают)
############################################
cleanup_ipv6_rules(){
  ui_info "Очистка IPv6-правил из firewall..."
  log "=== CLEANUP: IPv6 firewall rules ==="

  idx=0
  ipv6_indices=""
  while uci -q show "firewall.@rule[$idx]" >/dev/null 2>&1; do
    family="$(uci -q get "firewall.@rule[$idx].family" 2>/dev/null)"
    if [ "$family" = "ipv6" ]; then
      ipv6_indices="$idx${ipv6_indices:+ }$ipv6_indices"   # в начало = обратный порядок
    fi
    idx=$((idx + 1))
  done

  deleted=0
  for ridx in $ipv6_indices; do
    log "uci delete firewall.@rule[$ridx] (family=ipv6)"
    uci delete "firewall.@rule[$ridx]" >>"$LOG" 2>&1 && deleted=$((deleted + 1))
  done

  if [ "$deleted" -eq 0 ]; then
    ui_ok "IPv6-правила firewall: не найдены"
  else
    ui_ok "IPv6-правила firewall: удалено $deleted"
  fi
}

############################################
# БЭКАПЫ (копия сырых /etc/config/* — точное восстановление)
############################################
backup_create(){
  ensure_dirs
  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  dir="$BACKUP_ROOT/$ts"
  mkdir -p "$dir" 2>/dev/null || return 1

  for c in $CONFIGS; do
    if [ -f "/etc/config/$c" ]; then
      cp -a "/etc/config/$c" "$dir/$c" 2>>"$LOG" || return 1
    fi
    # человекочитаемая копия для глаз
    uci export "$c" >"$dir/$c.export" 2>/dev/null || true
  done

  /etc/init.d/odhcpd enabled >/dev/null 2>&1
  if [ $? -eq 0 ]; then odhcpd_en="1"; else odhcpd_en="0"; fi

  {
    printf "created_at=%s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "version=%s\n" "$VERSION"
    printf "conn=%s\n" "$(conn_line_plain)"
    printf "odhcpd_enabled=%s\n" "$odhcpd_en"
    printf "board=%s\n" "$(ubus call system board 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
  } >"$dir/meta.txt" 2>/dev/null || true

  log "BACKUP created: $dir"
  printf "%s" "$dir"
  return 0
}

list_backups(){
  [ -d "$BACKUP_ROOT" ] || return 0
  ls -1 "$BACKUP_ROOT" 2>/dev/null | sort
}

# Результат кладём в глобальную PICKED_DIR (НЕ через stdout: вызов идёт из
# интерактивного меню напрямую, а не через $(...), иначе UI "съедается")
PICKED_DIR=""
pick_backup(){
  PICKED_DIR=""
  ui_clear
  printf "%s📁 Выбор бэкапа%s\n" "$BLU" "$RST"
  ui_sep
  b_list="$(list_backups)"
  if [ -z "$b_list" ]; then ui_err "Бэкапы не найдены: $BACKUP_ROOT"; ui_pause; return 1; fi

  i=1
  echo "$b_list" | while IFS= read -r b; do printf "  %d) %s\n" "$i" "$b"; i=$((i+1)); done
  printf "\nВведите номер (0 - назад): "
  IFS= read -r n || true
  [ "$n" = "0" ] && return 1
  sel="$(echo "$b_list" | sed -n "${n}p")"
  if [ -z "$sel" ]; then ui_err "Неверный выбор"; ui_pause; return 1; fi
  PICKED_DIR="$BACKUP_ROOT/$sel"
  return 0
}

# Восстановление: побайтовая замена конфигов + откат sysctl + перезапуск
restore_backup_dir(){
  dir="$1"; force="${2:-}"

  [ -d "$dir" ] || { ui_err "Бэкап не найден: $dir"; log "RESTORE fail: no dir $dir"; return 1; }
  for c in $CONFIGS; do
    [ -f "$dir/$c" ] || { ui_err "В бэкапе нет $c"; return 1; }
  done

  if [ "$force" != "force" ]; then
    ui_warn "Будут восстановлены настройки из:"
    ui_info "  $dir"
    ui_warn "Сеть будет перезапущена"
    ui_confirm "Продолжить?" || { ui_info "Отмена"; return 1; }
  fi

  log "=== START restore: $dir ==="
  for c in $CONFIGS; do
    cp -a "$dir/$c" "/etc/config/$c" >>"$LOG" 2>&1
  done

  # снять жёсткий sysctl-запрет IPv6, если он ставился
  if [ -f "$SYSCTL_FILE" ]; then
    rm -f "$SYSCTL_FILE" 2>/dev/null || true
    for k in all default lo; do
      sysctl -w "net.ipv6.conf.$k.disable_ipv6=0" >>"$LOG" 2>&1 || true
    done
    log "restore: removed $SYSCTL_FILE + disable_ipv6=0"
  fi

  # восстановить состояние odhcpd
  odhcpd_en="$(grep -E '^odhcpd_enabled=' "$dir/meta.txt" 2>/dev/null | tail -n1 | cut -d= -f2)"
  if [ "$odhcpd_en" = "1" ]; then run /etc/init.d/odhcpd enable; else run /etc/init.d/odhcpd disable; fi

  run /etc/init.d/firewall restart
  run /etc/init.d/network restart
  run /etc/init.d/odhcpd restart
  log "=== END restore: $dir ==="
  return 0
}

restore_menu(){
  ui_clear
  printf "%s🔄 Восстановление%s\n" "$BLU" "$RST"
  ui_sep
  printf "  1) Восстановить последний бэкап\n"
  printf "  2) Выбрать бэкап из списка\n"
  printf "\n  0) Назад\n"
  ui_sep
  printf "Ваш выбор [0-2]: "
  IFS= read -r r || true
  case "$r" in
    1)
      last="$(last_backup_name)"
      [ -z "$last" ] && { ui_err "Бэкапов нет"; ui_pause; return 0; }
      if restore_backup_dir "$BACKUP_ROOT/$last" ""; then ui_ok "Готово"; else ui_err "Ошибка (см. $LOG)"; fi
      ui_pause ;;
    2)
      pick_backup || return 0
      if restore_backup_dir "$PICKED_DIR" ""; then ui_ok "Готово"; else ui_err "Ошибка (см. $LOG)"; fi
      ui_pause ;;
    0) return 0 ;;
    *) ui_err "Неверный выбор"; sleep 1 ;;
  esac
}

backups_manage_menu(){
  ui_clear
  printf "%s📁 Бэкапы%s\n" "$BLU" "$RST"
  ui_sep
  b_list="$(list_backups)"
  [ -z "$b_list" ] && { ui_err "Бэкапов не найдено: $BACKUP_ROOT"; ui_pause; return 0; }

  ui_info "Список:"; printf "%s\n\n" "$b_list"
  printf "  1) Удалить один бэкап\n"
  printf "  2) Удалить все, кроме последнего\n"
  printf "\n  0) Назад\n"
  ui_sep
  printf "Ваш выбор [0-2]: "
  IFS= read -r m || true
  case "$m" in
    1)
      pick_backup || return 0
      if ui_confirm "Удалить $PICKED_DIR ?"; then
        rm -rf "$PICKED_DIR" 2>/dev/null || true; log "BACKUP deleted: $PICKED_DIR"; ui_ok "Удалено"
      else ui_info "Отмена"; fi
      ui_pause ;;
    2)
      last="$(last_backup_name)"
      ui_warn "Будут удалены все бэкапы, кроме: $last"
      if ui_confirm "Продолжить?"; then
        for b in $(list_backups); do
          [ "$b" = "$last" ] && continue
          rm -rf "$BACKUP_ROOT/$b" 2>/dev/null || true; log "BACKUP deleted: $BACKUP_ROOT/$b"
        done
        ui_ok "Готово"
      else ui_info "Отмена"; fi
      ui_pause ;;
    0) return 0 ;;
    *) ui_err "Неверный выбор"; sleep 1 ;;
  esac
}

############################################
# WATCHDOG — самодостаточный, не зависит от $0
############################################
watchdog_start(){
  backup_dir="$1"

  # прибить старый watchdog
  if watchdog_running; then
    kill "$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)" 2>/dev/null || true
  fi
  rm -f "$WATCHDOG_PID_FILE" 2>/dev/null || true

  # сгенерировать автономный скрипт со всеми значениями внутри
  cat >"$WATCHDOG_SCRIPT" <<WDEOF
#!/bin/sh
BDIR='$backup_dir'
LOG='$LOG'
PIDF='$WATCHDOG_PID_FILE'
DELAY='$WD_DELAY'
TRIES='$WD_TRIES'
INTERVAL='$WD_INTERVAL'
PT='$WD_PING_TIMEOUT'
PING_HOSTS='$WD_PING_HOSTS'
CONFIGS='$CONFIGS'
SYSCTL_FILE='$SYSCTL_FILE'

wlog(){ printf "[%s] WD %s\n" "\$(date '+%Y-%m-%d %H:%M:%S')" "\$*" >>"\$LOG" 2>/dev/null; }
ping_ok(){
  for h in \$PING_HOSTS; do
    ping -c1 -W "\$PT" "\$h" >/dev/null 2>&1 && return 0
  done
  return 1
}

wlog "started (backup=\$BDIR delay=\${DELAY}s tries=\$TRIES)"
sleep "\$DELAY"

i=1
while [ "\$i" -le "\$TRIES" ]; do
  if ping_ok; then
    wlog "IPv4 OK (try \$i) — отката не будет"
    rm -f "\$PIDF" 2>/dev/null
    exit 0
  fi
  wlog "IPv4 НЕ доступен (try \$i/\$TRIES)"
  i=\$((i+1))
  sleep "\$INTERVAL"
done

wlog "IPv4 не поднялся — ОТКАТ из \$BDIR"
for c in \$CONFIGS; do
  [ -f "\$BDIR/\$c" ] && cp -a "\$BDIR/\$c" "/etc/config/\$c" >>"\$LOG" 2>&1
done
if [ -f "\$SYSCTL_FILE" ]; then
  rm -f "\$SYSCTL_FILE" 2>/dev/null
  for k in all default lo; do sysctl -w "net.ipv6.conf.\$k.disable_ipv6=0" >>"\$LOG" 2>&1; done
fi
od="\$(grep -E '^odhcpd_enabled=' "\$BDIR/meta.txt" 2>/dev/null | tail -n1 | cut -d= -f2)"
[ "\$od" = "1" ] && /etc/init.d/odhcpd enable >>"\$LOG" 2>&1 || /etc/init.d/odhcpd disable >>"\$LOG" 2>&1
/etc/init.d/firewall restart >>"\$LOG" 2>&1
/etc/init.d/network restart >>"\$LOG" 2>&1
/etc/init.d/odhcpd restart >>"\$LOG" 2>&1
wlog "откат завершён"
rm -f "\$PIDF" 2>/dev/null
exit 0
WDEOF

  chmod +x "$WATCHDOG_SCRIPT" 2>/dev/null || true

  # отцепить от текущего SSH-сеанса, чтобы пережить обрыв
  if command -v setsid >/dev/null 2>&1; then
    setsid "$WATCHDOG_SCRIPT" </dev/null >/dev/null 2>&1 &
  elif command -v nohup >/dev/null 2>&1; then
    nohup "$WATCHDOG_SCRIPT" </dev/null >/dev/null 2>&1 &
  else
    "$WATCHDOG_SCRIPT" </dev/null >/dev/null 2>&1 &
  fi
  echo $! >"$WATCHDOG_PID_FILE" 2>/dev/null || true
  log "WATCHDOG launched pid=$! (backup=$backup_dir)"
}

############################################
# ТОЧНАЯ ПРОВЕРКА IPv6 (с причинами)
# код возврата: 0 = выключен, 1 = включён
############################################
check_ipv6_detailed(){
  quiet="${1:-}"
  if [ "$quiet" != "quiet" ]; then
    ui_clear
    printf "%s🔎 Проверка IPv6 (точная)%s\n" "$BLU" "$RST"
    ui_sep
    ui_info "$(conn_line_plain | tr -d '\n')"
    ui_sep
  fi

  issues=""

  if uci -q show network.wan6 >/dev/null 2>&1; then
    [ "$quiet" != "quiet" ] && ui_err "wan6: найден"
    issues="${issues}\n- Есть интерфейс wan6"
  else
    [ "$quiet" != "quiet" ] && ui_ok "wan6: нет"
  fi

  /etc/init.d/odhcpd enabled >/dev/null 2>&1; od_en=$?
  if [ "$od_en" -eq 0 ]; then
    [ "$quiet" != "quiet" ] && ui_warn "odhcpd: enabled"
    issues="${issues}\n- odhcpd включён (enabled)"
  else
    [ "$quiet" != "quiet" ] && ui_ok "odhcpd: disabled"
  fi
  if pidof odhcpd >/dev/null 2>&1; then
    [ "$quiet" != "quiet" ] && ui_warn "odhcpd: running"
    issues="${issues}\n- odhcpd запущен (running)"
  else
    [ "$quiet" != "quiet" ] && ui_ok "odhcpd: stopped"
  fi

  ula="$(uget network.globals.ula_prefix)"
  ip6assign="$(uget network.lan.ip6assign)"
  reqaddr="$(uget network.wan.reqaddress)"
  reqpref="$(uget network.wan.reqprefix)"
  dhcpv6_lan="$(uget dhcp.lan.dhcpv6)"
  ra_lan="$(uget dhcp.lan.ra)"
  ndp_lan="$(uget dhcp.lan.ndp)"

  if [ "$quiet" != "quiet" ]; then
    ui_sep
    ui_info "UCI / network:"
    printf "  ula_prefix: %s\n" "${ula:-<none>}"
    printf "  lan.ip6assign: %s\n" "${ip6assign:-<none>}"
    printf "  wan.reqaddress: %s\n" "${reqaddr:-<none>}"
    printf "  wan.reqprefix: %s\n" "${reqpref:-<none>}"
    ui_info "UCI / dhcp (lan):"
    printf "  ra=%s, dhcpv6=%s, ndp=%s\n" "${ra_lan:-<none>}" "${dhcpv6_lan:-<none>}" "${ndp_lan:-<none>}"
  fi

  [ -n "$ula" ] && issues="${issues}\n- network.globals.ula_prefix задан"
  [ "${ip6assign:-}" != "0" ] && issues="${issues}\n- network.lan.ip6assign != 0"
  if [ -n "$reqaddr" ] && [ "$reqaddr" != "none" ]; then issues="${issues}\n- network.wan.reqaddress != none"; fi
  if [ -n "$reqpref" ] && [ "$reqpref" != "no" ]; then issues="${issues}\n- network.wan.reqprefix != no"; fi
  [ "${dhcpv6_lan:-}" != "disabled" ] && issues="${issues}\n- dhcp.lan.dhcpv6 != disabled"
  [ "${ra_lan:-}" != "disabled" ] && issues="${issues}\n- dhcp.lan.ra != disabled"
  [ "${ndp_lan:-}" != "disabled" ] && issues="${issues}\n- dhcp.lan.ndp != disabled"

  glob_lines="$(ip -6 addr show scope global 2>/dev/null | grep -Ec 'inet6 ')"
  if [ "$glob_lines" -gt 0 ] 2>/dev/null; then
    if [ "$quiet" != "quiet" ]; then
      ui_sep; ui_err "IPv6 адреса (global): есть ($glob_lines)"
      ip -6 addr show scope global 2>/dev/null | sed -n '1,60p'
    fi
    issues="${issues}\n- Есть глобальные IPv6-адреса (scope global)"
  else
    [ "$quiet" != "quiet" ] && { ui_sep; ui_ok "IPv6 адреса (global): нет"; }
  fi

  routes_real="$(ip -6 route 2>/dev/null | grep -Ec '(^default| via )')"
  if [ "$routes_real" -gt 0 ] 2>/dev/null; then
    if [ "$quiet" != "quiet" ]; then
      ui_err "IPv6 маршруты: есть"
      ip -6 route 2>/dev/null | sed -n '1,40p'
    fi
    issues="${issues}\n- Есть IPv6-маршруты (default/via)"
  else
    [ "$quiet" != "quiet" ] && ui_ok "IPv6 маршруты: нет"
  fi

  if [ -z "$issues" ]; then
    [ "$quiet" != "quiet" ] && { ui_sep; ui_ok "Итог: IPv6 полностью отключён"; }
    log "CHECK: IPv6 OFF"
    [ "$quiet" != "quiet" ] && ui_pause
    return 0
  else
    if [ "$quiet" != "quiet" ]; then
      ui_sep; ui_err "Итог: IPv6 отключён НЕ полностью"; ui_warn "Причины:"
      printf "%b\n" "$issues" | sed '/^$/d'
      ui_pause
    fi
    log "CHECK: IPv6 ON"
    return 1
  fi
}

############################################
# ДИАГНОСТИКА
############################################
collect_diag(){
  ui_clear
  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  out="$BASE_DIR/ipv6-diag-${ts}.txt"
  printf "%s📦 Диагностика%s\n" "$BLU" "$RST"; ui_sep; ui_info "Файл: $out"; ui_sep

  {
    printf "=== DIAG created_at: %s (script v%s) ===\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$VERSION"
    printf "=== CONNECTION ===\n"; conn_line_plain
    printf "\n=== SYSTEM (board) ===\n"; ubus call system board 2>/dev/null
    printf "\n=== UPTIME ===\n"; uptime
    printf "\n=== SERVICES ===\n--- odhcpd ---\n"
    /etc/init.d/odhcpd enabled >/dev/null 2>&1; echo "enabled_exit=$?"
    pidof odhcpd >/dev/null 2>&1 && echo "running=yes" || echo "running=no"
    printf "--- network ---\n"; /etc/init.d/network status 2>/dev/null
    printf "--- firewall ---\n"; /etc/init.d/firewall status 2>/dev/null
    printf "\n=== IP (v4) ===\n"; ip a
    printf "\n=== ROUTES (v4) ===\n"; ip r
    printf "\n=== IP (v6) ===\n"; ip -6 a
    printf "\n=== ROUTES (v6) ===\n"; ip -6 r
    printf "\n=== sysctl disable_ipv6 ===\n"; sysctl -a 2>/dev/null | grep disable_ipv6
    printf "\n=== UCI (key parts) ===\n--- network ---\n"
    uci -q show network | grep -E 'globals\.ula_prefix|lan\.ip6assign|wan\.reqaddress|wan\.reqprefix|wan6' || true
    printf "--- dhcp ---\n"; uci -q show dhcp | grep -E 'dhcpv6|\.ra=|\.ndp=' || true
    printf "--- firewall (ipv6 family) ---\n"; uci -q show firewall | grep -E '\.family=.ipv6.' || true
    printf "\n=== LOGREAD (last 250) ===\n"; logread 2>/dev/null | tail -n 250
    printf "\n=== SCRIPT LOG (last 200) ===\n"; [ -f "$LOG" ] && tail -n 200 "$LOG" || echo "<no log>"
    printf "=== END ===\n"
  } >"$out" 2>/dev/null

  if [ -s "$out" ]; then ui_ok "Готово"; ui_info "Путь: $out"; log "DIAG saved: $out"
  else ui_err "Не удалось создать файл (права/диск?)"; log "DIAG fail: $out"; fi
  ui_pause
}

############################################
# ОТКЛЮЧЕНИЕ IPv6
############################################
disable_ipv6_full(){
  interactive="${1:-1}"

  if [ "$interactive" = "1" ]; then
    ui_clear
    printf "%s🛑 Отключение IPv6%s\n" "$BLU" "$RST"; ui_sep
    ui_warn "Внимание: будет перезапущена сеть"
    ui_info "Доступ по SSH/LuCI может временно пропасть"
    ui_info "Включаю защиту отката по IPv4 (успех = ответит любой из: $WD_PING_HOSTS)"
    ui_sep
    if [ "$ASSUME_YES" != "1" ]; then
      ui_confirm "Продолжить?" || { ui_info "Отмена"; ui_pause; return; }
      ui_sep
      ui_info "Обычное отключение (рекомендуется): выключает IPv6 через настройки"
      ui_info "OpenWrt, сохраняет link-local и совместимость. По умолчанию — жми Enter."
      ui_info "Жёсткое (sysctl): гасит стек IPv6 в ядре целиком, включая fe80::. Нужно редко."
      if ui_confirm "Дополнительно вырубить IPv6 на уровне ядра (sysctl)? (Enter = нет)"; then HARD_SYSCTL="1"; fi
    fi
  fi

  log "=== START disable IPv6 (hard_sysctl=$HARD_SYSCTL) ==="

  ui_info "Создаю бэкап текущих настроек..."
  backup_dir="$(backup_create)"
  if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
    ui_err "Не удалось создать бэкап. Отмена."; log "DISABLE aborted: backup failed"
    [ "$interactive" = "1" ] && ui_pause; return 1
  fi
  ui_ok "Бэкап: $backup_dir"

  ui_info "Запускаю защиту отката (watchdog)..."
  watchdog_start "$backup_dir"
  ui_ok "Защита отката запущена (откатится сама, если IPv4 не поднимется)"
  ui_sep

  cleanup_ipv6_rules
  ui_sep

  ui_info "Применяю настройки отключения IPv6 (UCI)..."
  log "=== UCI: disable IPv6 ==="
  run uci -q delete network.globals.ula_prefix
  run uci set network.lan.ip6assign='0'
  run uci -q delete network.lan.ip6hint
  run uci -q delete network.lan.ip6ifaceid
  run uci set network.wan.reqaddress='none'
  run uci set network.wan.reqprefix='no'
  if uci -q show network.wan6 >/dev/null 2>&1; then run uci delete network.wan6; log "deleted network.wan6"; fi

  if uci -q show dhcp.lan >/dev/null 2>&1; then
    run uci set dhcp.lan.dhcpv6='disabled'; run uci set dhcp.lan.ra='disabled'; run uci set dhcp.lan.ndp='disabled'
  fi
  if uci -q show dhcp.wan >/dev/null 2>&1; then
    run uci set dhcp.wan.dhcpv6='disabled'; run uci set dhcp.wan.ra='disabled'; run uci set dhcp.wan.ndp='disabled'
  fi

  run uci commit network
  run uci commit dhcp
  run uci commit firewall

  if [ "$HARD_SYSCTL" = "1" ]; then
    ui_info "Отключаю IPv6 на уровне ядра (sysctl, персистентно)..."
    {
      echo "net.ipv6.conf.all.disable_ipv6=1"
      echo "net.ipv6.conf.default.disable_ipv6=1"
      echo "net.ipv6.conf.lo.disable_ipv6=1"
    } >"$SYSCTL_FILE" 2>/dev/null || true
    for k in all default lo; do run sysctl -w "net.ipv6.conf.$k.disable_ipv6=1"; done
    log "sysctl hard-disable applied ($SYSCTL_FILE)"
  fi

  ui_info "Останавливаю odhcpd..."
  run /etc/init.d/odhcpd stop
  run /etc/init.d/odhcpd disable

  ui_info "Перезапускаю firewall и сеть..."
  run /etc/init.d/firewall restart
  run /etc/init.d/network restart

  log "=== END disable IPv6 ==="
  ui_ok "Готово"
  if [ "$interactive" = "1" ]; then
    ui_info "Проверяю результат..."; sleep 2; check_ipv6_detailed
  fi
  return 0
}

############################################
# ЛОГ
############################################
show_log(){
  ui_clear
  printf "%s📜 Лог (последние 200 строк)%s\n" "$BLU" "$RST"; ui_sep
  if [ -s "$LOG" ]; then tail -n 200 "$LOG"; else ui_info "Лог пуст"; fi
  ui_sep; ui_pause
}

############################################
# HELP
############################################
show_help(){
  cat <<EOF
ipv6-off.sh v$VERSION — менеджер отключения IPv6 для OpenWrt

Использование:
  ipv6-off.sh                  интерактивное меню
  ipv6-off.sh --disable [--yes] [--hard]   отключить IPv6 (--hard = ещё и sysctl)
  ipv6-off.sh --restore-last [--yes]       восстановить последний бэкап
  ipv6-off.sh --check                      подробная проверка (код 0=выкл, 1=вкл)
  ipv6-off.sh --status                     краткий статус ON/OFF
  ipv6-off.sh --diag                       собрать диагностику в файл
  ipv6-off.sh --help                       эта справка

Файлы:
  лог:     $LOG
  бэкапы:  $BACKUP_ROOT
EOF
}

############################################
# MAIN
############################################
main(){
  log_init
  ensure_dirs
  rotate_log_if_needed

  # watchdog-режим больше не через $0 — оставлено для обратной совместимости
  case "${1:-}" in
    --watchdog) shift; log "legacy --watchdog вызван (игнор, watchdog теперь автономный)"; exit 0 ;;
    --help|-h) show_help; exit 0 ;;
    --status)  s="$(ipv6_quick_status)"; echo "$s"; [ "$s" = "OFF" ] && exit 0 || exit 1 ;;
    --check)   check_ipv6_detailed quiet; rc=$?; [ "$rc" -eq 0 ] && echo "IPv6: OFF" || echo "IPv6: ON"; exit $rc ;;
    --diag)    acquire_lock; trap release_lock EXIT INT TERM; collect_diag; exit 0 ;;
    --disable)
      acquire_lock; trap release_lock EXIT INT TERM
      shift
      for a in "$@"; do
        case "$a" in
          --yes|-y) ASSUME_YES="1" ;;
          --hard)   HARD_SYSCTL="1" ;;
        esac
      done
      disable_ipv6_full 0
      check_ipv6_detailed quiet; exit $?
      ;;
    --restore-last)
      acquire_lock; trap release_lock EXIT INT TERM
      shift
      for a in "$@"; do case "$a" in --yes|-y) ASSUME_YES="1" ;; esac; done
      last="$(last_backup_name)"
      [ -z "$last" ] && { echo "Бэкапов нет"; exit 1; }
      if [ "$ASSUME_YES" = "1" ]; then
        restore_backup_dir "$BACKUP_ROOT/$last" "force"
      else
        restore_backup_dir "$BACKUP_ROOT/$last" ""
      fi
      exit $?
      ;;
  esac

  # интерактивное меню
  acquire_lock
  trap release_lock EXIT INT TERM

  while true; do
    menu
    IFS= read -r opt || true
    case "$opt" in
      1) HARD_SYSCTL="0"; disable_ipv6_full 1 ;;
      2) check_ipv6_detailed ;;
      3) collect_diag ;;
      4) show_log ;;
      5) restore_menu ;;
      6) backups_manage_menu ;;
      0) ui_info "Выход"; exit 0 ;;
      *) ui_err "Неверный выбор"; sleep 1 ;;
    esac
  done
}

main "$@"
