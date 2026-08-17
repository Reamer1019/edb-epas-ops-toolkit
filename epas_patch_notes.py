#!/usr/bin/env python3
"""
epas_patch_notes.py — 抓取 EDB Postgres Advanced Server (EPAS) 指定版本區間的官方 release note（patch note）。

用途：大版本升級前，列一份「起始版本到結束版本」之間所有 patch note 給自己
或客戶比對，資料來源是 EDB 官方文件站 (enterprisedb.com/docs/epas/...)。

用法：
    python3 epas_patch_notes.py --start 16.4 --end 17.5
    python3 epas_patch_notes.py --start 16.4 --end 17.5 --out patch_notes.md
    python3 epas_patch_notes.py --start 16.4 --end 17.5 --include-start
    python3 epas_patch_notes.py --start 16.4 --end 17.5 --list-only

參數：
    --start         起始版本，例如 16.4（大版本.小版本，patch/release tag 會被忽略）
    --end           結束版本，例如 17.5
    --out           輸出檔案路徑，預設 patch_notes_<start>_to_<end>.md
    --include-start 預設只抓「大於起始版本、小於等於結束版本」的 patch note
                    （也就是「從起始版本升到結束版本，中間到底改了什麼」）；
                    加這個參數的話，起始版本自己的 release note 也會一併抓進來。
    --list-only     只列出版本號、發行日期、原始連結，不抓取每份 release note
                    的實際內容（比較快，先看看範圍內有多少版本）。

注意：
    這支腳本需要能連上 https://www.enterprisedb.com，請在有一般網際網路存取
    權限的機器上執行（例如自己的筆電/跳板機），不是設計給資料庫主機用的。
"""

import argparse
import re
import sys
from dataclasses import dataclass, field

try:
    import requests
    from bs4 import BeautifulSoup
except ImportError:
    print("缺少必要套件，請先安裝：pip3 install requests beautifulsoup4", file=sys.stderr)
    sys.exit(1)

BASE = "https://www.enterprisedb.com"
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; epas-patch-notes-script/1.0)"}
VER_RE = re.compile(r"^(\d+)\.(\d+)")


@dataclass
class ReleaseEntry:
    major: int
    minor: int
    version_label: str  # 官方標示的版本字串，例如 "17.5" 或 "17.11.0"
    date: str
    url: str
    body_md: str = field(default="", repr=False)


def parse_version(s: str):
    """把 '16.4'、'17.5.0' 這類字串解析成 (major, minor) tuple，用來做範圍比較。"""
    m = VER_RE.match(s.strip())
    if not m:
        raise ValueError(f"無法解析版本號：{s!r}，格式要像 16.4 或 17.5")
    return int(m.group(1)), int(m.group(2))


def fetch(url: str) -> BeautifulSoup:
    resp = requests.get(url, headers=HEADERS, timeout=30)
    resp.raise_for_status()
    return BeautifulSoup(resp.text, "html.parser")


def get_major_overview_entries(major: int):
    """
    抓 /docs/epas/<major>/epas_rel_notes/ 這個總覽頁，回傳這個大版本底下
    所有列出來的點版本 (version_label, date, url)。總覽頁裡有一個
    Version/Release date/Upstream merges 的表格，第一欄的連結文字就是版本號
    跟該版本 release note 的網址。
    """
    url = f"{BASE}/docs/epas/{major}/epas_rel_notes/"
    try:
        soup = fetch(url)
    except requests.HTTPError as e:
        print(f"  [警告] 抓不到大版本 {major} 的總覽頁（{url}）：{e}", file=sys.stderr)
        return []
    except requests.RequestException as e:
        print(f"  [錯誤] 連線失敗（{url}）：{e}", file=sys.stderr)
        return []

    entries = []
    # 總覽頁上通常有好幾個表格（左側導覽選單有時也是表格），逐一找含有
    # 版本號連結（href 裡有 epas_rel_notes/epas<major>_）的那些列，
    # 不要假設一定是「第一個 table」，比較不會因為頁面排版微調就壞掉。
    for table in soup.find_all("table"):
        for row in table.find_all("tr"):
            cells = row.find_all(["td", "th"])
            if not cells:
                continue
            link = cells[0].find("a")
            if not link or not link.get("href"):
                continue
            href = link["href"]
            if f"/epas/{major}/epas_rel_notes/epas" not in href:
                continue
            version_label = link.get_text(strip=True)
            date = cells[1].get_text(strip=True) if len(cells) > 1 else ""
            full_url = href if href.startswith("http") else BASE + href
            entries.append((version_label, date, full_url))

    if not entries:
        print(f"  [警告] 在 {url} 沒有解析到任何版本列表，這個大版本可能沒有這個表格，"
              f"或是頁面結構跟預期不一樣，需要人工檢查。", file=sys.stderr)
    return entries


