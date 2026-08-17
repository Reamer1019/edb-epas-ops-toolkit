#!/usr/bin/env bash
#
# mirror_edb_repo.sh — 依你指定的版本 spec,把 EDB AS 的套件(及其依賴)
# 打包成離線 repo,供 edb_offline_upgrade.sh(同目錄下的另一支腳本)在
# air-gapped 客戶端安裝/升級用。
#
# 這支腳本在「有網路、有 EDB 訂閱權限」的機器上跑,不是在客戶端跑。
#
# 設計原則(改版說明):一開始的版本是「每個大版本都抓最新的」,後來發現
# 客戶常常需要指定的舊小版本,而 EDB 每個大版本底下小版本數量不少
# (實測 15 版就有17個),如果每次都全部囤起來,體積會大到單機都放不下、
# 也大部分用不到。所以現在改成「每次執行,你告訴我要哪個版本,我就只抓
# 那個版本」,平常幫客戶準備升級前跑一次、抓那次要用的版本就好,不要
# 預先囤積整個版本矩陣。
#
# ============================================================
# 重要:動手前一定要看的兩件事
# ============================================================
#
# 1. 【EDB repo 訂閱設定我沒辦法幫你確認】EDB 的訂閱式 repo 存取機制
#    (token、setup script 的確切網址、參數)會隨你的帳戶方案跟時間變化,
#    我沒有把握目前你的訂閱入口實際長怎樣。下面 EDB_REPO_TOKEN 這個
#    變數填你自己 EDB 訂閱入口給的 token 即可,不用改 setup_edb_repo()
#    這個函式;如果你的訂閱入口給的不是這種 token 網址形式,才需要
#    直接改 setup_edb_repo() 內容。
#
# 2. 【dnf download --resolve 算的是「這台機器現在有什麼」,不是「乾淨
#    目標機器需要什麼」】—— 這是你們自己踩過、也寫進筆記裡的坑
#    (pgBackRest NFS 部署那次,還有 barman-cli 那次都中過)。這支腳本
#    用 podman 容器跑,每個 OS 版本用乾淨的基底映像,每次都是
#    全新環境,從根本上避開這個問題,不用再靠人工回想「來源機到底裝過
#    什麼」。這也是為什麼一定要用容器跑,不建議直接在你自己慣用的工作機
#    上對著系統的 dnf 下載——你工作機上裝的一堆有的沒的套件,會讓
#    --resolve 誤判「這個已經滿足了」,漏抓依賴,搬到客戶端才爆炸。
#
# 前置需求:
#   - podman(或改用 docker,把下面 CONTAINER_ENGINE 改成 docker 即可,
#     語法幾乎通用)
#   - createrepo_c(在 host,也就是這台機器上,不是容器裡——理由見
#     mirror_one_combo() 內的說明)
#   - 如果要跨架構(在 x86_64 機器上抓 aarch64 套件,或反過來),需要
#     qemu-user-static + binfmt 支援;podman 通常會自動處理,如果
#     --platform 失敗,參考 multiarch/qemu-user-static 或 tonistiigi/binfmt
#     這兩個容器工具做 binfmt 註冊,並留意 SELinux 是否擋掉 qemu 執行檔
#     的讀取權限(ausearch -m avc -ts recent | grep -i qemu 可以查)
#
# 用法:
#   ./mirror_edb_repo.sh                        # 顯示用法說明(跟 -h 一樣)
#   ./mirror_edb_repo.sh -h
#   ./mirror_edb_repo.sh <版本spec> [架構] [OS]  # 抓指定版本,可選只抓指定架構、
#                                                # 可選只抓指定 OS(el8/el9)
#   ./mirror_edb_repo.sh --all                  # 抓15~18全部大版本的全部小版本
#                                                # (會先跳警告確認,容量可能超過20G)
#
# 版本 spec 範例(輸入愈精確,抓得愈少、檔案愈小):
#   15              抓 15 底下所有小版本 + 所有 release(最完整,也最大)
#   15.18           抓版號以 15.18 開頭的所有 release
#   15.18.0         抓版號恰好 15.18.0 的所有 release
#   15.18.0-2.el8   抓恰好這一個 release,最精準、檔案最小(平常單一客戶
#                   要升級時應該用這種——先用 check_version.sh 或
#                   dnf repoquery --showduplicates 確認確切版號)
#
# 每次執行都會在 OUTPUT_ROOT 底下開一個新的子目錄(不會覆蓋/累加舊資料),
# 結束後打包成一個 edb_offline_repo_<spec>_<時間戳>.tar.gz(+ .sha256),
# 只包含「這次執行實際抓到的東西」。打包完會問你要不要順便刪掉解壓縮
# 前的原始目錄(只留 tar.gz),這台機器磁碟空間有限的話建議刪。
#
set -uo pipefail

