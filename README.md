# edb-epas-ops-toolkit

一組在維運 EDB Postgres Advanced Server（EPAS）時，為了取代手動、容易出錯的重複性作業而寫的小工具集。全部都是獨立的 Bash / Python 腳本，沒有外部框架依賴，設計上盡量做到「不用改程式碼、互動輸入就能用」，也刻意讓每一步都可回頭、可重試，避免一鍵全跑造成無法收拾的後果。

## 這裡面有什麼

| 檔案 | 用途 |
| --- | --- |
| [`upgrader.sh`](./upgrader.sh) | EPAS 升級／安裝互動工具，支援小版本升級、大版本升級（含 EFM 叢集處理）、全新安裝三種流程 |
| [`mirror_edb_repo.sh`](./mirror_edb_repo.sh) | 在有網路的機器上，依指定版本把 EPAS 套件打包成離線 repo，供 air-gapped 客戶端安裝/升級用 |
| [`check_version.sh`](./check_version.sh) | 查詢某個 EPAS 大版本在目前機器的 repo 裡實際有多少小版本可抓，只查詢不下載，給容量評估用 |
| [`who_running.sh`](./who_running.sh) | 掃描機器上目前正在跑的 Postgres/EDB instance（含對應 systemd service），EDB 與社群版分開偵測 |
| [`efm_check.sh`](./efm_check.sh) | 唯讀檢查本機的 EFM 狀態（是否運作中、是否在 cluster 裡、角色、正在監控哪個 instance），不做任何修復動作 |
| [`epas_patch_notes.py`](./epas_patch_notes.py) | 給定起始/結束版本，自動從 EDB 官方文件站抓取這段區間內所有版本的 release note，整理成一份 Markdown |

## upgrader.sh — 升級/安裝互動工具

最核心的一支。核心設計原則：

- **任何一步失敗都不會直接把整支腳本結束掉。** 會問你要重試這一步（所有參數重新輸入一次）還是中止整個流程，前面已完成的步驟不受影響——升級中途最怕的就是「一個輸入錯誤或指令失敗就被踢出腳本」，此時往往已經改了一半系統狀態，卻沒有回頭路。
- **全程即時寫 log**，即使腳本中途 crash，log 也已經落地，可事後查。任何一個確認提示都可以輸入 `--show-logs` 直接看目前為止的完整記錄，看完會重新問同一題，不會打斷流程。
- **小版本升級**：EFM 的關閉/開啟分開處理，每次只處理一台機器，依 Witness → Standby → Primary 的順序逐台確認角色與前面節點狀態；整個叢集升級完後，再對每台機器分別執行 `--reopen-efm`。
- **大版本升級**：一律從 Primary 開始執行，用資料目錄下有無 `standby.signal` 判斷角色（並會請使用者二次確認），Primary 用 `pg_upgrade`，Standby 等 Primary 完成後用 `pg_basebackup` 整個重建，過程中所有版本號（含 minor/point 版本）在檔名、repo id、systemd service 名稱、replication slot 名稱中都寫到最完整，避免多版本並存時互相搞混。

```bash
./upgrader.sh                # 跑一次完整的升級/安裝互動流程
./upgrader.sh --reopen-efm   # 整個叢集升級完成後，在每台機器上個別執行
./upgrader.sh -h|--help      # 顯示說明
```

## mirror_edb_repo.sh — 離線 repo 打包

在**有網路、有 EDB 訂閱權限**的機器上執行（不是在客戶端跑），依你指定的版本把 EPAS 套件及其依賴打包成離線 repo，給 air-gapped 環境用。

兩個踩過坑後才有的設計決定：

1. **只抓「這次要用的版本」，不預先囤積整個版本矩陣。** EDB 每個大版本底下小版本數量不少（實測某版本就有 17 個），全部囤起來體積會大到不合理，也大部分用不到。
2. **用容器（podman/docker）打包，而不是直接在工作機上對系統的 `dnf` 下載。** `dnf download --resolve` 算的是「這台機器現在裝了什麼」，不是「一台乾淨的目標機器需要什麼」——工作機上裝的其他套件會讓 `--resolve` 誤判已滿足依賴、漏抓套件，搬到客戶端才爆炸。每次用乾淨的基底映像跑，從根本上避開這個問題。

