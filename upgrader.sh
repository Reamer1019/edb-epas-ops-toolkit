#!/usr/bin/env bash
#
# upgrader.sh — EDB Postgres Advanced Server 升級互動工具
#
# Designer: Reamer
#
# 支援「小版本」與「大版本」升級流程。
#
# 特色/設計原則：
#   - 每一個會實際造成影響的動作，執行前都會先印出「即將做什麼」，經使用者
#     輸入 y 確認後才會真的執行，任何一步都可以取消整個流程。
#   - 全程即時把互動內容、指令、輸出寫進當前目錄下一個帶時間戳記的 log 檔，
#     就算腳本中途 crash，log 檔也已經落地，可以事後查。
#   - 在任何一個「確認」的提示上，都可以輸入 --show-logs 直接印出目前為止
#     的完整 log 內容，看完會重新問一次同一個問題，不會中斷流程。
#   - 小版本：EFM 的關閉/開啟是分開處理的，本腳本每次只處理「一台機器」的
#     升級與關閉 EFM（依 Witness→Standby→Primary 的順序，逐台各自判斷角色
#     並確認前面的節點已關閉），重新開啟 EFM 是等「整個叢集」都升級完成後，
#     才對每台機器分別執行一次 `./upgrader.sh --reopen-efm`。
#   - 大版本：一律從 Primary 開始執行本腳本。角色判斷是用資料目錄下有沒有
#     standby.signal（並與使用者 double check，不符會中止要求手動指定），
#     找不到本機 instance 時會問是不是 Witness。Primary 執行時會用
#     `efm stop-cluster` 一次關閉整個叢集的 EFM（會清空 Allowed Node host
#     list），Standby/Witness 執行時只會檢查「EFM 是否已經是關閉狀態」，不
#     會主動關閉；如果偵測到還在跑，代表 Primary 那邊還沒處理，會直接中止
#     並提示要照順序來。Standby 不會自己對本機資料跑 pg_upgrade，而是等
#     Primary 升級完成後，用 pg_basebackup 整個重建。整個叢集升級完成前，
#     請不要提前重開任何一台機器的 EFM，全部完成後對每台機器分別執行
#     `./upgrader.sh --reopen-efm`（如果剛剛是用 stop-cluster 關的，這裡也
#     會提示要不要重新把節點加回 Allowed Node host list）。
#
# 用法：
#   ./upgrader.sh                跑一次完整的升級互動流程
#   ./upgrader.sh --reopen-efm   整個叢集升級完成後，在每台機器上
#                                個別執行，重新開啟本機的 EFM 監控
#   ./upgrader.sh -h|--help      顯示這段說明
#
set -uo pipefail

########################################
# 設定區（可依現場需求調整）
########################################
DB_OS_USER="enterprisedb"                 # 資料庫程序的 OS 使用者
LOGFILE="./upgrader_$(date +%Y%m%d_%H%M%S).log"

########################################
# 顏色（僅在有 tty 時使用）
########################################
if [ -t 1 ]; then
  C_CYAN='\033[0;36m'
  C_YELLOW='\033[1;33m'
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_NC='\033[0m'
else
  C_CYAN=''; C_YELLOW=''; C_RED=''; C_GREEN=''; C_NC=''
fi

########################################
# 基礎工具函式
########################################

# log <訊息>：印到畫面（有顏色）並同步寫進 LOGFILE（純文字，帶時間戳）
log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="[$ts] $*"
  echo -e "${C_CYAN}${msg}${C_NC}"
  echo "$msg" >> "$LOGFILE"
}

warn() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="[$ts] [警告] $*"
  echo -e "${C_YELLOW}${msg}${C_NC}"
  echo "$msg" >> "$LOGFILE"
}

err() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="[$ts] [錯誤] $*"
  echo -e "${C_RED}${msg}${C_NC}"
  echo "$msg" >> "$LOGFILE"
}

# confirm <提示文字>：回傳 0 表示使用者同意，回傳 1 表示不同意/取消。
# 使用者可以隨時輸入 --show-logs 查看目前為止的完整 log，看完會重新詢問。
confirm() {
  local prompt="$1" ans
  while true; do
    read -rp "$(echo -e "${C_YELLOW}${prompt} [y/N，輸入 --show-logs 可查看目前日誌]: ${C_NC}")" ans
    case "$ans" in
      --show-logs|--show-log|logs|log)
        echo "===================== LOG START ($LOGFILE) ====================="
        cat "$LOGFILE" 2>/dev/null
        echo "====================== LOG END ======================"
        continue
        ;;
      y|Y|yes|Yes|YES)
        log "使用者確認「${prompt}」-> 同意"
        return 0
        ;;
      *)
        log "使用者確認「${prompt}」-> 不同意/取消"
        return 1
        ;;
    esac
  done
}

# run_and_log <指令...>：印出即將執行的指令、即時串流輸出到畫面同時寫進
# log，回傳指令實際的 exit code。
run_and_log() {
  log "\$ $*"
  "$@" 2>&1 | tee -a "$LOGFILE"
  local status="${PIPESTATUS[0]}"
  if [ "$status" -ne 0 ]; then
    err "指令失敗，exit code $status：$*"
  fi
  return "$status"
}

# run_as_db_user <指令...>：以資料庫 OS 使用者身份執行，其餘同 run_and_log。
run_as_db_user() {
  log "\$ (以 $DB_OS_USER 身份) $*"
  sudo -u "$DB_OS_USER" "$@" 2>&1 | tee -a "$LOGFILE"
  local status="${PIPESTATUS[0]}"
  if [ "$status" -ne 0 ]; then
    err "指令失敗，exit code $status：(以 $DB_OS_USER 身份) $*"
  fi
  return "$status"
}

# run_as_db_user_in_dir <目錄> <指令...>：跟 run_as_db_user 一樣，但先切換到
# 指定目錄再執行。pg_upgrade 需要在自己有讀寫權限的「當前工作目錄」下執行
# （用來放 pg_upgrade_output.d 等記錄），單純 sudo -u 不會變更工作目錄，如果
# 腳本本身是在 $DB_OS_USER 沒有寫入權限的目錄下跑的（例如 root 常待的目錄），
# pg_upgrade 一開始就會直接失敗，錯誤訊息是「You must have read and write
# access in the current directory.」，要另外處理。
run_as_db_user_in_dir() {
  local dir="$1"; shift
  log "\$ (以 $DB_OS_USER 身份，於 $dir) $*"
  sudo -u "$DB_OS_USER" bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@" 2>&1 | tee -a "$LOGFILE"
  local status="${PIPESTATUS[0]}"
  if [ "$status" -ne 0 ]; then
    err "指令失敗，exit code $status：(以 $DB_OS_USER 身份，於 $dir) $*"
  fi
  return "$status"
}

print_usage() {
  cat <<'EOF'
upgrader.sh — EDB Postgres Advanced Server 升級互動工具
Designer: Reamer

用法：
  ./upgrader.sh                跑一次完整的升級互動流程
  ./upgrader.sh --reopen-efm   整個叢集升級完成後，在每台機器上
                               個別執行，重新開啟本機的 EFM 監控
  ./upgrader.sh -h|--help      顯示這段說明

整個流程進行中，任何一個確認提示都可以輸入 --show-logs 查看目前為止的
完整日誌內容。日誌會即時寫在當前目錄下一個帶時間戳記的檔案裡，就算腳本
中途中斷，日誌也已經落地可查。

如果某一步失敗（指令出錯，或不小心按錯了某個確認），不會直接整支腳本
結束——會問你要「重試這一步」還是「中止整個流程」，重試的話這一步的
所有提示/參數都會重新問一次，前面已經完成的步驟不會受影響。
EOF
}

# run_step <step 函式名稱>：main flow 唯一呼叫 step 函式的方式，不要直接呼叫
# step_xxx。這是整支腳本「失敗不整個退出」的核心機制：
#   - 每個 step 函式內部原本會 exit 1 的地方，現在全部改成 return 1
#     （包括真的執行失敗、以及使用者在某個 confirm 上選擇不同意/取消）。
#   - run_step 呼叫該函式後，如果拿到非 0 的回傳值，不會讓整支腳本跟著結束，
#     而是問使用者要「重試這一步」還是「中止整個流程」。
#   - 選重試的話，會重新呼叫同一個函式，函式裡所有的 read/confirm 都會重新
#     問一次，等於這一步的所有參數都可以重新輸入，前面已經做完的步驟
#     （已經 dnf install、已經 initdb...）完全不受影響，不用整支腳本重跑。
#   - 只有使用者自己明確選「中止整個流程」，才會真的呼叫 exit。
run_step() {
  local step_func="$1"
  local rc
  while true; do
    "$step_func"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    warn "「$step_func」這一步沒有成功完成（exit code $rc）——可能是指令執行失敗，也可能是某個確認選了不同意/取消。前面已經完成的步驟不會受影響，你可以先去處理完問題（例如修正權限、清出磁碟空間、確認網路等）再回來重試。"
    local choice
    read -rp "要 (r) 重新做這一步（所有參數都可以重新輸入）、還是 (a) 中止整個流程？[r/a，直接 Enter 預設 r]: " choice
    case "$choice" in
      a|A)
        err "使用者選擇中止整個流程（在步驟「$step_func」）。"
        exit 1
        ;;
      *)
        log "使用者選擇重試這一步：$step_func"
        ;;
    esac
  done
}

final_exit_log() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    warn "腳本以非正常狀態結束 (exit code $code)，請查看以上（或 $LOGFILE）日誌確認執行到哪個步驟。"
  else
    log "腳本正常結束。"
  fi
}

########################################
# Step: 掃描目前正在跑的 EDB instance
########################################
# 掃描結果存放在下列平行陣列
PIDS=(); DATADIRS=(); PORTS=(); VERSIONS=(); MAJORS=(); EXEPATHS=()

scan_instances() {
  PIDS=(); DATADIRS=(); PORTS=(); VERSIONS=(); MAJORS=(); EXEPATHS=()
  local pid rest exe datadir port ver major
  while read -r pid rest; do
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
    [ -z "$exe" ] && continue
    datadir=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -oP '(?<=-D )\S+')
    [ -z "$datadir" ] && continue
    port=$(sed -n '4p' "$datadir/postmaster.pid" 2>/dev/null)
    ver=$("$exe" --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    major=$(echo "$exe" | grep -oP '(?<=/as)[0-9]+' | head -1)
    PIDS+=("$pid")
    DATADIRS+=("$datadir")
    PORTS+=("${port:-未知}")
    VERSIONS+=("${ver:-未知}")
    MAJORS+=("${major:-未知}")
    EXEPATHS+=("$exe")
  done < <(ps --no-headers -eo pid,cmd 2>/dev/null | grep -E '/bin/edb-postgres( |$).*-D ' | grep -v grep)
}

print_instances() {
  local i
  for i in "${!PIDS[@]}"; do
    printf "  %d) PID=%-8s 版本=%-8s Port=%-6s Major=as%-4s 資料目錄=%s\n" \
      "$((i + 1))" "${PIDS[$i]}" "${VERSIONS[$i]}" "${PORTS[$i]}" "${MAJORS[$i]}" "${DATADIRS[$i]}"
  done
}

########################################
# 主流程各步驟
########################################

UPGRADE_MODE="minor"

step_choose_major_or_minor() {
  echo
  echo "===== Step 1：這次要做什麼？ ====="
  echo "  1) 小版本升級 (Minor)"
  echo "  2) 大版本升級 (Major)"
  echo "  3) 純安裝新 instance（不牽涉任何舊 instance 升級）"
  local choice
  read -rp "請選擇 [1/2/3]: " choice
  case "$choice" in
    1) UPGRADE_MODE="minor"; log "使用者選擇：小版本升級" ;;
    2) UPGRADE_MODE="major"; log "使用者選擇：大版本升級" ;;
    3) UPGRADE_MODE="install"; log "使用者選擇：純安裝新 instance" ;;
    *)
      err "無效選擇：$choice"
      return 1
      ;;
  esac
}