def _in_chrome(el) -> bool:
    """判斷這個元素是不是包在 <nav>/<footer>/<header> 這類版面裝飾區塊裡面。"""
    return (
        el.find_parent("nav") is not None
        or el.find_parent("footer") is not None
        or el.find_parent("header") is not None
    )


def extract_release_note_body(soup: BeautifulSoup) -> str:
    """
    從單一版本的 release note 頁面萃取正文，轉成簡單的 Markdown。

    先前用「從 <h1> 開始沿著兄弟節點往下走，直到遇到疑似頁尾/導覽的內容」
    這個策略試了兩次，實際頁面的 DOM 結構跟猜測的不一樣，兩次都撈到左側
    選單或完全落空。改用不依賴節點順序/巢狀關係猜測的作法：
      1. 直接在全頁面找「以 Released: 開頭」的段落（那是版本發布日期）。
      2. 直接在全頁面找所有不在 nav/footer/header 裡的 <table>，且欄位數
         看起來像是實際內容表格（不是純版本清單那種每列只有一個版本連結）。
    這樣不管標題、選單、正文實際包在哪一層 DOM 裡，只要不是被排除的
    nav/footer/header，都抓得到。
    """
    parts = []

    for p in soup.find_all(["p", "li"]):
        if _in_chrome(p):
            continue
        t = p.get_text(" ", strip=True)
        if t.lower().startswith("released:"):
            parts.append(f"**{t}**")
            break

    for table in soup.find_all("table"):
        if _in_chrome(table):
            continue
        rows = table.find_all("tr")
        if not rows:
            continue
        first_row_cells = rows[0].find_all(["td", "th"])
        # 純版本清單的表格第一欄幾乎都是 "16.5" 這種版本號連結；真正的內容
        # 表格（Type/Description/Addresses）欄位數通常 >= 2，且不會每一列
        # 的第一格都符合版本號格式，用這個粗略排除總覽頁那種表格。
        if len(first_row_cells) < 2:
            continue
        col1_texts = [
            r.find_all(["td", "th"])[0].get_text(strip=True)
            for r in rows
            if r.find_all(["td", "th"])
        ]
        looks_like_version_list = col1_texts and all(VER_RE.match(c) for c in col1_texts)
        if looks_like_version_list:
            continue
        parts.append(table_to_markdown(table))

    body = "\n\n".join(p for p in parts if p.strip())
    return body if body.strip() else "（沒有解析到內文，可能頁面結構跟預期不同，請人工檢查原始網址；可以用 --debug-url 把這頁原始 HTML 存下來檢查）"


def table_to_markdown(table) -> str:
    rows = table.find_all("tr")
    if not rows:
        return ""
    lines = []
    for i, row in enumerate(rows):
        cells = row.find_all(["td", "th"])
        cell_text = [c.get_text(" ", strip=True).replace("|", "\\|") for c in cells]
        lines.append("| " + " | ".join(cell_text) + " |")
        if i == 0:
            lines.append("| " + " | ".join(["---"] * len(cells)) + " |")
    return "\n".join(lines)