執行前需要：podman（或 docker）、`createrepo_c`（裝在 host，不是容器裡）；跨架構打包則需要 qemu-user-static + binfmt 支援。實際的 EDB 訂閱 token / repo 設定，因為會隨帳號方案變動，需要自行填入腳本內的 `EDB_REPO_TOKEN` 等設定區。

## check_version.sh — 版本清單查詢

```bash
./check_version.sh 15                        # 查 edb-as15-server 有幾個版本
./check_version.sh 15 edb-as15-server-contrib # 查其他套件
```

只查詢、不下載任何 rpm。用 `dnf repoquery --showduplicates` 列出目前機器上已設定 repo 裡的完整版本清單，並統計「不重複版本數 × 架構數」，方便在打包離線 repo 前先評估大概要花多少容量，而不是打包到一半才發現裝不下。

## who_running.sh — 目前正在跑的 Postgres/EDB instance 掃描

```bash
./who_running.sh
```

透過 `/proc/<pid>/exe`、`/proc/<pid>/cmdline` 找出機器上所有正在跑的 `edb-postgres`（EDB Postgres Advanced Server）與 `postgres`（社群版）主程序，列出每一個的 PID、資料目錄、port（直接讀 `postmaster.pid` 第 4 行，不用去猜設定檔裡有沒有寫）、版本號，並列出 systemd 認得的對應 service 與其狀態。EDB 與社群版分開偵測、分開顯示，沒偵測到的區塊不會印出來；一台機器上同時跑多個 instance（不同大版本、不同 cluster）也能正確全部列出。結果會同時印在畫面上，並存一份到 `/root/pg_precheck_<時間戳記>.log`。

## efm_check.sh — EFM 狀態唯讀檢查

```bash
./efm_check.sh
```

給健檢用，純粹讀取狀態，**不執行任何修復或重啟動作**。針對這台機器上每一個偵測到的 EFM cluster，依序檢查四件事：是否有 EFM 在跑、這台機器是否在這個 cluster 裡（比對 `efm.properties` 裡的 `bind.address` 與 `cluster-status` 輸出）、角色是 Primary/Standby/Witness/Idle 哪一種、目前實際在監控哪一個 Postgres instance（比對 `db.data.dir` 與目前正在跑的 process）。一台機器上有多個 EFM cluster（例如正式環境跟測試 cluster 並存）會逐一檢查、分開列出。

## epas_patch_notes.py — Release note 彙整

大版本升級前，常需要列一份「這幾個版本之間到底改了什麼」給自己或客戶比對。這支腳本會自動到 EDB 官方文件站抓取指定版本區間內、每個版本的 release note（含 Upstream merge / Bug fix / Security fix 等分類、CVE 編號、對應 issue 編號），整理成一份 Markdown。

```bash
pip install -r requirements.txt

python3 epas_patch_notes.py --start 16.4 --end 17.5
python3 epas_patch_notes.py --start 16.4 --end 17.5 --out patch_notes.md
python3 epas_patch_notes.py --start 16.4 --end 17.5 --include-start
python3 epas_patch_notes.py --start 16.4 --end 17.5 --list-only
```

| 參數 | 說明 |
| --- | --- |
| `--start` / `--end` | 起始/結束版本，例如 `16.4`、`17.5` |
| `--out` | 輸出檔案路徑，預設 `patch_notes_<start>_to_<end>.md` |
| `--include-start` | 連起始版本自己的 release note 也一併抓進來 |
| `--list-only` | 只列出版本清單跟原始連結，不抓取內文（先看看範圍內有多少版本） |

需要能連上 `https://www.enterprisedb.com`，請在一般有網路存取權限的機器上執行。

## 使用前提醒

這些工具是針對 EDB Postgres Advanced Server 環境寫的維運腳本，涉及升級、資料目錄操作、系統服務等有實際影響的動作。腳本裡已經盡量做了確認提示、log 記錄與可重試設計，但**建議先在測試環境跑過一輪、確認符合自己環境的實際狀況（作業系統版本、EFM 版本、資料目錄路徑慣例等）後再用於正式環境**。腳本本身不含任何內部主機名稱、IP 或憑證，所有環境相關資訊都是執行時互動輸入。

## License

[MIT](./LICENSE)
