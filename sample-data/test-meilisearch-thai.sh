#!/usr/bin/env bash
# ==============================================================================
# Meilisearch + Charabia (thai-tcc-engine) Verification Suite
# ==============================================================================
# ทดสอบการตั้งค่า 01-index-settings/04-full-thai-settings.json และข้อมูลตัวอย่าง
# sample-data/articles.json บนอิมเมจ kamthorn/meilisearch:v1.56.0
#
# Usage:
#   MEILI_URL=http://localhost:7700 MEILI_MASTER_KEY=masterKey123456789 \
#     ./sample-data/test-meilisearch-thai.sh
# ==============================================================================
set -euo pipefail

export MEILI_URL="${MEILI_URL:-http://localhost:7700}"
export MEILI_MASTER_KEY="${MEILI_MASTER_KEY:-masterKey123456789}"
export INDEX_NAME="${INDEX_NAME:-thai_articles_demo}"

cd "$(dirname "$0")/.."

until curl -sf "${MEILI_URL}/health" > /dev/null; do
    echo "Waiting for Meilisearch at ${MEILI_URL}..."
    sleep 2
done

python3 - <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

URL = os.environ["MEILI_URL"].rstrip("/")
KEY = os.environ["MEILI_MASTER_KEY"]
INDEX = os.environ["INDEX_NAME"]
failures = []


def call(method, path, body=None):
    data = None
    headers = {"Authorization": f"Bearer {KEY}"}
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(URL + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw.decode("utf-8")) if raw else {}
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="replace")
        try:
            return json.loads(raw)
        except Exception:
            return {"error": raw, "status": err.code}


def wait_task(task_obj):
    uid = task_obj.get("taskUid")
    if uid is None:
        return
    for _ in range(120):
        res = call("GET", f"/tasks/{uid}")
        status = res.get("status")
        if status == "succeeded":
            return
        if status in ("failed", "canceled"):
            sys.exit(f"Task {uid} {status}: {json.dumps(res, ensure_ascii=False)}")
        time.sleep(0.25)
    sys.exit(f"Timed out waiting for task {uid}")


def check(label, ok, detail=""):
    print(("PASS: " if ok else "FAIL: ") + label + (f"  {detail}" if detail else ""))
    if not ok:
        failures.append(label)


def search(q, **kwargs):
    payload = {"q": q, "matchingStrategy": "all", **kwargs}
    res = call("POST", f"/indexes/{INDEX}/search", payload)
    if "hits" not in res:
        sys.exit("Search failed: " + json.dumps(res, ensure_ascii=False))
    return [h["id"] for h in res["hits"]], res


# ---------- 1. Recreate index, apply settings, load documents ----------
call("DELETE", f"/indexes/{INDEX}")
time.sleep(0.5)
wait_task(call("POST", "/indexes", {"uid": INDEX, "primaryKey": "id"}))

settings = json.load(open("01-index-settings/04-full-thai-settings.json", encoding="utf-8"))
wait_task(call("PATCH", f"/indexes/{INDEX}/settings", settings))

docs = json.load(open("sample-data/articles.json", encoding="utf-8"))
wait_task(call("POST", f"/indexes/{INDEX}/documents", docs))
print(f"Index '{INDEX}' configured and {len(docs)} documents indexed.\n")

# ---------- 2. Test A: Decomposed Sara Am Normalization ----------
print("=== Test A: Decomposed Sara Am (U+0E4D + tone + U+0E32) Normalization ===")
# Document 1 stores "นํ้าเสีย" using U+0E19 U+0E4D U+0E49 U+0E32
ids_composed, res_composed = search(
    "น้ำเสีย",
    attributesToHighlight=["title_th"],
    highlightPreTag="<mark>",
    highlightPostTag="</mark>",
)
ids_decomposed, _ = search("น\u0e4d\u0e49าเสีย")
ids_reordered, _ = search("น\u0e33\u0e49เสีย")

check("Standard 'น้ำเสีย' (U+0E49 U+0E33) finds doc '1' stored with decomposed 'นํ้าเสีย'",
      "1" in ids_composed, str(ids_composed))