# ────────────────────────────────────────────────────────────
# 設定區——照你的實際需求調整
# ────────────────────────────────────────────────────────────

# EDB AS 目前有在維護的大版本,只有 --all 模式會用到這份清單。
KNOWN_MAJORS="15 16 17 18"

# 要打包哪些 OS/架構組合,對照 EDB 官方 Platform Compatibility 頁面
# (https://www.enterprisedb.com/platform-compatibility#epas)核對過,
# EDB AS 14~18 全部版本的 ARM64 只支援 RHEL9,RHEL8 完全沒有 ARM64 的
# 套件——el8+aarch64 這個組合不管怎麼打包都會失敗,不是設定錯誤,是
# EDB 根本沒出這個組合,所以不放進清單裡。之後如果 EDB 開始支援更多
# 組合,照這個格式加一行就好("os:arch",空白分隔多組)。
COMBOS="el8:x86_64 el9:x86_64 el9:aarch64"

# 你的 EDB 訂閱 token(EDB 帳號後台 Repository 頁面可以找到那段網址裡的
# token)。只要填這一個變數就好,不用改任何函式內容;留空會直接報錯。
EDB_REPO_TOKEN=""

# 每個大版本要抓的套件,{V} 會被換成實際版本號(例如 18)。
# 套件名稱對照 EDB 官方文件(Available native packages)確認過,注意
# llvmjit 完整名稱是 edb-as{V}-server-llvmjit(不是 edb-as{V}-llvmjit)。
# 這是常見基本組合,你們實際用到的東西(例如 edb-as{V}-server-sslutils
# 給 PEM 用、edb-as{V}-server-pldebugger 除錯用)請自行增減;不確定某個
# 套件確實名稱時,先在有網路的機器上 dnf search edb-as${V} 對一下。
PACKAGE_TEMPLATE="edb-as{V}-server edb-as{V}-server-contrib edb-as{V}-server-client edb-as{V}-server-llvmjit"

OUTPUT_ROOT="./edb_offline_repo"
CONTAINER_ENGINE="podman"    # 沒有 podman 就改成 docker

# 基底映像對應表——用 AlmaLinux,不是 RHEL 官方的 UBI。
# 原本用 UBI(registry.access.redhat.com/ubi8/ubi 等),踩到一個坑:UBI
# 預設開的 ubi-*-appstream-rpms 是「可自由散布子集」,不是完整 AppStream,
# 像 boost-chrono 這類套件(edb-as{V}-pgagent 依賴鏈需要的東西)不在這個
# 子集裡,不管怎麼開 CodeReady Builder 都抓不到,因為問題根本不在 CRB,
# 是 UBI 本身的內容範圍就比較窄。AlmaLinux 是 RHEL 的 1:1 免費重build,
# AppStream/BaseOS 是完整內容、預設就開,沒有子集限制這回事,boost-chrono
# 這類套件直接就在裡面。而且 EDB 官方 Platform Compatibility 頁面本來就
# 把 Rocky Linux/AlmaLinux 列為正式支援的安裝平台,不是繞路的權宜之計。
declare -A BASE_IMAGE=(
  [el8]="docker.io/almalinux:8"
  [el9]="docker.io/almalinux:9"
)
declare -A PODMAN_PLATFORM=(
  [x86_64]="linux/amd64"
  [aarch64]="linux/arm64"
)

# ────────────────────────────────────────────────────────────
# 設定 EDB repo(容器內部執行,讓容器裡的 dnf 認得 EDB 的 repo)
# ────────────────────────────────────────────────────────────
# 不用改這個函式。要填的只有上面設定區的 EDB_REPO_TOKEN;沒填就直接報錯
# 中止,不會跑到一半才發現。如果你 EDB 訂閱入口給的不是這種
# curl|bash的 token 網址形式(例如是 dnf config-manager 那種寫法),
# 才需要直接改下面這行。
setup_edb_repo() {
  if [ -z "$EDB_REPO_TOKEN" ]; then
    echo "[錯誤] EDB_REPO_TOKEN 未設定。打開 mirror_edb_repo.sh,在腳本開頭"
    echo "       設定區把 EDB_REPO_TOKEN=\"\" 填上你的 EDB 訂閱 token 再重跑。"
    return 1
  fi
  curl -1sLf "https://downloads.enterprisedb.com/${EDB_REPO_TOKEN}/enterprise/setup.rpm.sh" | bash
}

