#!/usr/bin/env bash
{
  echo "=== 執行時間: $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo

  EDB_PIDS=($(ps -eo pid,cmd | grep -E '/bin/edb-postgres( |$).*-D ' | grep -v grep | awk '{print $1}'))
  if [ "${#EDB_PIDS[@]}" -gt 0 ]; then
    echo "=== 目前正在跑的 EDB instance ==="
    printf '%-10s %-35s %-6s %-8s\n' "PID" "資料目錄" "PORT" "版本"
    for pid in "${EDB_PIDS[@]}"; do
      exe=$(readlink -f /proc/$pid/exe)
      datadir=$(tr '\0' ' ' < /proc/$pid/cmdline | grep -oP '(?<=-D )\S+')
      port=$(sed -n '4p' "$datadir/postmaster.pid" 2>/dev/null)
      ver=$("$exe" --version | grep -oP '\d+\.\d+(\.\d+)?')
      printf '%-10s %-35s %-6s %-8s\n' "$pid" "$datadir" "$port" "$ver"
    done
    echo
  fi

  PG_PIDS=($(ps -eo pid,cmd | grep -E '/bin/postgres( |$).*-D ' | grep -v grep | awk '{print $1}'))
  if [ "${#PG_PIDS[@]}" -gt 0 ]; then
    echo "=== 目前正在跑的社群版 PG instance ==="
    printf '%-10s %-35s %-6s %-8s\n' "PID" "資料目錄" "PORT" "版本"
    for pid in "${PG_PIDS[@]}"; do
      exe=$(readlink -f /proc/$pid/exe)
      datadir=$(tr '\0' ' ' < /proc/$pid/cmdline | grep -oP '(?<=-D )\S+')
      port=$(sed -n '4p' "$datadir/postmaster.pid" 2>/dev/null)
      ver=$("$exe" --version | grep -oP '\d+\.\d+(\.\d+)?')
      printf '%-10s %-35s %-6s %-8s\n' "$pid" "$datadir" "$port" "$ver"
    done
    echo
  fi

  EDB_SVCS=($(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^edb-as-[0-9]+\.service$'))
  if [ "${#EDB_SVCS[@]}" -gt 0 ]; then
    echo "=== systemd 認得的 EDB service ==="
    for svc in "${EDB_SVCS[@]}"; do
      state=$(systemctl show -p ActiveState --value "$svc")
      mainpid=$(systemctl show -p MainPID --value "$svc")
      echo "$svc  狀態=$state  MainPID=$mainpid"
    done
    echo
  fi

  PG_SVCS=($(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(postgresql-[0-9]+|postgresql@[^ ]+)\.service$'))
  if [ "${#PG_SVCS[@]}" -gt 0 ]; then
    echo "=== systemd 認得的社群版 PG service ==="
    for svc in "${PG_SVCS[@]}"; do
      state=$(systemctl show -p ActiveState --value "$svc")
      mainpid=$(systemctl show -p MainPID --value "$svc")
      echo "$svc  狀態=$state  MainPID=$mainpid"
    done
  fi
} | tee /root/pg_precheck_$(date +%Y%m%d_%H%M%S).log