TARGET_PID=""; TARGET_DATADIR=""; TARGET_PORT=""; TARGET_MAJOR=""; TARGET_EXE=""
TARGET_VERSION=""
# TARGET_VERSION_NUM：TARGET_VERSION 去掉 rpm release/dist 標籤（例如
# "17.5.0-1.el9" 去掉 "-1.el9"）之後的純數字版本號，例如 "17.5.0"。
# 使用者明確要求過：程式裡任何會用到版本號的地方（repo id、資料目錄名稱、
# systemd service 後綴、replication slot 名稱...）都要盡量寫到完整的
# minor/point 版本，不要只寫大版本號，避免同一台機器上出現好幾個只憑
# 「as17」這種大版本名稱區分不出來、實際上是不同版本/不同用途的資料夾或
# service，事後debug 時搞混（這是真實踩過的坑）。這個變數統一在
# step_select_version_and_write_repo() 選定版本後算好，後面所有會用到
# 「版本號」的地方都應該優先用這個，而不是只用 TARGET_MAJOR/NEW_MAJOR。
TARGET_VERSION_NUM=""
SYSTEMD_TRACKED=false
SERVICE_NAME=""

step_select_instance() {
  echo
  echo "===== Step 2：掃描目前正在跑的 EDB instance ====="
  scan_instances
  if [ "${#PIDS[@]}" -eq 0 ]; then
    err "目前這台機器上沒有偵測到任何正在跑的 edb-postgres process，無法繼續。"
    return 1
  fi
  echo "偵測到以下 instance："
  print_instances
  log "共偵測到 ${#PIDS[@]} 個 instance"

  local sel idx
  while true; do
    read -rp "請輸入要處理的 instance 編號: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#PIDS[@]}" ]; then
      idx=$((sel - 1))
      break
    fi
    echo "輸入無效，請重新輸入。"
  done

  TARGET_PID="${PIDS[$idx]}"
  TARGET_DATADIR="${DATADIRS[$idx]}"
  TARGET_PORT="${PORTS[$idx]}"
  TARGET_MAJOR="${MAJORS[$idx]}"
  TARGET_EXE="${EXEPATHS[$idx]}"

  if [ "$TARGET_MAJOR" = "未知" ]; then
    err "無法從 binary 路徑判斷大版本號 ($TARGET_EXE)，無法繼續。"
    return 1
  fi

  log "已選擇目標 instance：PID=$TARGET_PID 資料目錄=$TARGET_DATADIR Port=$TARGET_PORT Major=as${TARGET_MAJOR}"

  # 目標版本號不在這裡問——要先看離線套件包裡實際打包了什麼版本,
  # 才知道有哪些版本可以選,見 step_prepare_offline_repo()。
  SERVICE_NAME="edb-as-${TARGET_MAJOR}.service"
  local mainpid
  mainpid=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || echo 0)
  if [ "$mainpid" = "$TARGET_PID" ]; then
    SYSTEMD_TRACKED=true
    log "確認：$SERVICE_NAME 的 Main PID ($mainpid) 與目標 PID 相符，這個 instance 是在 systemd 管理下。"
  else
    SYSTEMD_TRACKED=false
    warn "$SERVICE_NAME 目前的 Main PID 是「$mainpid」，跟目標 PID ($TARGET_PID) 對不上——這個 instance 不在 systemd 追蹤範圍內（可能是被手動用 pg_ctl 啟動的）。後面重啟時會改用手動停止再交給 systemctl start 接手的方式，不會直接用 systemctl restart。"
  fi
}

########################################
# 驗證 + 解壓縮離線套件包，並從實際內容決定可升級版本
########################################
HOST_OS_TAG=""; HOST_ARCH=""
EXTRACT_DIR=""
REPO_ID=""
REPO_FILE=""

# detect_host_os_arch：判斷這台機器自己是 el8/el9、x86_64/aarch64，
# 用來在解壓出來的離線套件包裡挑出對應這台機器的那個子目錄。
detect_host_os_arch() {
  HOST_ARCH=$(uname -m)
  local rhel_ver
  rhel_ver=$(rpm -E %{rhel} 2>/dev/null)
  if [ -n "$rhel_ver" ] && [ "$rhel_ver" != "%{rhel}" ]; then
    HOST_OS_TAG="el${rhel_ver}"
  else
    HOST_OS_TAG=""
  fi
}

step_extract_and_verify_archive() {
  echo
  echo "===== 驗證/解壓縮離線套件包 ====="

  detect_host_os_arch
  if [ -z "$HOST_OS_TAG" ]; then
    err "偵測不到這台機器的 OS 大版本（rpm -E %{rhel} 失敗），無法繼續。"
    return 1
  fi
  log "偵測到本機環境：OS=${HOST_OS_TAG} 架構=${HOST_ARCH}"

  # 1) 先找到要用哪個離線套件包（tar.gz）
  local -a candidates
  mapfile -t candidates < <(ls -1 ./edb_offline_repo_*.tar.gz 2>/dev/null)

  local archive_path input
  if [ "${#candidates[@]}" -eq 1 ]; then
    log "偵測到離線套件包：${candidates[0]}"
    read -rp "使用這個檔案嗎？直接 Enter 使用，或輸入其他路徑: " input
    archive_path="${input:-${candidates[0]}}"
  elif [ "${#candidates[@]}" -gt 1 ]; then
    echo "偵測到目前目錄下有多個離線套件包："
    local i
    for i in "${!candidates[@]}"; do
      printf "  %d) %s\n" "$((i + 1))" "${candidates[$i]}"
    done
    read -rp "請輸入編號，或直接輸入完整路徑: " input
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#candidates[@]}" ]; then
      archive_path="${candidates[$((input - 1))]}"
    else
      archive_path="$input"
    fi
  else
    read -rp "找不到目前目錄下的離線套件包，請輸入完整路徑: " archive_path
  fi

  if [ -z "$archive_path" ] || [ ! -f "$archive_path" ]; then
    err "找不到檔案：$archive_path"
    return 1
  fi
  log "使用離線套件包：$archive_path"

  # 2) 驗證 sha256（有校驗檔才驗，沒有就警告一下讓使用者自己決定要不要繼續）
  local sha_path="${archive_path}.sha256"
  if [ -f "$sha_path" ]; then
    log "找到校驗檔 $sha_path，驗證中..."
    if run_and_log sha256sum -c "$sha_path"; then
      log "sha256 驗證通過。"
    else
      err "sha256 驗證失敗，這個檔案很可能在搬運過程中壞掉了，請重新搬運這個檔案。"
      return 1
    fi
  else
    warn "找不到對應的校驗檔 $sha_path，沒辦法驗證這個檔案的完整性。"
    confirm "沒有校驗檔，確定仍要繼續解壓縮這個檔案嗎？" || { log "使用者取消。"; return 1; }
  fi

  # 3) 解壓縮
  EXTRACT_DIR="./upgrader_extract_$(date +%Y%m%d_%H%M%S)"
  confirm "確認要把 $archive_path 解壓縮到 $EXTRACT_DIR 嗎？" || { log "使用者取消。"; return 1; }
  mkdir -p "$EXTRACT_DIR"
  run_and_log tar -xzf "$archive_path" -C "$EXTRACT_DIR" || { err "解壓縮失敗。"; return 1; }
}

# step_select_major_from_repo：只在大版本升級流程使用。解壓縮完成後，掃描
# 套件包裡實際打包了哪些大版本（<os>/<arch>/edb-as<N> 目錄），列成選項讓
# 使用者選，不要在還沒看到套件包內容前就叫使用者用打字的猜一個大版本號。
step_select_major_from_repo() {
  echo
  echo "===== 選擇目標大版本 ====="
  local -a major_dirs majors
  mapfile -t major_dirs < <(find "$EXTRACT_DIR" -type d -path "*/${HOST_OS_TAG}/${HOST_ARCH}/edb-as*" 2>/dev/null | sort -V)

  if [ "${#major_dirs[@]}" -eq 0 ]; then
    err "解壓縮後找不到符合這台機器 (${HOST_OS_TAG}/${HOST_ARCH}) 的任何 edb-as<版本> 目錄，這個離線套件包可能沒有打包到這台機器需要的組合。"
    return 1
  fi
  mapfile -t majors < <(printf '%s\n' "${major_dirs[@]}" | grep -oP 'edb-as\K[0-9]+' | sort -Vu)

  echo "這個離線套件包裡（${HOST_OS_TAG}/${HOST_ARCH}），有打包以下大版本："
  local i
  for i in "${!majors[@]}"; do
    printf "  %d) as%s\n" "$((i + 1))" "${majors[$i]}"
  done

  local sel idx
  while true; do
    read -rp "請輸入要升級到的目標大版本編號: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#majors[@]}" ]; then
      idx=$((sel - 1))
      break
    fi
    echo "輸入無效，請重新輸入。"
  done
  NEW_MAJOR="${majors[$idx]}"
  TARGET_MAJOR="$NEW_MAJOR"
  log "選擇的目標大版本：as${NEW_MAJOR}"
}

step_select_version_and_write_repo() {
  echo
  echo "===== 選擇要升級的版本 ====="

  # 解壓出來的結構是 <run_dir 名稱>/<os>/<arch>/edb-as<版本>/*.rpm，最外層
  # 目錄名稱不固定（打包當下的 spec + 時間戳），所以用 find 找符合
  # <os>/<arch>/edb-as<major> 這個路徑組合的目錄，不管最外層叫什麼名字。
  local combo_dir
  combo_dir=$(find "$EXTRACT_DIR" -type d -path "*/${HOST_OS_TAG}/${HOST_ARCH}/edb-as${TARGET_MAJOR}" 2>/dev/null | head -1)
  if [ -z "$combo_dir" ]; then
    err "解壓縮後找不到符合這台機器 (${HOST_OS_TAG}/${HOST_ARCH}) 跟大版本 (as${TARGET_MAJOR}) 的目錄，這個離線套件包可能沒有打包到你這次需要的組合。"
    return 1
  fi
  log "找到對應的套件目錄：$combo_dir"

  # 4) 從實際的 rpm 檔名列出這個大版本有哪些版本可以選，不要用問的用猜的。
  # 只看 edb-as<major>-server-<版本> 這個核心套件的檔名（排除 -contrib/
  # -client/-llvmjit 等等），避免同一個版本被列出好幾次。
  local -a versions
  mapfile -t versions < <(ls -1 "$combo_dir" 2>/dev/null \
    | grep -E "^edb-as${TARGET_MAJOR}-server-[0-9]" \
    | sed -E "s/^edb-as${TARGET_MAJOR}-server-//; s/\.(x86_64|aarch64|noarch)\.rpm\$//" \
    | sort -Vu)

  if [ "${#versions[@]}" -eq 0 ]; then
    err "在 $combo_dir 底下找不到任何 edb-as${TARGET_MAJOR}-server 的 rpm，無法判斷有哪些版本可以升級。"
    return 1
  fi

  echo "這個離線套件包裡，as${TARGET_MAJOR} 有以下版本可以選擇升級："
  local i
  for i in "${!versions[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${versions[$i]}"
  done

  local vsel vidx
  while true; do
    read -rp "請輸入要升級到的版本編號: " vsel
    if [[ "$vsel" =~ ^[0-9]+$ ]] && [ "$vsel" -ge 1 ] && [ "$vsel" -le "${#versions[@]}" ]; then
      vidx=$((vsel - 1))
      break
    fi
    echo "輸入無效，請重新輸入。"
  done
  TARGET_VERSION="${versions[$vidx]}"
  log "選擇的目標版本：$TARGET_VERSION"

  # TARGET_VERSION_NUM：把 rpm release/dist 標籤（例如 "-1.el9"）去掉，只留
  # 純數字版本號（例如 "17.5.0-1.el9" -> "17.5.0"）。後面所有會用到版本號
  # 命名的地方（repo id、資料目錄、systemd service 後綴、replication slot
  # 名稱）一律用這個，寫到完整的 minor/point 版本，不要只用大版本號，避免
  # 同一台機器上出現好幾個只憑「as17」這種大版本名稱分不出差異、實際上是
  # 不同版本/不同用途的資料夾或 service，事後 debug 時搞混。
  TARGET_VERSION_NUM="${TARGET_VERSION%%-*}"
  if [ -z "$TARGET_VERSION_NUM" ]; then
    warn "無法從版本號 \"$TARGET_VERSION\" 解析出純數字版本號，相關命名暫時退回用大版本號。"
    TARGET_VERSION_NUM="${TARGET_MAJOR}"
  fi
  log "本次用於命名（repo id/資料目錄/service 後綴/slot 名稱）的版本號：$TARGET_VERSION_NUM"

  # 5) 設定/寫入 repo 檔案，baseurl 直接指向剛剛解壓出來的目錄，
  # 不用再手動輸入路徑。repo id 命名是 edb<大版本>-<完整版本號>-offline，
  # 例如目標版本 16.2.0-1.el9 對應到 edb16-16.2.0-offline，寫到完整版本號
  # 而不是只取一位小版本數字，避免 repo id 分不出 16.2.0 跟 16.2.1 的差別。
  REPO_ID="edb${TARGET_MAJOR}-${TARGET_VERSION_NUM}-offline"
  REPO_FILE="/etc/yum.repos.d/${REPO_ID}.repo"
  local baseurl
  baseurl="file://$(cd "$combo_dir" && pwd)"

  if [ -f "$REPO_FILE" ]; then
    log "偵測到 $REPO_FILE 已存在，內容如下："
    run_and_log cat "$REPO_FILE"
    confirm "要沿用這個既有的 repo 設定，不重新寫入嗎？" && {
      log "沿用既有 repo 檔案：$REPO_FILE"
      return
    }
  fi

  echo "即將寫入 $REPO_FILE，內容如下："
  cat <<EOF
[$REPO_ID]
name=EDB AS ${TARGET_MAJOR} ${TARGET_VERSION_NUM} Offline Repo
baseurl=$baseurl
enabled=0
gpgcheck=0
EOF
  confirm "確認要寫入以上內容到 $REPO_FILE 嗎？" || { log "使用者取消。"; return 1; }

  cat > "$REPO_FILE" <<EOF
[$REPO_ID]
name=EDB AS ${TARGET_MAJOR} ${TARGET_VERSION_NUM} Offline Repo
baseurl=$baseurl
enabled=0
gpgcheck=0
EOF
  log "已寫入 $REPO_FILE"
}

