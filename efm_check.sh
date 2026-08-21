#!/usr/bin/env bash

echo "=== EFM Check: $(date '+%Y-%m-%d %H:%M:%S') ==="

# Find EFM systemd services (supports multiple clusters per host)
EFM_SVCS=($(systemctl list-units --type=service --all --no-legend 2>/dev/null \
  | awk '{print $1}' \
  | grep -E '^edb-efm-5\.[0-9]+(-[^.]+)?\.service$'))

if [ "${#EFM_SVCS[@]}" -eq 0 ]; then
  echo "1. EFM running: No"
  exit 0
fi

for svc in "${EFM_SVCS[@]}"; do
  state=$(systemctl show -p ActiveState --value "$svc")
  echo "----"
  echo "Service: $svc (state=$state)"

  if [ "$state" != "active" ]; then
    echo "1. EFM running: No (service exists but inactive)"
    continue
  fi
  echo "1. EFM running: Yes"

  # Derive version, cluster name, properties file, and efm binary
  ver=$(echo "$svc" | grep -oP '(?<=edb-efm-)5\.[0-9]+')
  cluster=$(systemctl show -p Environment --value "$svc" | grep -oP '(?<=CLUSTER=)\S+')
  [ -z "$cluster" ] && cluster="efm"
  propfile="/etc/edb/efm-${ver}/${cluster}.properties"
  efmbin="/usr/edb/efm-${ver}/bin/efm"

  echo "Cluster: $cluster"

  # This node's own address, per its properties file
  myaddr=$(grep -oP '(?<=^bind.address=)[^:]+' "$propfile" 2>/dev/null)
  if [ -z "$myaddr" ]; then
    echo "2. This host in cluster: Unknown (cannot read bind.address from $propfile)"
    continue
  fi

  # Match this node's address in cluster-status output (role column must be
  # one of the known agent types, to avoid false hits on lines like
  # "Allowed node host list:" that also contain this address)
  status=$("$efmbin" cluster-status "$cluster" 2>/dev/null)
  role=$(echo "$status" | awk -v addr="$myaddr" \
    '$1 ~ /^(Primary|Standby|Witness|Idle)$/ && $2 == addr {print $1; exit}')

  if [ -z "$role" ]; then
    echo "2. This host in cluster: No ($myaddr not found in cluster-status)"
    continue
  fi
  echo "2. This host in cluster: Yes"
  echo "3. Role: $role"

  # Which running instance this EFM node is monitoring
  is_witness=$(grep -oP '(?<=^is.witness=)\S+' "$propfile" 2>/dev/null)
  if [ "$is_witness" = "true" ]; then
    echo "4. Monitored instance: N/A (witness node has no local DB)"
    continue
  fi

  dbdatadir=$(grep -oP '(?<=^db.data.dir=)\S+' "$propfile" 2>/dev/null)
  dbdatadir="${dbdatadir%/}"

  found=""
  while read -r ppid; do
    exe=$(readlink -f "/proc/$ppid/exe" 2>/dev/null)
    [ -z "$exe" ] && continue
    pdatadir=$(tr '\0' ' ' < "/proc/$ppid/cmdline" 2>/dev/null | grep -oP '(?<=-D )\S+')
    pdatadir="${pdatadir%/}"
    if [ "$pdatadir" = "$dbdatadir" ]; then
      pport=$(sed -n '4p' "$pdatadir/postmaster.pid" 2>/dev/null)
      pver=$("$exe" --version 2>/dev/null | grep -oP '\d+\.\d+(\.\d+)?')
      found="PID=$ppid Port=$pport Version=$pver"
      break
    fi
  done < <(ps -eo pid,cmd | grep -E '/bin/(edb-postgres|postgres)( |$).*-D ' | grep -v grep | awk '{print $1}')

  if [ -n "$found" ]; then
    echo "4. Monitored instance: $found (datadir=$dbdatadir)"
  else
    echo "4. Monitored instance: db.data.dir=$dbdatadir, but no matching running process found"
  fi
done
