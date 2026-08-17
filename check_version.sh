#!/usr/bin/env bash
#
# check_version.sh — 查詢 EDB AS 某個大版本在「目前這台機器已設定的
# repo」裡實際有多少個小版本可以抓,只查詢、不下載,給評估容量用。
#
# 前提:這台機器要已經設定好 EDB 的訂閱 repo(跟 mirror_edb_repo.sh 裡
# setup_edb_repo() 要填的是同一個東西)。如果你是在跑過 mirror_edb_repo.sh
# 的那台機器上執行這支腳本,repo 應該已經設定過了;如果 dnf repolist 看
# 不到 edb 相關的 repo id,要先把 repo 設定起來這支腳本才查得到東西。
#
# 用法:
#   ./check_version.sh 15                        # 查 edb-as15-server 有幾個版本
#   ./check_version.sh 15 edb-as15-server-contrib # 查其他套件
#
set -uo pipefail

ver="${1:-}"
pkg="${2:-edb-as${ver}-server}"

if [ -z "$ver" ]; then
  echo "用法: $0 <大版本號> [套件名稱,預設 edb-as<版本>-server]"
  echo "例如: $0 15"
  exit 1
fi

if ! command -v dnf >/dev/null 2>&1; then
  echo "[錯誤] 找不到 dnf,這支腳本要在有 dnf 的機器上跑"
  exit 1
fi

echo "查詢套件: ${pkg}"
echo "來源: 目前這台機器已啟用的 repo(只查詢,不會下載任何 rpm)"
echo

tmpfile=$(mktemp)
# --showduplicates:預設 dnf repoquery 只會顯示「每個 repo 裡最新的那個」,
# 要看到全部歷史版本一定要加這個,不然只會查到跟 dnf download 一樣的
# 「只有最新版」結果,失去查詢的意義。
dnf repoquery --showduplicates --qf '%{version}\t%{release}\t%{arch}\t%{reponame}' "$pkg" \
  2>"${tmpfile}.err" | sort -V > "$tmpfile"

if [ ! -s "$tmpfile" ]; then
  echo "[警告] 查不到任何版本,可能是:"
  echo "  - 這台機器還沒設定 EDB repo(跑 dnf repolist 看得到 edb 相關 repo id 嗎?)"
  echo "  - 套件名稱打錯,確認完整名稱,例如 edb-as15-server"
  echo "  - repoquery 本身有錯誤,詳見下方:"
  cat "${tmpfile}.err" 2>/dev/null | sed 's/^/    /'
  rm -f "$tmpfile" "${tmpfile}.err"
  exit 1
fi

echo "── 版本清單(版本 / release / 架構 / repo)──"
cat "$tmpfile"
echo

total_count=$(wc -l < "$tmpfile")
distinct_count=$(awk -F'\t' '{print $1}' "$tmpfile" | sort -Vu | wc -l)
arch_count=$(awk -F'\t' '{print $3}' "$tmpfile" | sort -u | wc -l)

echo "── 統計 ──"
echo "總筆數(含不同架構/release重複計算): ${total_count}"
echo "不重複的 x.y.z 版本數: ${distinct_count}"
echo "涵蓋架構數: ${arch_count}"
echo
echo "評估容量時記得乘上:"
echo "  這個 distinct 版本數 × 你要打包的其他套件數(contrib/client/llvmjit等)"
echo "  × OS 大版本數(el8/el9)× 架構數 × 每個 rpm 平均大小"
echo "才是全部小版本都要囤的實際總容量;通常會遠比你想的大,這也是為什麼"
echo "建議走「需要哪個版本才臨時抓那個」而不是整批預先囤積。"

rm -f "$tmpfile" "${tmpfile}.err"