# step_prepare_offline_repo：小版本流程用的組合函式，TARGET_MAJOR 在呼叫
# 前就已經從目前正在跑的 instance 決定好了，所以不需要 step_select_major_from_repo
# 這個選大版本的步驟，直接解壓縮+驗證完就接去選版本、寫 repo。
step_prepare_offline_repo() {
  step_extract_and_verify_archive
  step_select_version_and_write_repo
}

step_warn_siblings() {
  echo
  echo "===== Step 4：檢查同大版本的其他 instance ====="
  local i siblings=()
  for i in "${!PIDS[@]}"; do
    if [ "${MAJORS[$i]}" = "$TARGET_MAJOR" ] && [ "${PIDS[$i]}" != "$TARGET_PID" ]; then
      siblings+=("PID=${PIDS[$i]} 資料目錄=${DATADIRS[$i]} Port=${PORTS[$i]} 目前版本=${VERSIONS[$i]}")
    fi
  done

  if [ "${#siblings[@]}" -eq 0 ]; then
    log "沒有偵測到其他同為 as${TARGET_MAJOR} 的 instance。"
    return
  fi

  warn "偵測到 ${#siblings[@]} 個其他同為 as${TARGET_MAJOR} 的 instance："
  local s
  for s in "${siblings[@]}"; do
    warn "  - $s"
  done
  warn "這次 dnf update 會把 as${TARGET_MAJOR} 共用的 binary 換成 ${TARGET_VERSION}，上面這些其他 instance 的檔案也會一起被換掉，但只有你剛剛選的目標 instance 會在這次流程中被重啟生效。其他 instance 在被個別重啟前仍會繼續用舊版本執行；本工具不會替你處理、也不保證它們之後被重啟時能正常運作，請自行評估、記錄。"

  confirm "了解以上風險，確認要繼續嗎？" || { log "使用者取消流程。"; return 1; }
}

########################################
# EFM 處理
########################################
EFM_SERVICE=""
EFM_CLUSTER="efm"
EFM_BIN=""

find_efm_service() {
  systemctl list-units --all --type=service --no-legend 'edb-efm-*' 2>/dev/null | awk '{print $1}' | head -1
}

find_efm_bin() {
  command -v efm 2>/dev/null && return
  ls /usr/edb/efm-*/bin/efm 2>/dev/null | head -1
}

step_handle_efm() {
  echo
  echo "===== Step 5：檢查 EFM 狀態 ====="
  EFM_SERVICE=$(find_efm_service)
  if [ -z "$EFM_SERVICE" ]; then
    log "未偵測到任何 edb-efm-* 服務，判斷這台機器沒有裝 EFM，略過 EFM 處理。"
    return
  fi
  log "偵測到 EFM 服務：$EFM_SERVICE"

  # 這台機器上有 EFM 在跑，不代表它就是在管「這次要升級的這個 instance」——
  # 同一台機器上可能同時裝了好幾個互不相干的資料庫叢集，各自有各自的 EFM。
  # 先掃 /etc/edb/efm-*/*.properties，看有沒有哪個叢集設定檔的 db.port
  # 剛好等於這個 instance 的 port，用這個自動判斷相不相關，不要每次都
  # 硬把使用者拖進完整的 EFM 流程。
  local -a matched_props=()
  local pf pf_port
  while IFS= read -r pf; do
    [ -z "$pf" ] && continue
    pf_port=$(grep -oP '^\s*db\.port\s*=\s*\K[0-9]+' "$pf" 2>/dev/null | head -1)
    if [ -n "$pf_port" ] && [ "$pf_port" = "$TARGET_PORT" ]; then
      matched_props+=("$pf")
    fi
  done < <(find /etc/edb/efm-*/ -maxdepth 1 -name '*.properties' 2>/dev/null)

  if [ "${#matched_props[@]}" -eq 0 ]; then
    warn "掃描 /etc/edb/efm-*/*.properties，沒有找到任何叢集設定檔的 db.port 跟這個 instance 的 port ($TARGET_PORT) 相符。"
    confirm "判斷這個 EFM 服務跟這次要升級的 instance 無關，要跳過整個 EFM 處理步驟嗎？" && {
      log "使用者確認 EFM 與本次 instance 無關，略過 EFM 處理。"
      return
    }
    warn "使用者選擇不跳過，改為手動輸入叢集名稱繼續往下走。"
    read -rp "EFM 叢集名稱（直接 Enter 預設為 efm）: " input
    EFM_CLUSTER="${input:-efm}"
  elif [ "${#matched_props[@]}" -eq 1 ]; then
    EFM_CLUSTER=$(basename "${matched_props[0]}" .properties)
    log "自動比對 port 相符，判斷這個 instance 屬於 EFM 叢集：$EFM_CLUSTER（設定檔：${matched_props[0]}）"
  else
    warn "有 ${#matched_props[@]} 個叢集設定檔的 db.port 都跟這個 instance 相符，無法自動判斷，請自行確認："
    local mp
    for mp in "${matched_props[@]}"; do warn "  - $mp"; done
    read -rp "EFM 叢集名稱（直接 Enter 預設為 efm）: " input
    EFM_CLUSTER="${input:-efm}"
  fi

  log "使用的 EFM 叢集名稱：$EFM_CLUSTER"

  EFM_BIN=$(find_efm_bin)
  local role=""
  if [ -z "$EFM_BIN" ]; then
    warn "找不到 efm 指令（試過 PATH 跟 /usr/edb/efm-*/bin/efm），無法自動查詢這台機器的角色。"
  else
    role=$("$EFM_BIN" node-status-json "$EFM_CLUSTER" 2>/dev/null | grep -oP '"type"\s*:\s*"\K[^"]+' | head -1)
    log "查詢到本機在叢集 '$EFM_CLUSTER' 中的角色：${role:-無法判斷}"
  fi

  if [ -z "$role" ]; then
    warn "無法自動判斷角色，請自行確認這台機器是 Witness / Standby / Primary 後再繼續。"
    confirm "已手動確認角色與其他節點的 EFM 狀態，是否繼續關閉本機 EFM？" || { log "使用者取消。"; return 1; }
    run_and_log systemctl stop "$EFM_SERVICE" && log "已關閉本機 EFM ($EFM_SERVICE)。" || return 1
    return
  fi

  case "$role" in
    Witness)
      log "本機角色為 Witness。"
      confirm "確認要關閉本機 (Witness) 的 EFM 監控 ($EFM_SERVICE) 嗎？" && {
        run_and_log systemctl stop "$EFM_SERVICE" || return 1
        log "已關閉 Witness 的 EFM。"
      } || { log "使用者選擇不關閉。"; return 1; }
      ;;
    Standby)
      log "本機角色為 Standby。"
      confirm "請先確認 Witness 節點的 EFM 是否已經關閉（尚未關閉請先去處理 Witness）。Witness 已關閉了嗎？" || {
        err "Witness 尚未關閉，請先完成 Witness 的步驟。"
        return 1
      }
      confirm "確認要關閉本機 (Standby) 的 EFM 監控 ($EFM_SERVICE) 嗎？" && {
        run_and_log systemctl stop "$EFM_SERVICE" || return 1
        log "已關閉 Standby 的 EFM。"
      } || { log "使用者選擇不關閉。"; return 1; }
      ;;
    Primary)
      log "本機角色為 Primary。"
      confirm "請先確認 Witness 與『所有』Standby 節點的 EFM 是否都已經關閉。都關閉了嗎？" || {
        err "Witness/Standby 尚未全部關閉。建議的順序是先完成所有 Standby 的升級，最後才處理 Primary。"
        return 1
      }
      confirm "確認要關閉本機 (Primary) 的 EFM 監控 ($EFM_SERVICE) 嗎？" && {
        run_and_log systemctl stop "$EFM_SERVICE" || return 1
        log "已關閉 Primary 的 EFM。"
      } || { log "使用者選擇不關閉。"; return 1; }
      ;;
    *)
      warn "查到的角色 '$role' 不是 Witness/Standby/Primary 其中之一，請自行確認狀態。"
      confirm "已手動確認，是否繼續關閉本機 EFM？" && {
        run_and_log systemctl stop "$EFM_SERVICE" || return 1
      } || { log "使用者取消。"; return 1; }
      ;;
  esac

  warn "提醒：在『整個叢集』(Witness + 所有 Standby + Primary) 全部升級完成前，請不要重開任何一台機器的 EFM。全部完成後，請對每台機器分別執行：$0 --reopen-efm"
}

do_reopen_efm() {
  echo "===== 重新開啟本機 EFM 監控 ====="
  EFM_SERVICE=$(find_efm_service)
  if [ -z "$EFM_SERVICE" ]; then
    echo "本機未偵測到 edb-efm-* 服務，沒有東西需要重開。"
    exit 0
  fi
  log "偵測到 EFM 服務：$EFM_SERVICE"
  confirm "請再次確認：整個叢集(Witness + 所有 Standby + Primary)是否都已完成升級？確認後才會重新開啟本機的 EFM 監控。" && {
    run_and_log systemctl start "$EFM_SERVICE" && log "已重新開啟本機 EFM ($EFM_SERVICE)。"
  } || {
    log "使用者選擇先不重開，結束。"
    exit 0
  }

  confirm "剛才如果是大版本升級、且用了 efm stop-cluster 整叢集關閉，Allowed Node host list 這時候是空的（除非 auto.allow.hosts=true）。要不要現在把其他節點的位址加回白名單？" && {
    EFM_BIN=$(find_efm_bin)
    if [ -z "$EFM_BIN" ]; then
      err "找不到 efm 指令，請自行手動執行 efm allow-node。"
    else
      local ec addr
      read -rp "EFM 叢集名稱（直接 Enter 預設 efm）: " ec
      ec="${ec:-efm}"
      echo "請輸入要加入白名單的節點位址，一行一個，輸入空白行結束："
      while true; do
        read -rp "位址: " addr
        [ -z "$addr" ] && break
        run_and_log "$EFM_BIN" allow-node "$ec" "$addr"
      done
    fi
  }
  exit 0
}

########################################
# dnf list updates + 套件選擇
########################################
SELECTED_PKGS=()