# ────────────────────────────────────────────────────────────
# 共用小工具
# ────────────────────────────────────────────────────────────
parse_major() {  # $1=spec -> 印出開頭的大版本數字,抓不到印空字串
  echo "$1" | grep -oE '^[0-9]+'
}

confirm_typed() {  # $1=要求輸入的關鍵字 $2=提示文字
  local want="$1" prompt="$2" got
  echo "  [需要確認] ${prompt}"
  read -rp "  請輸入「${want}」以繼續(其他任何輸入都會取消): " got
  [ "$got" = "$want" ]
}

sanitize_for_filename() {  # $1=任意字串 -> 只保留英數字/點/減號/底線,其餘換成底線
  # 用 printf 而不是 echo:echo 印出來的字串結尾會帶換行字元,那個換行字元
  # 也不在允許清單裡,會被 tr -c 一起換成底線,結果變成尾巴多一個底線
  # (例如 "15" 變成 "15_")——這是實測寫測試腳本時真的撞到的坑。
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

print_usage() {
  cat <<USAGE
用法:
  ./mirror_edb_repo.sh                        顯示這份說明(跟 -h 一樣)
  ./mirror_edb_repo.sh -h
  ./mirror_edb_repo.sh <版本spec> [架構] [OS]  抓指定版本,可選只抓指定架構、
                                               可選只抓指定 OS(el8/el9)
  ./mirror_edb_repo.sh --all                  抓 ${KNOWN_MAJORS// /,} 全部大版本的
                                               全部小版本(會先跳警告確認,容量
                                               可能超過 20G,先用 check_version.sh
                                               評估過再決定要不要用這個模式)

版本 spec 範例(輸入愈精確,抓得愈少、檔案愈小):
  15              抓 15 底下所有小版本 + 所有 release(最完整,也最大)
  15.18           抓版號以 15.18 開頭的所有 release
  15.18.0         抓版號恰好 15.18.0 的所有 release
  15.18.0-2.el8   抓恰好這一個 release,最精準、檔案最小(平常單一客戶要
                  升級時應該用這種——注意 release 編號(這裡的 "2")一定要
                  帶,不能省略,實際編號用 check_version.sh 或 dnf repoquery
                  --showduplicates 查,不要用猜的)

架構(可選,不填 = 涵蓋這個版本 spec 支援的所有架構):
  x86_64          只抓 x86_64
  aarch64         只抓 aarch64(目前只有 el9,el8 沒有 ARM64 套件)
  (留空,或填 "" 佔位,代表不篩選架構)

OS(可選,不填 = 涵蓋這個版本 spec 支援的所有 OS):
  el8             只抓 RHEL/Rocky/AlmaLinux 8 系列
  el9             只抓 RHEL/Rocky/AlmaLinux 9 系列

範例:
  ./mirror_edb_repo.sh 15.18.0-2.el8 x86_64        只抓這一個 release、只要 x86_64
                                                    (el8 本來就只有 x86_64,OS 可不填)
  ./mirror_edb_repo.sh 16.1.0-1.el9 "" el9         只抓 16.1.0-1.el9,只要 el9,
                                                    架構不篩選(x86_64+aarch64都要,
                                                    第二個參數留空字串佔位)
  ./mirror_edb_repo.sh 16 x86_64 el9               16 版全部小版本,只要 el9 的 x86_64
  ./mirror_edb_repo.sh 15                          抓 15 全部小版本,所有支援的組合

輸出:
  每次執行都會在 ${OUTPUT_ROOT} 底下開一個新的子目錄(不會覆蓋/累加舊資料),
  結束後打包成一個 edb_offline_repo_<spec>_<時間戳>.tar.gz(+ .sha256),
  只包含這次執行實際抓到的東西。想先評估某個大版本底下有多少小版本、
  再決定要打包多細,用同目錄的 check_version.sh 先查(只查詢不下載)。
USAGE
}

# ────────────────────────────────────────────────────────────
# 核心邏輯
# ────────────────────────────────────────────────────────────
mirror_one_combo() {  # $1=os $2=arch $3=majors(空白分隔) $4=spec(可為空="全部") $5=run_dir
  local os="$1" arch="$2" majors="$3" spec="$4" run_dir="$5"
  local image="${BASE_IMAGE[$os]:-}"
  local platform="${PODMAN_PLATFORM[$arch]:-}"

  if [ -z "$image" ]; then
    echo "[錯誤] 不認得的 OS 版本: ${os}(目前只設定了 ${!BASE_IMAGE[*]})"
    return 1
  fi
  if [ -z "$platform" ]; then
    echo "[錯誤] 不認得的架構: ${arch}(目前只設定了 ${!PODMAN_PLATFORM[*]})"
    return 1
  fi

  local combo_dir="${run_dir}/${os}/${arch}"
  mkdir -p "$combo_dir"

  echo "══════════════════════════════════════════════════════"
  echo " 開始打包: OS=${os}  ARCH=${arch}  版本spec=${spec:-<全部>}  image=${image}"
  echo " 輸出目錄: ${combo_dir}"
  echo "══════════════════════════════════════════════════════"

  # 把 setup_edb_repo 的內容跟主要下載邏輯,一起丟進容器內執行。
  # 用 bash -c 組一段完整腳本,透過 heredoc 傳進 podman run。
  #
  # 注意:容器內「只負責下載 rpm」,不在容器內跑 createrepo_c——這一步
  # 只是讀 rpm header 產生中繼資料,不需要「乾淨環境」這個特性(那個
  # 特性只跟 dnf download --resolve 解依賴有關),搬到 host(這台機器)
  # 執行更簡單,host 上你自己的機器裝一次 createrepo_c 就好。
  local inner_script
  inner_script=$(cat <<'INNER_EOF'
set -euo pipefail
echo "-- 容器內環境確認 --"
cat /etc/os-release | grep -E "^(NAME|VERSION)="
uname -m

echo "-- 安裝基本工具 --"
dnf -y install dnf-plugins-core >/dev/null

echo "-- 設定 EDB repo --"
# 把貼進來的內容包成一個「真正的函式」再呼叫,不是直接當成頂層腳本執行——
# setup_edb_repo() 裡面(不管是佔位符還是你自己填的內容)很可能用 return
# 提早結束,而 return 只能在函式或 source 進來的腳本裡用,直接貼成頂層
# 程式碼碰到 return 會噴 "return: can only `return' from a function or
# sourced script" 直接中止,是這裡曾經真實發生過的 bug,務必保持這個包法。
setup_edb_repo_inner() {
EDB_REPO_SETUP_PLACEHOLDER
}
if ! setup_edb_repo_inner; then
  exit 1
fi

echo "-- 開始逐大版本解析/下載 --"
for ver in $MAJORS_INNER; do
  pkgdir="/out/edb-as${ver}"
  mkdir -p "$pkgdir"
  pkgs=$(echo "$PACKAGE_TEMPLATE_INNER" | sed "s/{V}/${ver}/g")

  echo "  [EDB AS ${ver}] 解析符合條件的版本(spec=\"${SPEC_INNER}\",留空代表全部)..."
  : > "${pkgdir}/resolved_nevra.txt"
  for base_pkg in $pkgs; do
    # --showduplicates:dnf repoquery 預設只列每個 repo 裡最新的一筆,
    # 要看到全部歷史版本一定要加這個。
    candidates=$(dnf repoquery --showduplicates --qf '%{name}-%{version}-%{release}.%{arch}' "$base_pkg" 2>>"${pkgdir}/dnf_download.err")
    if [ -z "$candidates" ]; then
      echo "    [警告] ${base_pkg}: repoquery 查不到任何版本(套件名稱可能打錯,"
      echo "           或這個大版本沒有這個套件,或 repo 沒設定成功)"
      continue
    fi
    if [ -n "$SPEC_INNER" ]; then
      # 前綴比對:NEVRA 字串要以 "<套件名>-<spec>" 開頭。用 awk 的 index()
      # 做字面(非正規表示式)前綴比對,避免 spec 裡的點被誤當成正規
      # 表示式的任意字元、或 grep -F 不方便錨定開頭的問題。
      matched=$(echo "$candidates" | awk -v pfx="${base_pkg}-${SPEC_INNER}" 'index($0, pfx)==1')
    else
      matched="$candidates"
    fi
    if [ -z "$matched" ]; then
      echo "    [警告] ${base_pkg}: 找不到符合 spec=\"${SPEC_INNER}\" 的版本,"
      echo "           實際可選版本(最新5個):"
      echo "$candidates" | sort -V | tail -5 | sed 's/^/             /'
      continue
    fi
    echo "$matched" >> "${pkgdir}/resolved_nevra.txt"
  done

  nevra_count=$(wc -l < "${pkgdir}/resolved_nevra.txt" 2>/dev/null); nevra_count="${nevra_count:-0}"
  if [ "$nevra_count" -eq 0 ]; then
    echo "  [EDB AS ${ver}] 沒有解析到任何符合條件的版本,略過下載"
    continue
  fi
  echo "  [EDB AS ${ver}] 解析到 ${nevra_count} 筆,逐一下載(含依賴)..."

  # 一個 NEVRA 一次 dnf download 呼叫,不要把全部 NEVRA 塞進同一個指令。
  # 這是實測踩到的坑:spec 抓比較寬(例如整個大版本)時,resolved_nevra.txt
  # 裡會同時有好幾個小版本的 llvmjit,而 llvmjit 這個套件的依賴鏈綁定
  # 「OS 當下的 LLVM 版本」,不同小版本的 edb-as16-server-llvmjit 各自綁
  # 不同的 LLVM 大版本(例如16.1.0要LLVM15、16.10.0要LLVM19.1),這些
  # LLVM 版本互斥,同一個 repo 通常只有目前那一個在架上。把好幾個小版本
  # 的 llvmjit 一次丟進同一個 dnf download,dnf 的 solver 會想「同時」
  # 滿足所有版本的依賴,得到互相衝突的 "conflicting requests" 直接整批
  # 失敗——即使加了 --skip-broken 也一樣,因為這不是「單一套件解不開」,
  # 是「好幾個套件的要求互相矛盾」,--skip-broken 處理不了這種情況。
  # 拆成一個 NEVRA 一次呼叫,each 各自獨立 resolve,某個舊版本的 llvmjit
  # 因為系統上已經沒有它要的舊 LLVM 而抓不到,只會讓「那一個版本」失敗,
  # 不會拖累其他版本;llvmjit 本身也只是 JIT 加速用的選配套件,不是
  # pg_upgrade/日常運作必需品,個別版本抓不到通常可以接受。
  # 注意:這裡故意不加 -C(--cacheonly)。曾經為了省下重複的 metadata
  # 過期檢查加過這個旗標,但踩到一個更嚴重的坑:-C 管的不只是「metadata
  # 要不要重查」,還包括「套件本身能不能從網路重新抓」——加了 -C,dnf
  # 只肯用本機套件快取裡已經有的東西,一律不碰網路抓新檔案。這個容器
  # 每次都是全新環境(刻意設計,避免污染),套件快取永遠是空的,結果
  # -C 讓每一個套件的下載都被擋下來,錯誤訊息會是
  # "Some packages have invalid cache, but cannot be downloaded due to
  # \"--cacheonly\" option",整批 0 個 rpm。metadata 過期檢查頂多讓
  # spec 抓比較寬(例如整個大版本、上百筆 NEVRA)時跑久一點,不加 -C
  # 只是慢,加了 -C 是直接全部抓不到,兩害相權,不加。
  fail_count=0
  while IFS= read -r nevra; do
    [ -z "$nevra" ] && continue
    if dnf download --resolve --alldeps --skip-broken --destdir="$pkgdir" "$nevra" 2>>"${pkgdir}/dnf_download.err"; then
      :
    else
      fail_count=$((fail_count+1))
      echo "    [警告] ${nevra}: 下載失敗(常見於 llvmjit 綁定的舊版 LLVM 已經不在 repo 裡),詳見 ${pkgdir}/dnf_download.err"
    fi
  done < "${pkgdir}/resolved_nevra.txt"

  got=$(find "$pkgdir" -name '*.rpm' | wc -l)
  echo "  [EDB AS ${ver}] 下載完成,共 ${got} 個 rpm(${fail_count} 筆 NEVRA 失敗)"
  if [ "$got" -eq 0 ]; then
    echo "  [警告][EDB AS ${ver}] 實際 0 個 rpm,詳見 ${pkgdir}/dnf_download.err 內容:"
    sed 's/^/    /' "${pkgdir}/dnf_download.err" 2>/dev/null
  fi
done

echo "-- 全部大版本處理完成(repo 中繼資料留給 host 端建立)--"
INNER_EOF
)
  # 把佔位符換成真正的內容(setup_edb_repo 的函式本體)。
  # declare -f 印出來的格式是:
  #   funcname ()
  #   {
  #     ...body...
  #   }
  # 前兩行是函式名稱+開大括號、最後一行是收大括號,要拿掉這 3 行才是
  # 純函式內容,只刪第1行會漏刪「{」那行,body 裡就會混進一個孤立的
  # 大括號,語法直接壞掉。
  local repo_setup_body
  repo_setup_body=$(declare -f setup_edb_repo | sed '1,2d;$d')
  inner_script="${inner_script//EDB_REPO_SETUP_PLACEHOLDER/$repo_setup_body}"

  "$CONTAINER_ENGINE" run --rm \
    --platform "$platform" \
    -v "${combo_dir}:/out:Z" \
    -e "MAJORS_INNER=${majors}" \
    -e "PACKAGE_TEMPLATE_INNER=${PACKAGE_TEMPLATE}" \
    -e "SPEC_INNER=${spec}" \
    -e "EDB_REPO_TOKEN=${EDB_REPO_TOKEN}" \
    "$image" \
    bash -c "$inner_script"

  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[錯誤] ${os}/${arch} 這個組合執行失敗(exit ${rc}),往上翻看容器內的錯誤訊息"
  fi

  # ── host 端建立 repo 中繼資料 ──
  # 對每個「有抓到 rpm」的版本子目錄跑 createrepo_c,跟容器內下載成不成功
  # 是分開的兩件事:即使某個版本下載失敗,已經成功的其他版本還是要建立
  # 中繼資料,不要整組因為一個版本失敗就全部沒有 repodata。
  echo "-- host 端建立 repo 中繼資料(createrepo_c)--"
  local verdir has_any=0
  for verdir in "$combo_dir"/edb-as*; do
    [ -d "$verdir" ] || continue
    if [ -z "$(find "$verdir" -maxdepth 1 -name '*.rpm' 2>/dev/null)" ]; then
      echo "  ${verdir}: 沒有 rpm,略過"
      continue
    fi
    has_any=1
    echo "  ${verdir}: 建立中繼資料"
    createrepo_c "$verdir" >/dev/null 2>"${verdir}/createrepo.err" \
      || { echo "  [錯誤] createrepo_c 失敗,詳見 ${verdir}/createrepo.err"; rc=1; }
  done
  [ "$has_any" -eq 0 ] && echo "  這個組合(${os}/${arch})完全沒有成功下載的版本,無 repo 可建立"

  return "$rc"
}

write_manifest() {  # $1=run_dir $2=majors $3=spec標籤
  local run_dir="$1" majors="$2" label="$3"
  local manifest="${run_dir}/MANIFEST.txt"
  {
    echo "EDB 離線 repo 打包清單"
    echo "產生時間: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "版本 spec: ${label}"
    echo "涵蓋大版本: ${majors}"
    echo
    echo "目錄結構: <os>/<arch>/edb-as<版本>/"
    echo
    find "$run_dir" -name "*.rpm" 2>/dev/null | wc -l | xargs echo "rpm 總數:"
    echo
    echo "── 離線目標機安裝方式 ──"
    echo "把這個資料夾(或打包出來的 tar.gz,用 USB 或核准的傳輸管道,不能"
    echo "走網路傳輸,那樣就不算 air-gapped 了)搬到客戶端機器上,然後在客戶端:"
    echo
    echo "  cat > /etc/yum.repos.d/edb-offline.repo <<EOF"
    echo "  [edb-offline]"
    echo "  name=EDB Offline Repo"
    echo "  baseurl=file:///path/to/<os>/<arch>/edb-as<版本>"
    echo "  enabled=1"
    echo "  gpgcheck=0"
    echo "  EOF"
    echo "  dnf clean all && dnf makecache"
    echo "  dnf install edb-as<版本>-server"
    echo
    echo "(baseurl 那行的路徑要對照實際解壓縮出來的目錄結構手動填,上面是"
    echo "示意,不是直接能貼的指令;edb_offline_upgrade.sh 的 [2] 模組會"
    echo "自動處理這件事,不需要手動下這些指令)"
  } > "$manifest"
  echo "已產生清單: $manifest"
}

# ────────────────────────────────────────────────────────────
# 打包成單一檔案(供 edb_offline_upgrade.sh 的 [2] 模組使用)
# ────────────────────────────────────────────────────────────
# 為什麼要多這一步:run_dir 底下是「目錄樹」(os/arch/edb-as<版本>/*.rpm),
# 檔案數量動輒上百上千個,用 USB 之類的方式一個個檔案搬很麻煩也容易漏檔、
# 權限跑掉。打包成一個 tar.gz,搬運/校驗/紀錄版本都只要對著「一個檔案」
# 處理。順便算 sha256——這個檔案通常會經過 USB 這種人工搬運過程,校驗碼
# 是唯一能確認「搬過去的檔案沒有半路壞掉/傳輸中斷截斷」的方法。
package_archive() {  # $1=run_dir $2=spec標籤(用在檔名)
  local run_dir="$1" label="$2"
  local ts archive_name archive_path safe_label
  ts=$(date '+%Y%m%d_%H%M%S')
  safe_label=$(sanitize_for_filename "$label")
  archive_name="edb_offline_repo_${safe_label}_${ts}.tar.gz"
  archive_path="$(cd "$(dirname "$OUTPUT_ROOT")" && pwd)/${archive_name}"

  echo "══════════════════════════════════════════════════════"
  echo " 打包成單一檔案: ${archive_path}"
  echo "══════════════════════════════════════════════════════"

  # -C 切到 run_dir 的上一層,tar 內部路徑用資料夾名稱開頭(不是絕對路徑),
  # 這樣客戶端解壓縮出來的目錄名稱固定,edb_offline_upgrade.sh 猜路徑
  # 才猜得準;絕對路徑打包進 tar 是常見的坑(對方機器上路徑不一定一樣)。
  local root_parent root_name
  root_parent="$(cd "$(dirname "$run_dir")" && pwd)"
  root_name="$(basename "$run_dir")"

  if tar -czf "$archive_path" -C "$root_parent" "$root_name"; then
    echo "  打包完成: ${archive_path}"
  else
    echo "[錯誤] 打包失敗,請檢查磁碟空間(打包過程會暫時需要跟原始檔案總大小相當的額外空間)"
    return 1
  fi

  local sha_path="${archive_path}.sha256"
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$(dirname "$archive_path")" && sha256sum "$(basename "$archive_path")" > "$sha_path" )
  elif command -v shasum >/dev/null 2>&1; then
    ( cd "$(dirname "$archive_path")" && shasum -a 256 "$(basename "$archive_path")" > "$sha_path" )
  else
    echo "  (找不到 sha256sum/shasum,略過校驗碼——強烈建議自行算一份,USB搬運後在客戶端要能驗證檔案完整)"
  fi
  [ -f "$sha_path" ] && echo "  校驗碼: ${sha_path}($(cat "$sha_path"))"

  echo
  echo "  搬到客戶端後,先驗證再解壓縮:"
  echo "    sha256sum -c $(basename "$sha_path")"
  echo "    tar -xzf $(basename "$archive_path")"
  echo "  或直接把路徑填進 edb_offline_upgrade.conf 的 OFFLINE_REPO_ARCHIVE,"
  echo "  讓它的 [2] 模組自動驗證+解壓縮。"

  # 磁碟空間有限時,原始目錄(解壓縮前的樣子)打包完基本上用不到了,
  # 留著只是白佔空間——問一下要不要順手刪掉,只保留 tar.gz。
  echo
  read -rp "  是否刪除原始目錄 ${run_dir}(只保留剛打包好的 tar.gz)?(y/N) " del_confirm
  if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
    rm -rf "$run_dir"
    echo "  已刪除 ${run_dir}"
  else
    echo "  保留原始目錄,之後要手動清理請自行到 ${OUTPUT_ROOT} 底下確認"
  fi
}

# ────────────────────────────────────────────────────────────
# 進入點
# ────────────────────────────────────────────────────────────
raw_arg1="${1:-}"

case "$raw_arg1" in
  ""|-h|--help)
    print_usage
    exit 0
    ;;
esac

if [ -z "$EDB_REPO_TOKEN" ]; then
  echo "[錯誤] EDB_REPO_TOKEN 未設定。打開 mirror_edb_repo.sh,在腳本開頭設定區"
  echo "       把 EDB_REPO_TOKEN=\"\" 填上你的 EDB 訂閱 token 再重跑。"
  exit 1
fi

if ! command -v "$CONTAINER_ENGINE" >/dev/null 2>&1; then
  echo "[錯誤] 找不到 ${CONTAINER_ENGINE},請先安裝,或把腳本開頭 CONTAINER_ENGINE 改成你有的容器工具"
  exit 1
fi

# createrepo_c 現在是在「host」(這台機器,不是容器內)執行,理由見
# mirror_one_combo() 裡的說明。這台機器要有這個套件才能建立 repo 中繼資料。
if ! command -v createrepo_c >/dev/null 2>&1; then
  echo "[錯誤] 這台機器(host)找不到 createrepo_c,請先安裝再重跑:"
  echo "         dnf install -y createrepo_c"
  echo "       如果 dnf 也說找不到,通常是 AppStream/CRB 沒啟用,先試:"
  echo "         dnf install -y --enablerepo='*' createrepo_c"
  exit 1
fi

if [ "$raw_arg1" = "--all" ]; then
  echo "[警告] --all 會抓 ${KNOWN_MAJORS} 每個大版本底下的所有小版本/release,"
  echo "       實測估算全部版本 × 全部組合可能超過 20G,確定要繼續嗎?"
  echo "       建議先用 check_version.sh 評估過容量再決定。"
  if ! confirm_typed "ALL" "確認要抓全部版本"; then
    echo "已取消"
    exit 1
  fi
  run_label="ALL"
  spec_for_download=""
  majors="$KNOWN_MAJORS"
  arch_filter="${2:-}"
  os_filter="${3:-}"
else
  run_label="$raw_arg1"
  spec_for_download="$raw_arg1"
  major=$(parse_major "$run_label")
  if [ -z "$major" ]; then
    echo "[錯誤] 看不懂版本 spec \"${run_label}\",開頭要是大版本數字,例如 15 或 15.18.0"
    echo "       不確定要打什麼,直接執行 ./mirror_edb_repo.sh(不帶參數)看用法說明"
    exit 1
  fi
  majors="$major"
  arch_filter="${2:-}"
  os_filter="${3:-}"
fi

if [ -n "$arch_filter" ] && [ -z "${PODMAN_PLATFORM[$arch_filter]:-}" ]; then
  echo "[錯誤] 不認得的架構 \"${arch_filter}\",目前支援: ${!PODMAN_PLATFORM[*]}"
  exit 1
fi

if [ -n "$os_filter" ] && [ -z "${BASE_IMAGE[$os_filter]:-}" ]; then
  echo "[錯誤] 不認得的 OS \"${os_filter}\",目前支援: ${!BASE_IMAGE[*]}"
  exit 1
fi

safe_label=$(sanitize_for_filename "$run_label")
run_dir="${OUTPUT_ROOT}/run_${safe_label}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$run_dir"

overall_rc=0
ran_any=0
for combo in $COMBOS; do
  os="${combo%%:*}"
  arch="${combo##*:}"
  if [ -n "$arch_filter" ] && [ "$arch" != "$arch_filter" ]; then
    continue
  fi
  if [ -n "$os_filter" ] && [ "$os" != "$os_filter" ]; then
    continue
  fi
  ran_any=1
  mirror_one_combo "$os" "$arch" "$majors" "$spec_for_download" "$run_dir" || overall_rc=1
done

if [ "$ran_any" -eq 0 ]; then
  echo "[錯誤] 沒有任何組合符合條件(架構篩選 \"${arch_filter}\"、OS 篩選 \"${os_filter}\" 的組合可能不在 COMBOS 清單裡,例如 el8+aarch64 這個組合本來就不存在)"
  exit 1
fi

write_manifest "$run_dir" "$majors" "$run_label"

if [ "$overall_rc" -ne 0 ]; then
  echo
  echo "[提醒] 有組合執行失敗,往上找 [錯誤]/[警告] 標記的地方處理"
  echo "[提醒] 仍會繼續打包,但打包內容可能不完整,建議處理完失敗組合後重跑"
fi

package_archive "$run_dir" "$run_label" || overall_rc=1

exit "$overall_rc"