def collect_entries(start_major, start_minor, end_major, end_minor, include_start):
    all_entries = []
    for major in range(start_major, end_major + 1):
        print(f"抓取大版本 {major} 的版本列表...", file=sys.stderr)
        for version_label, date, url in get_major_overview_entries(major):
            try:
                v_major, v_minor = parse_version(version_label)
            except ValueError:
                print(f"  [警告] 版本標籤 '{version_label}' 格式看不懂，略過（{url}）", file=sys.stderr)
                continue

            lower_ok = (v_major, v_minor) > (start_major, start_minor) or (
                include_start and (v_major, v_minor) == (start_major, start_minor)
            )
            upper_ok = (v_major, v_minor) <= (end_major, end_minor)
            if lower_ok and upper_ok:
                all_entries.append(ReleaseEntry(v_major, v_minor, version_label, date, url))

    all_entries.sort(key=lambda e: (e.major, e.minor))
    return all_entries


def main():
    ap = argparse.ArgumentParser(description="抓取 EDB Postgres Advanced Server 指定版本區間的 release note")
    ap.add_argument("--start", default=None, help="起始版本，例如 16.4（除了 --debug-url 之外都要給）")
    ap.add_argument("--end", default=None, help="結束版本，例如 17.5（除了 --debug-url 之外都要給）")
    ap.add_argument("--out", default=None, help="輸出檔案路徑，預設 patch_notes_<start>_to_<end>.md")
    ap.add_argument("--include-start", action="store_true", help="連起始版本自己的 release note 也抓進來")
    ap.add_argument("--list-only", action="store_true", help="只列版本清單跟連結，不抓正文內容")
    ap.add_argument("--debug-url", default=None,
                     help="除錯用：只抓這個網址的原始 HTML 存成 debug_page.html，不做其他事")
    args = ap.parse_args()

    if args.debug_url:
        resp = requests.get(args.debug_url, headers=HEADERS, timeout=30)
        resp.raise_for_status()
        with open("debug_page.html", "w", encoding="utf-8") as f:
            f.write(resp.text)
        print("已存成 debug_page.html", file=sys.stderr)
        return

    if not args.start or not args.end:
        print("[錯誤] 沒有用 --debug-url 的話，--start 和 --end 都是必填", file=sys.stderr)
        sys.exit(1)

    try:
        start_major, start_minor = parse_version(args.start)
        end_major, end_minor = parse_version(args.end)
    except ValueError as e:
        print(f"[錯誤] {e}", file=sys.stderr)
        sys.exit(1)

    if (start_major, start_minor) > (end_major, end_minor):
        print("[錯誤] 起始版本不能比結束版本新", file=sys.stderr)
        sys.exit(1)

    entries = collect_entries(start_major, start_minor, end_major, end_minor, args.include_start)

    if not entries:
        print("在指定範圍內沒有抓到任何版本，請確認版本號輸入是否正確，"
              "或該大版本的 release note 頁面結構是否有變動。", file=sys.stderr)
        sys.exit(1)

    print(f"\n在 {args.start} ~ {args.end} 範圍內找到 {len(entries)} 個版本：", file=sys.stderr)
    for e in entries:
        print(f"  - {e.version_label}  ({e.date})  {e.url}", file=sys.stderr)

    if args.list_only:
        return

    out_path = args.out or f"patch_notes_{args.start}_to_{args.end}.md"
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(f"# EDB Postgres Advanced Server Patch Notes：{args.start} → {args.end}\n\n")
        f.write(f"（資料來源：EDB 官方文件 https://www.enterprisedb.com/docs/epas/ ，"
                f"共 {len(entries)} 個版本，"
                f"{'含' if args.include_start else '不含'}起始版本自身的 release note）\n\n")
        f.write("---\n\n")
        for e in entries:
            print(f"抓取 {e.version_label} 的內容...", file=sys.stderr)
            try:
                soup = fetch(e.url)
                body = extract_release_note_body(soup)
            except requests.RequestException as ex:
                body = f"（抓取失敗：{ex}）"
            f.write(f"## {e.version_label}（發行日期：{e.date}）\n\n")
            f.write(f"來源：{e.url}\n\n")
            f.write(body)
            f.write("\n\n---\n\n")

    print(f"\n完成，輸出檔案：{out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