step_list_and_select_packages() {
  echo
  echo "===== Step 6：查詢可更新套件 ====="
  log "查詢 edb-as${TARGET_MAJOR}-* 在 repo '$REPO_ID' 底下可更新的套件..."
  run_and_log dnf list updates --disablerepo='*' --enablerepo="$REPO_ID" "edb-as${TARGET_MAJOR}-*"

  local -a available
  mapfile -t available < <(dnf list updates --disablerepo='*' --enablerepo="$REPO_ID" "edb-as${TARGET_MAJOR}-*" 2>/dev/null | awk '$1 ~ /^edb-as/ {print $1}')

  if [ "${#available[@]}" -eq 0 ]; then
    err "沒有查到任何可更新的套件，請確認 repo 設定、版本號是否正確。"
    return 1
  fi

  echo "偵測到以下可更新套件（核心套件與 extension 套件都列在一起）："
  local i
  for i in "${!available[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${available[$i]}"
  done

  read -rp "請輸入要更新的套件編號（空白分隔多個，直接 Enter 代表全部更新）: " sel
  SELECTED_PKGS=()
  if [ -z "$sel" ]; then
    SELECTED_PKGS=("${available[@]}")
  else
    local n
    for n in $sel; do
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#available[@]}" ]; then
        SELECTED_PKGS+=("${available[$((n - 1))]}")
      fi
    done
  fi

  if [ "${#SELECTED_PKGS[@]}" -eq 0 ]; then
    err "沒有選擇任何套件。"
    return 1
  fi

  log "本次選擇更新的套件：${SELECTED_PKGS[*]}"
}

step_dnf_update() {
  echo
  echo "===== Step 7：執行 dnf update ====="
  echo "即將執行："
  echo "  dnf update -y --disablerepo='*' --enablerepo=\"$REPO_ID\" \\"
  local i last=$(( ${#SELECTED_PKGS[@]} - 1 ))
  for i in "${!SELECTED_PKGS[@]}"; do
    if [ "$i" -eq "$last" ]; then
      echo "    ${SELECTED_PKGS[$i]}"
    else
      echo "    ${SELECTED_PKGS[$i]} \\"
    fi
  done
  confirm "確認要執行以上更新嗎？" || { log "使用者取消。"; return 1; }
  run_and_log dnf update -y --disablerepo='*' --enablerepo="$REPO_ID" "${SELECTED_PKGS[@]}" || {
    err "dnf update 失敗。"
    return 1
  }
}

########################################
# 重啟
########################################
step_restart() {
  echo
  echo "===== Step 8：重啟服務 ====="
  if [ "$SYSTEMD_TRACKED" = true ]; then
    log "此 instance 由 systemd 追蹤（$SERVICE_NAME），將使用 systemctl restart。"
    confirm "確認執行 systemctl restart $SERVICE_NAME ？" && {
      run_and_log systemctl restart "$SERVICE_NAME" || return 1
    } || { log "使用者取消重啟。"; return 1; }
    return
  fi

  warn "此 instance 不在 systemd 追蹤範圍內，將採用：先手動停止，再改由 systemctl start 接手的方式。"
  confirm "確認對資料目錄 $TARGET_DATADIR 執行 pg_ctl stop -m fast（以 $DB_OS_USER 身份）嗎？" || {
    log "使用者取消。"
    return 1
  }
  run_as_db_user pg_ctl stop -D "$TARGET_DATADIR" -m fast

  log "確認 PID $TARGET_PID 是否已經停止..."
  local i stopped=false
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! ps -p "$TARGET_PID" > /dev/null 2>&1; then
      stopped=true
      break
    fi
    sleep 2
  done

  if [ "$stopped" = false ]; then
    err "PID $TARGET_PID 在等待後仍在執行，可能停止失敗，請手動確認狀態。"
    return 1
  fi
  log "已確認 PID $TARGET_PID 已停止。"

  local unit_pgdata
  unit_pgdata=$(systemctl show -p Environment --value "$SERVICE_NAME" 2>/dev/null | grep -oP 'PGDATA=\K\S+')
  if [ -n "$unit_pgdata" ] && [ "$unit_pgdata" != "$TARGET_DATADIR" ]; then
    warn "systemd unit ($SERVICE_NAME) 設定的資料目錄是「$unit_pgdata」，跟目標資料目錄「$TARGET_DATADIR」不一致！直接 systemctl start 有可能啟動到錯誤的 instance。"
    confirm "確定仍要執行 systemctl start $SERVICE_NAME 嗎？" || {
      err "使用者中止。目標 instance 目前處於已停止狀態，請自行以正確方式手動啟動（例如 pg_ctl start -D $TARGET_DATADIR）。"
      return 1
    }
  fi

  confirm "確認執行 systemctl start $SERVICE_NAME ？" && {
    run_and_log systemctl start "$SERVICE_NAME" || return 1
  } || {
    err "使用者取消。目標 instance 目前處於已停止狀態，請自行手動啟動。"
    return 1
  }
}

########################################
# 驗證：systemctl status / psql 版本 / 複寫狀況
########################################
PSQL_PORT=""; PSQL_DB=""; PSQL_USER=""; PSQL_PASSWORD=""

psql_query() {
  local sql="$1"
  if [ -n "$PSQL_PASSWORD" ]; then
    PGPASSWORD="$PSQL_PASSWORD" psql -h 127.0.0.1 -p "$PSQL_PORT" -d "$PSQL_DB" -U "$PSQL_USER" -tAc "$sql" 2>>"$LOGFILE"
  else
    psql -h 127.0.0.1 -p "$PSQL_PORT" -d "$PSQL_DB" -U "$PSQL_USER" -tAc "$sql" 2>>"$LOGFILE"
  fi
}

psql_show() {
  local sql="$1"
  if [ -n "$PSQL_PASSWORD" ]; then
    PGPASSWORD="$PSQL_PASSWORD" psql -h 127.0.0.1 -p "$PSQL_PORT" -d "$PSQL_DB" -U "$PSQL_USER" -c "$sql" 2>&1 | tee -a "$LOGFILE"
  else
    psql -h 127.0.0.1 -p "$PSQL_PORT" -d "$PSQL_DB" -U "$PSQL_USER" -c "$sql" 2>&1 | tee -a "$LOGFILE"
  fi
}

step_verify() {
  echo
  echo "===== Step 9：驗證結果 ====="
  run_and_log systemctl status "$SERVICE_NAME" --no-pager

  read -rp "psql port（直接 Enter 預設 ${TARGET_PORT}）: " input
  PSQL_PORT="${input:-$TARGET_PORT}"
  read -rp "psql db（直接 Enter 預設 edb）: " input
  PSQL_DB="${input:-edb}"
  read -rp "psql user（直接 Enter 預設 enterprisedb）: " input
  PSQL_USER="${input:-enterprisedb}"
  read -rsp "psql password（直接 Enter 代表無密碼）: " PSQL_PASSWORD
  echo

  log "連線確認目前版本..."
  local ver
  ver=$(psql_query "SELECT version();")
  if [ -z "$ver" ]; then
    err "無法連線查詢版本，請確認 port/db/user/密碼是否正確、pg_hba.conf 是否允許這種連線方式。"
  else
    log "目前實際回報版本：$ver"
  fi

  local is_standby
  is_standby=$(psql_query "SELECT pg_is_in_recovery();")
  if [ "$is_standby" = "t" ]; then
    log "本機為 standby，檢查複寫狀態..."
    psql_show "SELECT status, last_msg_receipt_time FROM pg_stat_wal_receiver;"
  fi
}

########################################
# extension 版本校正
########################################
step_extension_reconcile() {
  local core_pkgs="edb-as${TARGET_MAJOR}-server edb-as${TARGET_MAJOR}-server-contrib edb-as${TARGET_MAJOR}-server-client edb-as${TARGET_MAJOR}-server-llvmjit"
  local -a ext_updated=()
  local p is_core
  for p in "${SELECTED_PKGS[@]}"; do
    is_core=false
    local c
    for c in $core_pkgs; do
      [ "$p" = "$c" ] && is_core=true && break
    done
    [ "$is_core" = false ] && ext_updated+=("$p")
  done

  if [ "${#ext_updated[@]}" -eq 0 ]; then
    log "這次沒有更新到額外的 extension 套件，略過版本校正。"
    return
  fi

  echo
  echo "===== extension 版本校正 ====="
  warn "這次有更新以下 extension 相關套件，資料庫內部登記的版本可能需要用 ALTER EXTENSION ... UPDATE; 才會更新："
  local e
  for e in "${ext_updated[@]}"; do
    warn "  - $e"
  done

  confirm "是否現在連進資料庫查看目前已安裝的 extension 版本 (\\dx)？" && {
    psql_show "\dx"
  }

  # 直接用查詢找出「Version 跟 Default version 真的不符」的 extension，這樣
  # 直接 Enter 才有意義（全部更新），不然使用者每次都得照著 \dx 的畫面手key
  # 名字，而且跟腳本其他地方「直接 Enter 代表全部」的習慣不一致。
  log "查詢實際版本不符（Version != Default version）的 extension..."
  local -a mismatched
  mapfile -t mismatched < <(psql_query "SELECT name FROM pg_available_extensions WHERE installed_version IS NOT NULL AND installed_version <> default_version ORDER BY name;")

  if [ "${#mismatched[@]}" -eq 0 ]; then
    log "查詢結果：目前沒有 Version 跟 Default version 不符的 extension，不需要執行 ALTER EXTENSION UPDATE。"
    return
  fi

  echo "偵測到以下 extension 目前的 Version 跟 Default version 不符："
  local i
  for i in "${!mismatched[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${mismatched[$i]}"
  done

  local ext_names
  read -rp "請輸入要執行 ALTER EXTENSION ... UPDATE; 的 extension 名稱（空白分隔多個；直接 Enter 更新以上全部；輸入 skip 全部略過）: " ext_names

  if [ "$ext_names" = "skip" ]; then
    log "使用者選擇全部略過，不執行 ALTER EXTENSION UPDATE。"
    return
  fi

  local -a to_update
  if [ -z "$ext_names" ]; then
    to_update=("${mismatched[@]}")
    log "使用者未輸入，預設更新以上偵測到的全部 extension：${to_update[*]}"
  else
    to_update=($ext_names)
  fi

  local en
  for en in "${to_update[@]}"; do
    confirm "確認執行 ALTER EXTENSION $en UPDATE; ？" && {
      psql_show "ALTER EXTENSION $en UPDATE;"
    }
  done
}

########################################
# 大版本升級流程
########################################
# 一律從 Primary 開始執行本腳本。角色偵測用 standby.signal 檔案是否存在
# 判斷，並與使用者 double check；找不到本機 instance 時問是不是 Witness。
# Primary 負責用 efm stop-cluster 一次關掉整個叢集的 EFM，Standby/Witness
# 只檢查「是否已經是關閉狀態」，不主動關閉，順序不對就直接中止。
# Standby 不會對自己的舊資料跑 pg_upgrade，而是等 Primary 升級完成後用
# pg_basebackup 整個重建。

NEW_MAJOR=""
NODE_ROLE=""
OLD_PID=""; OLD_DATADIR=""; OLD_PORT=""; OLD_MAJOR=""; OLD_EXE=""; OLD_VERSION=""
OLD_SYSTEMD_TRACKED=false; OLD_SERVICE_NAME=""
NEW_DATADIR=""; NEW_PORT=""; NEW_SERVICE_NAME=""
EFM_STOPPED_BY_ME=false
REPL_SLOT_NAME=""
PGU_WORKDIR=""
PGU_MODE=""
INSTALL_PURPOSE=""

step_install_choose_purpose() {
  echo
  echo "===== 這次安裝的目的？ ====="
  echo "  1) 測試/暫時用途"
  echo "  2) 正式環境"
  local choice
  read -rp "請選擇 [1/2]: " choice
  case "$choice" in
    1) INSTALL_PURPOSE="test"; log "使用者選擇：測試/暫時用途安裝。" ;;
    2) INSTALL_PURPOSE="production"; log "使用者選擇：正式環境安裝。" ;;
    *)
      err "無效選擇：$choice"
      return 1
      ;;
  esac
}