check("Decomposed 'นํ้าเสีย' (U+0E4D U+0E49 U+0E32) finds doc '1'",
      "1" in ids_decomposed, str(ids_decomposed))
check("Reordered 'นำ้เสีย' (U+0E33 U+0E49) finds doc '1'",
      "1" in ids_reordered, str(ids_reordered))
hl_doc1 = res_composed["hits"][0]["_formatted"]["title_th"] if res_composed["hits"] else ""
check("Highlighting preserves exact byte offsets on decomposed 'นํ้าเสีย'",
      "<mark>น\u0e4d\u0e49าเสีย</mark>" in hl_doc1, hl_doc1)

# ---------- 3. Test B: Zero-Width Characters Inside Thai Words ----------
print("\n=== Test B: Zero-Width Characters (U+200B, U+200C, U+FEFF) Filtering ===")
# Document 2 contains "ปัญญาประ\u200bดิษฐ์", "อินเทอร์\u200cเน็ต", "การ\ufeffแพทย์"
ids_zwsp, _ = search("ประดิษฐ์")
ids_zwnj, _ = search("อินเทอร์เน็ต")
ids_bom, _ = search("การแพทย์")
check("Searching 'ประดิษฐ์' finds doc '2' despite U+200B inside 'ประ\\u200bดิษฐ์'",
      "2" in ids_zwsp, str(ids_zwsp))
check("Searching 'อินเทอร์เน็ต' finds doc '2' despite U+200C inside 'อินเทอร์\\u200cเน็ต'",
      "2" in ids_zwnj, str(ids_zwnj))
check("Searching 'การแพทย์' finds doc '2' despite U+FEFF (BOM) inside 'การ\\ufeffแพทย์'",
      "2" in ids_bom, str(ids_bom))

# ---------- 4. Test C: Duplicate Combining Marks Deduplication ----------
print("\n=== Test C: Consecutive Duplicate Combining Marks Deduplication ===")
# Document 3 contains "วิิเคราะห์" (double Sara I) and "ข้้้อความ" (triple Mai Tho)
ids_dup1, res_dup1 = search(
    "วิเคราะห์ ข้อความ",
    attributesToHighlight=["title_th"],
    highlightPreTag="<mark>",
    highlightPostTag="</mark>",
)
check("Clean 'วิเคราะห์ ข้อความ' finds doc '3' stored as 'วิิเคราะห์ข้้้อความ'",
      ids_dup1 == ["3"], str(ids_dup1))
hl_doc3 = res_dup1["hits"][0]["_formatted"]["title_th"] if res_dup1["hits"] else ""
check("Highlighting accurately wraps dirty tokens '<mark>วิิเคราะห์</mark><mark>ข้้้อความ</mark>'",
      "<mark>วิิเคราะห์</mark><mark>ข้้้อความ</mark>" in hl_doc3, hl_doc3)

# ---------- 5. Test D: Sub-word / Base Morpheme Dictionary Philosophy ----------
print("\n=== Test D: Sub-word Compound Splitting vs 2-Syllable Base Morpheme Preservation ===")
ids_chemo, _ = search("บำบัด")
ids_microbio, _ = search("ชีววิทยา")
ids_se, _ = search("ซอฟต์แวร์")
ids_care, _ = search("ดูแล")
ids_work, _ = search("ทำงาน")
ids_understand, _ = search("เข้าใจ")
ids_cross_boundary, _ = search('"ดีดู"')

check("Sub-word search 'บำบัด' finds both 'การบำบัด' (doc '1') and 'เคมีบำบัด' (doc '4')",
      {"1", "4"} <= set(ids_chemo), str(ids_chemo))
check("Sub-word search 'ชีววิทยา' finds 'จุลชีววิทยา' (doc '5')",
      "5" in ids_microbio, str(ids_microbio))
check("Sub-word search 'ซอฟต์แวร์' finds 'วิศวกรรมซอฟต์แวร์' (doc '6')",
      "6" in ids_se, str(ids_se))
check("2-syllable base morphemes 'ดูแล', 'ทำงาน', 'เข้าใจ' match docs '7' and '8'",
      "7" in ids_care and "7" in ids_work and "8" in ids_understand,
      f"ดูแล={ids_care}, ทำงาน={ids_work}, เข้าใจ={ids_understand}")