step_install_choose_role() {
  echo
  echo "===== 這台要安裝成什麼角色？ ====="
  echo "  1) 全新獨立 instance（initdb）"
  echo "  2) 某個既有 Primary 的 Standby（pg_basebackup）"
  local choice
  read -rp "請選擇 [1/2]: " choice
  case "$choice" in
    1) NODE_ROLE="primary"; log "使用者選擇：全新獨立 instance（initdb）。" ;;
    2) NODE_ROLE="standby"; log "使用者選擇：安裝成 Standby（pg_basebackup）。" ;;
    *)
      err "無效選擇：$choice"
      return 1
      ;;
  esac
}

step_install_wrapup() {
  echo
  echo "===== 收尾 ====="
  if [ "$INSTALL_PURPOSE" = "production" ]; then
    warn "正式環境安裝提醒：記得接上 Barman/pgBackRest 備份、PEM 或其他監控，並把這台 instance 登記進你們的資產/HA 清單。若需要納入 EFM cluster，那部分不在本工具範圍內，請照現有流程手動處理。pg_hba.conf 的認證方式也建議自行檢查是否符合你們正式環境的規範。"
  else
    warn "測試/暫時安裝提醒：這台是拋棄式的，測完記得清理資料目錄（$NEW_DATADIR）、systemd unit（$NEW_SERVICE_NAME）、firewall 開放的 port（$NEW_PORT），避免留著造成日後混淆。"
  fi
  log "本次安裝流程已全部完成。"
}

step_major_select_instance_and_role() {
  echo
  echo "===== Step 2：掃描本機 instance、判斷角色 ====="
  scan_instances
  if [ "${#PIDS[@]}" -eq 0 ]; then
    warn "這台機器上沒有偵測到任何正在跑的 edb-postgres process。"
    confirm "這台機器是不含資料庫的 Witness 節點嗎？" && {
      NODE_ROLE="witness"
      log "使用者確認：本機為 Witness 節點，不含資料庫，後面會跳過所有資料庫相關步驟。"
      return
    }
    err "既不是偵測到的 instance，也不是 Witness，這台機器沒有東西可以升級。"
    return 1
  fi

  echo "偵測到以下 instance："
  print_instances
  local sel idx
  while true; do
    read -rp "請輸入要升級的 instance 編號: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#PIDS[@]}" ]; then
      idx=$((sel - 1))
      break
    fi
    echo "輸入無效，請重新輸入。"
  done

  OLD_PID="${PIDS[$idx]}"; OLD_DATADIR="${DATADIRS[$idx]}"; OLD_PORT="${PORTS[$idx]}"
  OLD_MAJOR="${MAJORS[$idx]}"; OLD_EXE="${EXEPATHS[$idx]}"; OLD_VERSION="${VERSIONS[$idx]}"

  if [ "$OLD_MAJOR" = "未知" ]; then
    err "無法判斷這個 instance 的大版本號，無法繼續。"
    return 1
  fi
  log "已選擇要升級的 instance：PID=$OLD_PID 資料目錄=$OLD_DATADIR Port=$OLD_PORT 目前大版本=as${OLD_MAJOR} 版本=$OLD_VERSION"

  # 跟小版本流程一樣的判斷方式：比對 systemd 認得的 MainPID 是不是真的等於
  # 這個 PID，等一下要停舊 cluster 時才知道能不能安全用 systemctl stop，
  # 還是只能退回用 pg_ctl stop（例如被人手動用 pg_ctl 啟動、systemd 沒追蹤到）。
  OLD_SERVICE_NAME="edb-as-${OLD_MAJOR}.service"
  local old_mainpid
  old_mainpid=$(systemctl show -p MainPID --value "$OLD_SERVICE_NAME" 2>/dev/null || echo 0)
  if [ "$old_mainpid" = "$OLD_PID" ]; then
    OLD_SYSTEMD_TRACKED=true
    log "確認：$OLD_SERVICE_NAME 的 Main PID ($old_mainpid) 與目標 PID 相符，這個 instance 在 systemd 管理下，等一下停止舊 cluster 時會用 systemctl stop。"
  else
    OLD_SYSTEMD_TRACKED=false
    warn "$OLD_SERVICE_NAME 目前的 Main PID 是「$old_mainpid」，跟目標 PID ($OLD_PID) 對不上，這個 instance 不在 systemd 追蹤範圍內。等一下停止舊 cluster 時會改用 pg_ctl stop（以 $DB_OS_USER 身份）。"
  fi

  if [ "$OLD_MAJOR" -ge "$NEW_MAJOR" ] 2>/dev/null; then
    warn "目前版本 as${OLD_MAJOR} 已經 >= 目標大版本 as${NEW_MAJOR}，這不像是常見的升級方向，請確認選擇是否正確。"
    confirm "確定要繼續嗎？" || { log "使用者取消。"; return 1; }
  fi

  local detected="primary"
  if [ -f "$OLD_DATADIR/standby.signal" ]; then
    detected="standby"
  fi
  log "偵測方式：檢查 $OLD_DATADIR/standby.signal 是否存在 -> $([ "$detected" = standby ] && echo 存在 || echo 不存在)，初步判斷角色為：$detected"
  echo "偵測到本機角色為：$detected"

  confirm "這個判斷正確嗎？" && {
    NODE_ROLE="$detected"
  } || {
    warn "偵測結果與使用者認知不符。這種不一致很可能代表操作有問題（例如選錯 instance），請先自行確認清楚。"
    local manual
    read -rp "如果要強制手動指定角色，請輸入 primary 或 standby（直接 Enter 放棄手動指定）: " manual
    case "$manual" in
      primary|standby)
        NODE_ROLE="$manual"
        warn "使用者手動覆寫角色為：$NODE_ROLE（跳過自動偵測結果，風險請自行承擔）"
        ;;
      *)
        err "使用者沒有手動指定角色，這一步無法繼續。"
        return 1
        ;;
    esac
  }
  log "本機角色確認為：$NODE_ROLE"

  if [ "$NODE_ROLE" = "primary" ]; then
    warn "大版本升級規定一律從 Primary 開始。如果你不是先在 Primary 上執行這支腳本，代表操作順序有誤，請先確認清楚。"
  fi
}

step_major_handle_efm() {
  echo
  echo "===== Step 4：EFM 處理（大版本，整叢集關閉）====="
  EFM_SERVICE=$(find_efm_service)
  if [ -z "$EFM_SERVICE" ]; then
    log "未偵測到任何 edb-efm-* 服務，判斷這台機器沒有裝 EFM，略過 EFM 處理。"
    return
  fi
  log "偵測到 EFM 服務：$EFM_SERVICE"

  if [ "$NODE_ROLE" != "witness" ]; then
    local -a matched_props=()
    local pf pf_port
    while IFS= read -r pf; do
      [ -z "$pf" ] && continue
      pf_port=$(grep -oP '^\s*db\.port\s*=\s*\K[0-9]+' "$pf" 2>/dev/null | head -1)
      if [ -n "$pf_port" ] && [ "$pf_port" = "$OLD_PORT" ]; then
        matched_props+=("$pf")
      fi
    done < <(find /etc/edb/efm-*/ -maxdepth 1 -name '*.properties' 2>/dev/null)

    if [ "${#matched_props[@]}" -eq 0 ]; then
      warn "掃描 /etc/edb/efm-*/*.properties，沒有找到任何叢集設定檔的 db.port 跟這個 instance 的 port ($OLD_PORT) 相符。"
      confirm "判斷這個 EFM 服務跟這次要升級的 instance 無關，要跳過整個 EFM 處理步驟嗎？" && {
        log "使用者確認 EFM 與本次 instance 無關，略過 EFM 處理。"
        return
      }
      local input
      read -rp "EFM 叢集名稱（直接 Enter 預設為 efm）: " input
      EFM_CLUSTER="${input:-efm}"
    elif [ "${#matched_props[@]}" -eq 1 ]; then
      EFM_CLUSTER=$(basename "${matched_props[0]}" .properties)
      log "自動比對 port 相符，判斷這個 instance 屬於 EFM 叢集：$EFM_CLUSTER"
    else
      warn "有 ${#matched_props[@]} 個叢集設定檔的 db.port 都相符，無法自動判斷："
      local mp; for mp in "${matched_props[@]}"; do warn "  - $mp"; done
      local input
      read -rp "EFM 叢集名稱（直接 Enter 預設為 efm）: " input
      EFM_CLUSTER="${input:-efm}"
    fi
  else
    local input
    read -rp "EFM 叢集名稱（直接 Enter 預設為 efm）: " input
    EFM_CLUSTER="${input:-efm}"
  fi

  log "使用的 EFM 叢集名稱：$EFM_CLUSTER"
  EFM_BIN=$(find_efm_bin)
  [ -z "$EFM_BIN" ] && warn "找不到 efm 指令（試過 PATH 跟 /usr/edb/efm-*/bin/efm），部分操作會受限。"

  if [ "$NODE_ROLE" = "primary" ]; then
    warn "本機角色為 Primary：即將用 efm stop-cluster 一次關閉整個叢集(Witness+所有Standby+Primary)的 EFM。"
    warn "注意：stop-cluster 會清空 EFM 的 Allowed Node host list，除非 auto.allow.hosts=true，之後重開機需要對每個節點重新執行 efm allow-node（--reopen-efm 時會提示）。"
    confirm "確認要對叢集 '$EFM_CLUSTER' 執行 efm stop-cluster 嗎？" && {
      run_and_log "${EFM_BIN:-efm}" stop-cluster "$EFM_CLUSTER" || return 1
      EFM_STOPPED_BY_ME=true
      log "已對整個叢集執行 stop-cluster。"
    } || { log "使用者取消。"; return 1; }
  else
    log "本機角色為 ${NODE_ROLE}：大版本升級規定由 Primary 統一關閉整個叢集的 EFM，這裡只檢查狀態，不主動關閉。"
    if systemctl is-active --quiet "$EFM_SERVICE"; then
      err "偵測到本機 EFM 服務 ($EFM_SERVICE) 仍在運作中，代表 Primary 那邊可能還沒執行整叢集的 EFM 關閉。請先確認 Primary 的步驟已完成，再回來繼續這台機器。"
      return 1
    fi
    log "確認本機 EFM 已經是關閉狀態，符合預期的執行順序（由 Primary 統一關閉），繼續。"
  fi
}

step_major_dnf_install() {
  echo
  echo "===== Step 5：安裝新大版本套件 ====="
  log "查詢 edb-as${NEW_MAJOR}-* 在 repo '$REPO_ID' 底下有哪些套件..."
  # 注意：這裡不能用「dnf list available」，因為它只列「目前還沒裝」的套件，
  # 如果這台機器之前留過同大版本的舊套件（殘留安裝），dnf list available
  # 會直接查不到東西、以 exit code 1 收場，即使 repo 裡的 rpm 完全沒問題。
  # 改用 dnf repoquery，純粹查 repo 裡有什麼，不管目前裝了沒裝，跟
  # check_version.sh 用的方式一致。
  run_and_log dnf repoquery --disablerepo='*' --enablerepo="$REPO_ID" --qf '%{name}.%{arch}  (%{version}-%{release})' "edb-as${NEW_MAJOR}-*"

  local -a available
  mapfile -t available < <(dnf repoquery --disablerepo='*' --enablerepo="$REPO_ID" --qf '%{name}.%{arch}' "edb-as${NEW_MAJOR}-*" 2>/dev/null | sort -u)

  if [ "${#available[@]}" -eq 0 ]; then
    err "沒有查到任何可安裝的套件，請確認 repo 設定、版本號是否正確。"
    return 1
  fi

  if [ "$UPGRADE_MODE" != "install" ]; then
    confirm "是否要連進舊 cluster 查詢目前已安裝的 extension，比對新版本套件清單，預先檢查相容性？（沒裝對應套件的話 pg_upgrade 之後會直接失敗）" && {
      local op odb ou opw
      read -rp "psql port（直接 Enter 預設 ${OLD_PORT}）: " op; op="${op:-$OLD_PORT}"
      read -rp "psql db（直接 Enter 預設 edb）: " odb; odb="${odb:-edb}"
      read -rp "psql user（直接 Enter 預設 enterprisedb）: " ou; ou="${ou:-enterprisedb}"
      read -rsp "psql password（直接 Enter 代表無密碼）: " opw; echo
      local dx_out
      if [ -n "$opw" ]; then
        dx_out=$(PGPASSWORD="$opw" psql -h 127.0.0.1 -p "$op" -d "$odb" -U "$ou" -tAc "SELECT extname FROM pg_extension;" 2>>"$LOGFILE")
      else
        dx_out=$(psql -h 127.0.0.1 -p "$op" -d "$odb" -U "$ou" -tAc "SELECT extname FROM pg_extension;" 2>>"$LOGFILE")
      fi
      if [ -z "$dx_out" ]; then
        warn "查不到 extension 清單（連線失敗或沒有額外 extension），略過比對。"
      else
        log "舊 cluster 已安裝的 extension：$(echo "$dx_out" | tr '\n' ' ')"
        local ext
        while read -r ext; do
          [ -z "$ext" ] && continue
          if ! printf '%s\n' "${available[@]}" | grep -qi "$ext"; then
            warn "extension「$ext」在新版本套件清單裡沒有明顯對應的套件名稱，請自行確認 as${NEW_MAJOR} 是否支援，不確定就繼續下去，pg_upgrade 可能會直接失敗中止。"
          fi
        done <<< "$dx_out"
      fi
    }
  fi

  echo "偵測到以下可安裝套件："
  local i
  for i in "${!available[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${available[$i]}"
  done
  local sel
  read -rp "請輸入要安裝的套件編號（空白分隔多個，直接 Enter 代表全部安裝）: " sel
  SELECTED_PKGS=()
  if [ -z "$sel" ]; then
    SELECTED_PKGS=("${available[@]}")
  else
    local n
    for n in $sel; do
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#available[@]}" ]; then
        SELECTED_PKGS+=("${available[$((n - 1))]}")
      fi
    done
  fi
  if [ "${#SELECTED_PKGS[@]}" -eq 0 ]; then
    err "沒有選擇任何套件。"
    return 1
  fi

  echo "即將執行："
  echo "  dnf install -y --disablerepo='*' --enablerepo=\"$REPO_ID\" \\"
  local last=$(( ${#SELECTED_PKGS[@]} - 1 ))
  for i in "${!SELECTED_PKGS[@]}"; do
    if [ "$i" -eq "$last" ]; then echo "    ${SELECTED_PKGS[$i]}"; else echo "    ${SELECTED_PKGS[$i]} \\"; fi
  done
  confirm "確認要執行以上安裝嗎？" || { log "使用者取消。"; return 1; }
  run_and_log dnf install -y --disablerepo='*' --enablerepo="$REPO_ID" "${SELECTED_PKGS[@]}" || {
    err "dnf install 失敗。"
    return 1
  }
}

step_major_primary_initdb() {
  echo
  echo "===== [Primary] 建立新版本的 Cluster ====="
  local new_bindir="/usr/edb/as${NEW_MAJOR}/bin"
  if [ ! -x "${new_bindir}/initdb" ]; then
    err "找不到 ${new_bindir}/initdb，請確認新版本套件是否安裝成功。"
    return 1
  fi

  local default_dir="/pgdata/edb/as${TARGET_VERSION_NUM:-$NEW_MAJOR}/data" input
  read -rp "新 cluster 的資料目錄（直接 Enter 預設 ${default_dir}）: " input
  NEW_DATADIR="${input:-$default_dir}"

  if [ -d "$NEW_DATADIR" ] && [ -n "$(ls -A "$NEW_DATADIR" 2>/dev/null)" ]; then
    log "偵測到 $NEW_DATADIR 已存在且非空，判斷是既有的 cluster。"
    confirm "要沿用這個既有的 cluster，不重新 initdb 嗎？" && { log "沿用既有 cluster：$NEW_DATADIR"; return; }
    err "目錄已存在且非空，若不沿用請先自行清空或換一個路徑。"
    return 1
  fi

  local loc_args=() q
  if [ "$UPGRADE_MODE" != "install" ]; then
    read -rp "是否要連進舊 cluster 查詢目前的 locale/encoding，作為新 cluster initdb 的參數？[y/N]: " q
    if [[ "$q" =~ ^[yY] ]]; then
      local op odb ou opw enc coll ctype
      read -rp "psql port（直接 Enter 預設 ${OLD_PORT}）: " op; op="${op:-$OLD_PORT}"
      read -rp "psql db（直接 Enter 預設 edb）: " odb; odb="${odb:-edb}"
      read -rp "psql user（直接 Enter 預設 enterprisedb）: " ou; ou="${ou:-enterprisedb}"
      read -rsp "psql password（直接 Enter 代表無密碼）: " opw; echo
      if [ -n "$opw" ]; then
        enc=$(PGPASSWORD="$opw" psql -h 127.0.0.1 -p "$op" -d "$odb" -U "$ou" -tAc "SHOW server_encoding;" 2>>"$LOGFILE")
        coll=$(PGPASSWORD="$opw" psql -h 127.0.0.1 -p "$op" -d "$odb" -U "$ou" -tAc "SHOW lc_collate;" 2>>"$LOGFILE")
        ctype=$(PGPASSWORD="$opw" psql -h 127.0.0.1 -p "$op" -d "$odb" -U "$ou" -tAc "SHOW lc_ctype;" 2>>"$LOGFILE")
      else
        enc=$(psql -h 127.0.0.1 -p "$op" -d "$odb" -U "$ou" -tAc "SHOW server_encoding;" 2>>"$LOGFILE")
        coll=$(psql -h 127.0.0.1 -p "$op" -d "$odb" -U "$ou" -tAc "SHOW lc_collate;" 2>>"$LOGFILE")
        ctype=$(psql -h 127.0.0.1 -p "$op" -d "$odb" -U "$ou" -tAc "SHOW lc_ctype;" 2>>"$LOGFILE")
      fi
      if [ -n "$enc" ] && [ -n "$coll" ] && [ -n "$ctype" ]; then
        log "查到舊 cluster：encoding=$enc lc_collate=$coll lc_ctype=$ctype，將以此作為 initdb 參數。"
        loc_args=(--encoding="$enc" --lc-collate="$coll" --lc-ctype="$ctype")
      else
        warn "查詢失敗，initdb 將使用系統預設 locale/encoding，請自行留意跟舊 cluster 是否一致。"
      fi
    else
      warn "略過查詢，initdb 將使用系統預設 locale/encoding。跟舊 cluster 不一致可能造成 collation 版本落差，索引悄悄壞掉的風險，請自行留意。"
    fi
  fi

  local checksum_prompt="是否要開啟 data checksums（initdb --data-checksums）？"
  if [ "$UPGRADE_MODE" = "install" ] && [ "$INSTALL_PURPOSE" = "production" ]; then
    checksum_prompt="正式環境安裝：建議開啟 data checksums（initdb --data-checksums），之後要再改要整個 cluster 重掃一遍，成本高很多。是否開啟？"
  fi
  local checksum_args=()
  confirm "$checksum_prompt" && checksum_args=(--data-checksums)

  # 純安裝模式才需要在這裡直接設 superuser 密碼；大版本升級沿用舊 cluster
  # 既有的使用者/密碼，pg_upgrade 不會動這塊，所以這段只在 install 模式跑。
  local pwfile=""
  if [ "$UPGRADE_MODE" = "install" ]; then
    local pg_password=""
    if [ "$INSTALL_PURPOSE" = "production" ]; then
      while [ -z "$pg_password" ]; do
        read -rsp "正式環境安裝：請輸入 $DB_OS_USER 這個 superuser 的密碼（必填）: " pg_password
        echo
      done
    else
      read -rsp "$DB_OS_USER 這個 superuser 的密碼（直接 Enter 代表不設密碼，測試用途）: " pg_password
      echo
    fi
    if [ -n "$pg_password" ]; then
      pwfile=$(mktemp)
      echo "$pg_password" > "$pwfile"
      chmod 600 "$pwfile"
      chown "$DB_OS_USER" "$pwfile" 2>/dev/null
      log "已準備 superuser 密碼（透過臨時檔案傳給 initdb --pwfile，不會出現在畫面或 log）。"
    else
      warn "$DB_OS_USER 沒有設定密碼，測試用途請自行注意這台機器的網路可及範圍。"
    fi
  fi

  confirm "確認要執行 initdb 建立新 cluster 於 $NEW_DATADIR 嗎？" || { [ -n "$pwfile" ] && rm -f "$pwfile"; log "使用者取消。"; return 1; }
  mkdir -p "$NEW_DATADIR"
  chown "$DB_OS_USER:$DB_OS_USER" "$NEW_DATADIR" 2>/dev/null
  run_as_db_user "${new_bindir}/initdb" -D "$NEW_DATADIR" "${loc_args[@]}" "${checksum_args[@]}" ${pwfile:+--pwfile="$pwfile"} || {
    [ -n "$pwfile" ] && rm -f "$pwfile"
    err "initdb 失敗。"
    return 1
  }
  [ -n "$pwfile" ] && rm -f "$pwfile"
  log "initdb 完成：$NEW_DATADIR"
}

step_major_standby_basebackup() {
  echo
  echo "===== [Standby] 用 pg_basebackup 重建 ====="

  if [ "$UPGRADE_MODE" = "install" ]; then
    confirm "確認要用 pg_basebackup 從指定的 Primary 建立這個全新的 Standby 嗎？" || {
      log "使用者取消。"
      return 1
    }
  else
    confirm "請先確認：Primary 是否已經完成大版本升級，並且新版本已經啟動、可以連線？" || {
      err "請先完成 Primary 那邊的升級，再回來繼續這台機器。"
      return 1
    }

    confirm "確認要停止本機舊的 standby（PID=$OLD_PID，資料目錄=$OLD_DATADIR）嗎？" || { log "使用者取消。"; return 1; }
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
      if [ "$OLD_SYSTEMD_TRACKED" = true ]; then
        log "這個 instance 在 systemd 管理下（$OLD_SERVICE_NAME），改用 systemctl stop。"
        run_and_log systemctl stop "$OLD_SERVICE_NAME" || { err "停止舊 standby 失敗。"; return 1; }
      else
        warn "這個 instance 不在 systemd 追蹤範圍內，改用 pg_ctl stop。"
        run_as_db_user pg_ctl stop -D "$OLD_DATADIR" -m fast || { err "停止舊 standby 失敗。"; return 1; }
      fi
    fi
    log "舊 standby 已停止。"
  fi

  local default_dir="/pgdata/edb/as${TARGET_VERSION_NUM:-$NEW_MAJOR}/data" input
  read -rp "新 standby 的資料目錄（直接 Enter 預設 ${default_dir}）: " input
  NEW_DATADIR="${input:-$default_dir}"

  if [ -d "$NEW_DATADIR" ] && [ -n "$(ls -A "$NEW_DATADIR" 2>/dev/null)" ]; then
    err "$NEW_DATADIR 已存在且非空，pg_basebackup 沒辦法寫入非空目錄，請先清空或換路徑。"
    return 1
  fi
  confirm "確認要建立目錄 $NEW_DATADIR 並設好權限嗎？" || { log "使用者取消。"; return 1; }
  mkdir -p "$NEW_DATADIR"
  chmod 0700 "$NEW_DATADIR"
  chown "$DB_OS_USER:$DB_OS_USER" "$NEW_DATADIR"

  local pb_host="" pb_port="" pb_user pb_pass
  while [ -z "$pb_host" ]; do read -rp "Primary 的 IP（必填）: " pb_host; done
  while [ -z "$pb_port" ]; do read -rp "Primary 的 port（必填）: " pb_port; done
  read -rp "複製用的 user（直接 Enter 預設 replicator）: " pb_user
  pb_user="${pb_user:-replicator}"
  read -rsp "複製用的密碼（直接 Enter 代表無密碼）: " pb_pass; echo
  local slot_ver_tag slot_host_tag default_slot_name
  slot_ver_tag="${TARGET_VERSION_NUM:-$NEW_MAJOR}"
  slot_ver_tag="${slot_ver_tag//./_}"
  slot_host_tag=$(hostname -s 2>/dev/null || echo standby)
  slot_host_tag="${slot_host_tag//-/_}"
  default_slot_name="as${slot_ver_tag}_${slot_host_tag}"
  read -rp "replication slot 名稱（直接 Enter 預設 ${default_slot_name}，只能是小寫字母/數字/底線）: " REPL_SLOT_NAME
  REPL_SLOT_NAME="${REPL_SLOT_NAME:-$default_slot_name}"

  echo "即將執行："
  echo "  (以 $DB_OS_USER 身份) pg_basebackup -h $pb_host -p $pb_port -U $pb_user -D $NEW_DATADIR -Fp -Xs -P -R -C -S $REPL_SLOT_NAME --checkpoint=fast"
  local pb_pass_file=""
  if [ -n "$pb_pass" ]; then
    echo "  （密碼已透過臨時 .pgpass 檔案傳遞，不會出現在畫面、log 或 ps aux）"
  fi
  confirm "確認要執行以上 pg_basebackup 嗎？" || { log "使用者取消。"; return 1; }

  if [ -n "$pb_pass" ]; then
    pb_pass_file=$(mktemp)
    echo "${pb_host}:${pb_port}:*:${pb_user}:${pb_pass}" > "$pb_pass_file"
    chmod 600 "$pb_pass_file"
    chown "$DB_OS_USER" "$pb_pass_file" 2>/dev/null
  fi

  log "\$ (以 $DB_OS_USER 身份) pg_basebackup -h $pb_host -p $pb_port -U $pb_user -D $NEW_DATADIR -Fp -Xs -P -R -C -S $REPL_SLOT_NAME --checkpoint=fast"
  local status
  if [ -n "$pb_pass_file" ]; then
    sudo -u "$DB_OS_USER" env PGPASSFILE="$pb_pass_file" pg_basebackup -h "$pb_host" -p "$pb_port" -U "$pb_user" \
      -D "$NEW_DATADIR" -Fp -Xs -P -R -C -S "$REPL_SLOT_NAME" --checkpoint=fast 2>&1 | tee -a "$LOGFILE"
    status="${PIPESTATUS[0]}"
    rm -f "$pb_pass_file"
  else
    sudo -u "$DB_OS_USER" pg_basebackup -h "$pb_host" -p "$pb_port" -U "$pb_user" \
      -D "$NEW_DATADIR" -Fp -Xs -P -R -C -S "$REPL_SLOT_NAME" --checkpoint=fast 2>&1 | tee -a "$LOGFILE"
    status="${PIPESTATUS[0]}"
  fi
  if [ "$status" -ne 0 ]; then
    err "pg_basebackup 失敗（exit code $status）。"
    return 1
  fi
  log "pg_basebackup 完成：$NEW_DATADIR（已包含 -R 寫入的 standby.signal / primary_conninfo）"
}

step_major_configure_port() {
  echo
  echo "===== 設定新服務的 Port ====="
  NEW_PORT=""
  while [ -z "$NEW_PORT" ]; do
    read -rp "新服務要用的 port（必填，不能留空）: " NEW_PORT
  done
  log "新服務將使用 port：$NEW_PORT"

  confirm "確認要執行 firewall-cmd 開放 port $NEW_PORT/tcp 嗎？" && {
    run_and_log firewall-cmd --permanent --add-port="${NEW_PORT}/tcp"
    run_and_log firewall-cmd --reload
  } || warn "使用者選擇不透過本工具處理 firewall，請自行確認 port 已開放。"

  if [ -f "$NEW_DATADIR/postgresql.conf" ]; then
    confirm "確認要把 $NEW_DATADIR/postgresql.conf 的 port 改成 $NEW_PORT 嗎？（Standby 的 postgresql.conf 是從 Primary 複製過來的，port 可能跟這台機器上其他 instance 衝突，請仔細確認）" && {
      run_and_log sed -i -E "s/^#?port[[:space:]]*=.*/port = ${NEW_PORT}/" "$NEW_DATADIR/postgresql.conf"
    }
  fi
}

step_major_setup_systemd_unit() {
  echo
  echo "===== 設定新版本的 systemd unit ====="
  local base_unit="/usr/lib/systemd/system/edb-as-${NEW_MAJOR}.service"

  # 後綴預設值一律把完整版本號寫進去（不是只憑 major），這樣同一台機器上
  # 就算裝了好幾個 as${NEW_MAJOR} 開頭的 service，光看名字就能分清楚是哪個
  # 版本、什麼用途，不用再去翻 Environment=PGDATA 才知道實際指到哪裡（這台
  # 機器上就真實發生過這種混淆）。版本號裡的點一律轉底線，因為 systemd unit
  # 名稱裡雖然可以放點，但容易跟型別後綴（.service）混淆，不如統一用底線。
  local svc_ver_tag="${TARGET_VERSION_NUM:-$NEW_MAJOR}"
  svc_ver_tag="${svc_ver_tag//./_}"
  # 升級流程預設「<版本號>_upgrade」（跟舊版本區分，驗證沒問題後你可以自己
  # 決定要不要改名）；純安裝模式沒有「升級中」這回事，正式環境預設直接用
  # 「<版本號>」（不額外加 test/upgrade 這種用途字樣），測試/暫時安裝預設用
  # 「<版本號>_test」，並且都可以自己覆寫，避免跟同機其他 instance 撞名。
  local default_suffix="${svc_ver_tag}_upgrade"
  if [ "$UPGRADE_MODE" = "install" ]; then
    if [ "$INSTALL_PURPOSE" = "production" ]; then
      default_suffix="${svc_ver_tag}"
    else
      default_suffix="${svc_ver_tag}_test"
    fi
  fi
  local suffix
  read -rp "這個 instance 的 systemd service 名稱要加什麼後綴？（直接 Enter 預設「${default_suffix:-無後綴，用正式名稱}」，同一台機器上如果有其他 instance 請避免撞名）: " suffix
  suffix="${suffix:-$default_suffix}"
  if [ -n "$suffix" ]; then
    NEW_SERVICE_NAME="edb-as-${NEW_MAJOR}-${suffix}.service"
  else
    NEW_SERVICE_NAME="edb-as-${NEW_MAJOR}.service"
  fi
  local dest_unit="/etc/systemd/system/${NEW_SERVICE_NAME}"

  if [ ! -f "$base_unit" ]; then
    err "找不到 $base_unit，請確認新版本套件是否安裝成功。"
    return 1
  fi

  if [ -f "$dest_unit" ]; then
    log "偵測到 $dest_unit 已存在。"
    run_and_log cat "$dest_unit"
    confirm "要沿用這個既有的 unit 檔嗎？" && { log "沿用既有 unit：$dest_unit"; return; }
  fi

  confirm "確認要複製 $base_unit 到 $dest_unit 並設定 PGDATA/PIDFile 嗎？" || { log "使用者取消。"; return 1; }
  run_and_log cp "$base_unit" "$dest_unit" || return 1

  if grep -q '^\[Service\]' "$dest_unit"; then
    sed -i "/^\[Service\]/a Environment=PGDATA=${NEW_DATADIR}\nPIDFile=${NEW_DATADIR}/postmaster.pid" "$dest_unit"
  else
    { echo "[Service]"; echo "Environment=PGDATA=${NEW_DATADIR}"; echo "PIDFile=${NEW_DATADIR}/postmaster.pid"; } >> "$dest_unit"
  fi
  log "已寫入 Environment=PGDATA=${NEW_DATADIR} 與 PIDFile 到 $dest_unit"
  run_and_log cat "$dest_unit"
  confirm "確認執行 systemctl daemon-reload 嗎？" && run_and_log systemctl daemon-reload
}

step_major_pg_upgrade() {
  echo
  echo "===== [Primary] 執行 pg_upgrade ====="
  local old_bindir="/usr/edb/as${OLD_MAJOR}/bin"
  local new_bindir="/usr/edb/as${NEW_MAJOR}/bin"
  if [ ! -x "${new_bindir}/pg_upgrade" ]; then
    err "找不到 ${new_bindir}/pg_upgrade。"
    return 1
  fi

  warn "pg_upgrade 執行前，舊、新兩個 cluster 都必須是「已停止」狀態，這是操作者要自己保證的前提，pg_upgrade 不會幫你檢查/處理。"
  if ps -p "$OLD_PID" > /dev/null 2>&1; then
    warn "偵測到舊 cluster 的 PID ($OLD_PID) 似乎還在跑。"
    if [ "$OLD_SYSTEMD_TRACKED" = true ]; then
      log "這個 instance 在 systemd 管理下（$OLD_SERVICE_NAME）。"
      confirm "確認執行 systemctl stop $OLD_SERVICE_NAME 嗎？" && {
        run_and_log systemctl stop "$OLD_SERVICE_NAME" || return 1
      } || { err "舊 cluster 未停止。"; return 1; }
    else
      warn "這個 instance 不在 systemd 追蹤範圍內（可能是被手動用 pg_ctl 啟動的），改用 pg_ctl stop。"
      confirm "確認對 $OLD_DATADIR 執行 pg_ctl stop -m fast（以 $DB_OS_USER 身份）？" && {
        run_as_db_user pg_ctl stop -D "$OLD_DATADIR" -m fast
      } || { err "舊 cluster 未停止。"; return 1; }
    fi

    log "確認 PID $OLD_PID 是否已經停止..."
    local i stopped=false
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if ! ps -p "$OLD_PID" > /dev/null 2>&1; then stopped=true; break; fi
      sleep 2
    done
    if [ "$stopped" = false ]; then
      err "PID $OLD_PID 在等待後仍在執行，可能停止失敗，請手動確認狀態。"
      return 1
    fi
    log "已確認舊 cluster (PID $OLD_PID) 已停止。"
  fi
  confirm "確認新 cluster ($NEW_DATADIR) 目前是停止狀態（尚未啟動過）嗎？" || { err "請先手動確認新 cluster 是停止的。"; return 1; }

  echo "pg_upgrade 有以下幾種資料搬移模式可以選："
  echo "  copy             （預設）逐一複製檔案到新 cluster。最安全：複製完舊 cluster 完全不受影響、還能正常啟動，代價是要多一倍磁碟空間，速度也最慢。"
  echo "  link             用 hard link 取代複製。幾乎不用額外空間、速度最快，但新舊 cluster 的資料檔實際上是同一份，新 cluster 一啟動，舊 cluster 就不能再安全啟動了，沒有回頭路。要求新舊 datadir 在同一個檔案系統。"
  echo "  clone            用檔案系統的 reflink/clone（copy-on-write）。速度、省空間跟 link 差不多，但因為是 COW，寫入新 cluster 不會動到舊 cluster 的資料，複製完舊 cluster 仍可正常啟動。只有部分作業系統/檔案系統支援（Linux 4.5+ 的 Btrfs、有開 reflink 的 XFS；macOS APFS），也要求同一個檔案系統。"
  echo "  copy-file-range  用 copy_file_range() 這個系統呼叫複製，在有支援的檔案系統上效果接近 clone（共用實體區塊），沒支援也還是比一般複製快一些。目前支援 Linux、FreeBSD。"
  echo "  swap             直接把舊 cluster 的資料目錄搬給新 cluster 用，再換上新版的 catalog 檔。relation 數量多時可能比其他模式都快，但『檔案搬移這一步一開始』舊 cluster 就會被破壞性修改、之後不能再啟動，比 link 更激進——連 --check 通過都不代表安全，是實際搬移動作開始才算數。要求同一個檔案系統，官方建議搭配 --sync-method=fsync 一起用。"
  warn "link/clone/copy-file-range/swap 都要求新舊 datadir 在同一個檔案系統下，而且要新版 pg_upgrade 本身有支援這個模式才能用（部分是比較新的版本才加入的），選了不支援的模式 pg_upgrade 會直接報錯。不確定的話選 copy 最保險。"

  local mode
  read -rp "請輸入要用的模式（copy/link/clone/copy-file-range/swap，直接 Enter 預設 copy）: " mode
  mode="${mode:-copy}"

  local mode_args=()
  case "$mode" in
    copy)
      log "使用 copy 模式（預設，最安全，舊 cluster 完全不受影響）。"
      ;;
    link)
      warn "選擇 link 模式：新 cluster 一啟動，舊 cluster 就『不能再安全啟動』，沒有回頭路，舊 cluster 只能當殘留清掉，不能拿來降級。"
      confirm "了解以上風險，確定要用 link 模式嗎？" && mode_args=(--link) || { mode="copy"; log "改回使用 copy 模式。"; }
      ;;
    clone)
      warn "選擇 clone 模式：需要檔案系統支援 reflink/clone（Linux 4.5+ 的 Btrfs、有開 reflink 的 XFS；macOS APFS），且新舊 datadir 要同一個檔案系統，不支援的話 pg_upgrade 會直接報錯中止。"
      confirm "確定要用 clone 模式嗎？" && mode_args=(--clone) || { mode="copy"; log "改回使用 copy 模式。"; }
      ;;
    copy-file-range)
      warn "選擇 copy-file-range 模式：目前只支援 Linux、FreeBSD，且新舊 datadir 要同一個檔案系統。"
      confirm "確定要用 copy-file-range 模式嗎？" && mode_args=(--copy-file-range) || { mode="copy"; log "改回使用 copy 模式。"; }
      ;;
    swap)
      warn "選擇 swap 模式：『檔案搬移這一步一開始』舊 cluster 就會被破壞性修改、之後不能再啟動，比 link 更激進，連 --check 通過都不代表安全。要求新舊 datadir 同一個檔案系統，官方建議搭配 --sync-method=fsync 一起用。"
      confirm "了解以上風險，確定要用 swap 模式嗎？" && mode_args=(--swap --sync-method=fsync) || { mode="copy"; log "改回使用 copy 模式。"; }
      ;;
    *)
      warn "無法識別的模式「$mode」，改用預設的 copy 模式。"
      mode="copy"
      ;;
  esac
  PGU_MODE="$mode"

  local base_cmd=("${new_bindir}/pg_upgrade"
    --old-bindir "$old_bindir" --new-bindir "$new_bindir"
    --old-datadir "$OLD_DATADIR" --new-datadir "$NEW_DATADIR"
    --old-port "$OLD_PORT" --new-port "$NEW_PORT"
    "${mode_args[@]}")

  # pg_upgrade 要求在自己有讀寫權限的「當前工作目錄」下執行（用來放
  # pg_upgrade_output.d/ 等記錄），單純 sudo -u 不會換目錄，如果腳本本身是在
  # $DB_OS_USER 沒有寫入權限的目錄下跑的（常見於用 root 執行整支腳本），
  # pg_upgrade 一開始就會直接失敗（"You must have read and write access in
  # the current directory."）。這裡另外準備一個 $DB_OS_USER 有權限的專用目錄。
  local pgu_ver_tag="${TARGET_VERSION_NUM:-$NEW_MAJOR}"
  pgu_ver_tag="${pgu_ver_tag//./_}"
  PGU_WORKDIR="$(dirname "$NEW_DATADIR")/pg_upgrade_work_as${OLD_MAJOR}_to_${pgu_ver_tag}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$PGU_WORKDIR"
  chown "$DB_OS_USER:$DB_OS_USER" "$PGU_WORKDIR"
  log "pg_upgrade 的執行目錄（放 pg_upgrade_output.d 等記錄）：$PGU_WORKDIR"

  echo "即將先執行 --check 模式（不會真的動任何資料）："
  printf '  %s\n' "${base_cmd[@]}" "--check"
  confirm "確認執行 --check 嗎？" || { log "使用者取消。"; return 1; }
  run_as_db_user_in_dir "$PGU_WORKDIR" "${base_cmd[@]}" --check || {
    err "--check 沒有通過，請看上面/log 的訊息排查。"
    return 1
  }
  log "--check 通過。"

  echo "即將正式執行 pg_upgrade（模式：$mode）："
  printf '  %s\n' "${base_cmd[@]}"
  confirm "確認要正式執行 pg_upgrade 嗎？這步之後如果選的是 link 或 swap 模式，就沒有回頭路了（copy/clone/copy-file-range 模式舊 cluster 仍然安全）。" || { log "使用者取消。"; return 1; }
  run_as_db_user_in_dir "$PGU_WORKDIR" "${base_cmd[@]}" || {
    err "pg_upgrade 失敗，請查看上面/log 的訊息。"
    return 1
  }
  log "pg_upgrade 完成。詳細記錄（含 analyze/delete 建議腳本，如果有產生的話）在：$PGU_WORKDIR"
}