check("Exact phrase '\"ดีดู\"' does NOT falsely match across 'คนดี' + 'ดูแล' in doc '7'",
      ids_cross_boundary == [], str(ids_cross_boundary))

# ---------- 6. Test E: Tone Distinction & Typo Tolerance Safety ----------
print("\n=== Test E: Short Thai Word Tone Safety vs Long Word Typo Tolerance ===")
ids_klong_drum, _ = search("กลอง")
ids_klong_cam, _ = search("กล้อง")
ids_rice, _ = search("ข้าว")
ids_white, _ = search("ขาว")
ids_long_typo1, _ = search("อิเล็กทรอนิกส")
ids_long_typo2, _ = search("คอมพิวเตอร")

check("'กลอง' (4 chars) matches only doc '11' (not 'กล้อง' doc '10')",
      ids_klong_drum == ["11"], str(ids_klong_drum))
check("'กล้อง' (5 chars) matches only doc '10' (not 'กลอง' doc '11')",
      ids_klong_cam == ["10"], str(ids_klong_cam))
check("'ข้าว' (4 chars) matches only doc '9' and 'ขาว' does not falsely match 'ข้าว'",
      ids_rice == ["9"] and ids_white == [], f"ข้าว={ids_rice}, ขาว={ids_white}")
check("Long Thai word (>= 6 chars) typo 'อิเล็กทรอนิกส' still matches doc '12'",
      "12" in ids_long_typo1, str(ids_long_typo1))
check("Long Thai word (>= 6 chars) typo 'คอมพิวเตอร' still matches doc '12'",
      "12" in ids_long_typo2, str(ids_long_typo2))

# ---------- 7. Test F: Bilingual Synonyms & Curated Stop Words ----------
print("\n=== Test F: Bilingual Synonyms & Curated Stop Words ===")
ids_ai, _ = search("เอไอ")
ids_covid, _ = search("sars-cov-2")
ids_bigdata, _ = search("big data")
ids_stopwords, _ = search("การรักษา และ ของ ใน ด้วย เคมีบำบัด")

check("Synonym 'เอไอ' finds 'ปัญญาประดิษฐ์' (doc '2')", "2" in ids_ai, str(ids_ai))
check("Synonym 'sars-cov-2' finds 'โควิด' (doc '4')", "4" in ids_covid, str(ids_covid))
check("Synonym 'big data' finds 'ข้อมูลขนาดใหญ่' (doc '3')", "3" in ids_bigdata, str(ids_bigdata))
check("Stop words ('และ', 'ของ', 'ใน', 'ด้วย') are ignored cleanly in multi-word query",
      ids_stopwords == ["4"], str(ids_stopwords))

# ---------- 8. Test G: Matching Strategy ALL + Fallback LAST with Score Threshold ----------
print("\n=== Test G: Two-Stage Matching Strategy (ALL -> LAST + rankingScoreThreshold) ===")
q_long = "การดูแลผู้สูงอายุในชุมชนเมือง"
ids_strict, _ = search(q_long, matchingStrategy="all")
ids_naive_last, _ = search(q_long, matchingStrategy="last")
ids_guarded_last, _ = search(q_long, matchingStrategy="last", rankingScoreThreshold=0.25)

check("Stage 1 (matchingStrategy='all') returns 0 hits when unseen suffix 'ชุมชนเมือง' is present",
      ids_strict == [], str(ids_strict))
check("Naive matchingStrategy='last' without threshold leaks noisy 'การ' matches across many docs",
      len(ids_naive_last) >= 5, f"{len(ids_naive_last)} docs: {ids_naive_last}")
check("Stage 2 (matchingStrategy='last' + rankingScoreThreshold=0.25) returns relevant doc '7' as top hit without noise flood",
      len(ids_guarded_last) > 0 and ids_guarded_last[0] == "7" and len(ids_guarded_last) < len(ids_naive_last),
      str(ids_guarded_last))

print()
if failures:
    sys.exit(f"{len(failures)} check(s) failed: {failures}")
print("=== All 21 Meilisearch + Charabia Thai checks passed! ===")
PY