step_major_start_new_cluster() {
  echo
  echo "===== 啟動新版本服務 ====="
  confirm "確認執行 systemctl start $NEW_SERVICE_NAME 嗎？" && {
    run_and_log systemctl start "$NEW_SERVICE_NAME" || return 1
  } || { err "使用者取消。新 cluster 目前未啟動。"; return 1; }
}

step_major_analyze() {
  echo
  echo "===== [Primary] 重建統計資訊 ====="
  confirm "pg_upgrade 完成後建議執行 vacuumdb --analyze-in-stages 重建查詢統計資訊，現在要執行嗎？" && {
    run_as_db_user "/usr/edb/as${NEW_MAJOR}/bin/vacuumdb" -p "$NEW_PORT" -U "$DB_OS_USER" --all --analyze-in-stages
  } || warn "略過，記得之後手動找時間執行，不然新 cluster 查詢計畫可能會很差。"
}

step_major_verify() {
  echo
  echo "===== 驗證結果 ====="
  run_and_log systemctl status "$NEW_SERVICE_NAME" --no-pager

  read -rp "psql port（直接 Enter 預設 ${NEW_PORT}）: " input
  PSQL_PORT="${input:-$NEW_PORT}"
  read -rp "psql db（直接 Enter 預設 edb）: " input
  PSQL_DB="${input:-edb}"
  read -rp "psql user（直接 Enter 預設 enterprisedb）: " input
  PSQL_USER="${input:-enterprisedb}"
  read -rsp "psql password（直接 Enter 代表無密碼）: " PSQL_PASSWORD
  echo

  local ver
  ver=$(psql_query "SELECT version();")
  if [ -z "$ver" ]; then
    err "無法連線查詢版本，請確認 port/db/user/密碼、pg_hba.conf 設定。"
  else
    log "目前實際回報版本：$ver"
  fi

  if [ "$NODE_ROLE" = "standby" ]; then
    local is_standby
    is_standby=$(psql_query "SELECT pg_is_in_recovery();")
    if [ "$is_standby" = "t" ]; then
      log "確認為 standby，複寫狀態如下："
      psql_show "SELECT status, last_msg_receipt_time FROM pg_stat_wal_receiver;"
    else
      err "預期應該是 standby，但 pg_is_in_recovery() 回傳不是 t，請自行確認狀態是否正常。"
    fi
  fi
}

step_major_wrapup() {
  echo
  echo "===== 收尾 ====="

  if [ "$NODE_ROLE" != "witness" ] && [ -n "$OLD_DATADIR" ] && [ -d "$OLD_DATADIR" ]; then
    if [ "$PGU_MODE" = "link" ] || [ "$PGU_MODE" = "swap" ]; then
      warn "這次 pg_upgrade 用的是 $PGU_MODE 模式，舊 cluster ($OLD_DATADIR) 已經不能再安全啟動了，不是可用的備援，只是殘留檔案，找時間清掉即可。"
    elif [ -n "$OLD_DATADIR" ]; then
      confirm "舊 cluster 資料目錄 ($OLD_DATADIR) 要保留一段時間當備援嗎？（選『是』只是記錄下來，本工具不會自動刪除任何資料目錄）" && {
        log "使用者選擇保留舊 cluster：$OLD_DATADIR，請自行決定何時清理。"
      } || {
        warn "使用者選擇不特別保留，但基於安全考量本工具不會自動幫你刪除，請確認沒問題後自行手動清理 $OLD_DATADIR。"
      }
    fi
  fi

  warn "EFM 提醒：整個叢集(Witness+所有Standby+Primary)全部升級完成前，請不要重開任何一台機器的 EFM。全部完成後，請對每台機器分別執行：$0 --reopen-efm"
  if [ "$EFM_STOPPED_BY_ME" = true ]; then
    warn "這次是用 efm stop-cluster 關閉整個叢集的，Allowed Node host list 已被清空。除非 auto.allow.hosts=true，否則重開機後要對每個節點重新執行 efm allow-node，執行 $0 --reopen-efm 時會提示這件事。"
  fi
  warn "外部工具提醒：大版本升級後，Barman/pgBackRest 的備份設定通常需要跟著更新（pgBackRest 要改 pg1-path 並執行 stanza-upgrade；Barman 要改 server 設定並重新做一次 full backup 當新基準點），PEM 監控的 target 設定也可能需要重新指到新的 port/路徑。這些都不在本工具範圍內，請自行安排。"

  log "本次大版本升級流程已全部完成。"
}

########################################
# 進入點
########################################
trap final_exit_log EXIT

case "${1:-}" in
  -h|--help)
    print_usage
    exit 0
    ;;
  --reopen-efm)
    do_reopen_efm
    ;;
esac

echo "=============================================="
echo " upgrader.sh — EDB 升級互動工具"
echo " Designer: Reamer"
echo "=============================================="
log "腳本開始執行，log 檔：$LOGFILE"

run_step step_choose_major_or_minor

if [ "$UPGRADE_MODE" = "minor" ]; then
  run_step step_select_instance
  run_step step_prepare_offline_repo
  run_step step_warn_siblings
  run_step step_handle_efm
  run_step step_list_and_select_packages
  run_step step_dnf_update
  run_step step_restart
  run_step step_verify
  run_step step_extension_reconcile

  echo
  log "本次流程已全部完成。提醒：EFM 重新開啟要等整個叢集都升級完才對每台機器執行 $0 --reopen-efm。"
elif [ "$UPGRADE_MODE" = "major" ]; then
  # 大版本：先解壓縮/驗證離線套件包，從實際內容列出有打包哪些大版本讓使用
  # 者選（不要叫使用者用打字的猜一個大版本號），再掃描本機 instance、判斷
  # 角色，這樣角色判斷裡「目前版本是否 >= 目標大版本」的檢查才有東西可比。
  run_step step_extract_and_verify_archive
  run_step step_select_major_from_repo
  run_step step_major_select_instance_and_role
  run_step step_major_handle_efm

  if [ "$NODE_ROLE" = "witness" ]; then
    log "本機為 Witness，沒有資料庫需要升級，僅處理 EFM。"
  else
    run_step step_select_version_and_write_repo
    run_step step_major_dnf_install

    if [ "$NODE_ROLE" = "primary" ]; then
      run_step step_major_primary_initdb
      run_step step_major_configure_port
      run_step step_major_setup_systemd_unit
      run_step step_major_pg_upgrade
      run_step step_major_start_new_cluster
      run_step step_major_analyze
    else
      run_step step_major_standby_basebackup
      run_step step_major_configure_port
      run_step step_major_setup_systemd_unit
      run_step step_major_start_new_cluster
    fi

    run_step step_major_verify
    [ "$NODE_ROLE" = "primary" ] && run_step step_extension_reconcile
  fi

  run_step step_major_wrapup
else
  # 純安裝：沒有舊 instance，不碰 EFM（EFM cluster 本身的建立維持手動處理，
  # 不在本工具範圍內）。重用大版本流程裡 dnf 安裝/initdb/pg_basebackup/
  # port/systemd/啟動/驗證這些積木，只是跳過「找舊 instance、關 EFM、
  # pg_upgrade」這些跟「升級」綁在一起的部分。
  run_step step_install_choose_purpose
  run_step step_extract_and_verify_archive
  run_step step_select_major_from_repo
  run_step step_install_choose_role
  run_step step_select_version_and_write_repo
  run_step step_major_dnf_install

  if [ "$NODE_ROLE" = "primary" ]; then
    run_step step_major_primary_initdb
    run_step step_major_configure_port
    run_step step_major_setup_systemd_unit
    run_step step_major_start_new_cluster
  else
    run_step step_major_standby_basebackup
    run_step step_major_configure_port
    run_step step_major_setup_systemd_unit
    run_step step_major_start_new_cluster
  fi

  run_step step_major_verify
  run_step step_install_wrapup
fi
