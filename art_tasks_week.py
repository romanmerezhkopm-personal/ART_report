"""Art tasks created in a date range across an Asana portfolio, grouped by project -> PDF.

Used by the /art_tasks_week_report skill (D:\\project\\.claude\\skills\\art_tasks_week_report).

    python art_tasks_week.py --from 2026-10-12 --to 2026-10-16 [--portfolio GID|URL] [--out PATH.pdf] [--open-only]

Dates are inclusive, Europe/Kyiv local time, and REQUIRED — there is deliberately no default
period: Roman asked that the range is always confirmed with him before a run (18.10.2026).

Art task = the department prefix of the name is 2D / 3D / VFX / ANIM (see art_prefix()).
Tasks are found by a workspace-wide search on created_at (catches subtasks of milestones and
features, which are not members of the game project themselves), then attributed to the
portfolio project through their parent chain. Top-level tasks of every portfolio project are
cross-checked against the search result. Read-only: nothing is written to Asana.

The PDF is rendered by printing an HTML page with headless Edge (no reportlab on this machine,
links stay clickable) and is re-read with pypdf afterwards to confirm every task has its link.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, time as dtime, timedelta, timezone
from html import escape
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = "https://app.asana.com/api/1.0"
WORKSPACE = "1210983682540893"
DEFAULT_PORTFOLIO = "1213817629046220"  # Active Portfolio Games
KYIV = ZoneInfo("Europe/Kyiv")
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

LEADING_TAGS_RE = re.compile(r"^\s*((?:\[[^\]]*\]\s*)+)")
TAG_RE = re.compile(r"\[([^\]]*)\]")
ART_TOKEN_RE = re.compile(r"^\s*(2D|3D|VFX|ANIM)\b", re.I)
NEAR_MISS_RE = re.compile(r"\b(2D|3D|VFX|ANIM|art|арт|animation|анимац|анімац)", re.I)

TASK_FIELDS = ("name,created_at,permalink_url,completed,assignee.name,parent.gid,parent.name,"
               "memberships.project.gid,memberships.project.name")


def art_prefix(name):
    """Art department of a task by its name prefix (2D/3D/VFX/ANIM), else None.

    Naming format is "[DEP] [TYPE] title": the department is one of the LEADING [..] tags and
    starts with the token — "[2D ART] …", "[3D ART] …", "[2D ASO Icon Promo Art] …", "[Bug] [2D] …".
    Without leading tags the name itself may start with it — "2D иконка …".
    A token outside the leading tags is not a prefix: "[DEV] 3D model import" is a DEV task.
    "[Animation] …" does not count: the department code is ANIM (asana_naming_glossary).
    """
    m = LEADING_TAGS_RE.match(name or "")
    if m:
        for tag in TAG_RE.findall(m.group(1)):
            t = ART_TOKEN_RE.match(tag)
            if t:
                return t.group(1).upper()
        return None
    t = ART_TOKEN_RE.match(name or "")
    return t.group(1).upper() if t else None


def utc_bounds(d_from, d_to):
    """[start, end) in UTC for Kyiv calendar days d_from..d_to inclusive (DST-aware)."""
    start = datetime.combine(d_from, dtime.min, KYIV).astimezone(timezone.utc)
    end = datetime.combine(d_to + timedelta(days=1), dtime.min, KYIV).astimezone(timezone.utc)
    return start, end


def iso_z(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def short_project(name):
    """'RiC: [com.unrealgames…]' -> 'RiC'; keeps the name if nothing is left."""
    s = re.sub(r"\s*[\[<].*$", "", name or "").rstrip(" :")
    return s or (name or "").strip()


# ---------------------------------------------------------------- Asana API (read-only)

_PAT = None


def _pat():
    global _PAT
    if _PAT is None:
        _PAT = open(os.path.join(HERE, "asana_pat.txt"), encoding="utf-8").read().strip()
    return _PAT


def api_get(path, params=None):
    url = BASE + path + ("?" + urllib.parse.urlencode(params) if params else "")
    last = None
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={"Authorization": "Bearer " + _pat()})
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(int(e.headers.get("Retry-After", "5")))
                continue
            raise RuntimeError(f"GET {path} -> {e.code} {e.read()[:300]!r}")
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            last = e
            time.sleep(2 ** attempt)
    raise RuntimeError(f"too many retries: {path} ({last})")


def paged(path, params):
    out, params = [], dict(params, limit=100)
    while True:
        res = api_get(path, params)
        out.extend(res["data"])
        nxt = res.get("next_page")
        if not nxt:
            return out
        params["offset"] = nxt["offset"]


def portfolio_projects(root):
    """gid -> {name, archived, path} for every project under the portfolio, nested ones included."""
    projects, seen = {}, set()

    def walk(pf, path):
        if pf in seen:
            return
        seen.add(pf)
        for it in paged(f"/portfolios/{pf}/items", {"opt_fields": "name,archived,resource_type"}):
            if it["resource_type"] == "portfolio":
                walk(it["gid"], path + [it["name"]])
            elif it["resource_type"] == "project":
                projects.setdefault(it["gid"], {"name": it["name"].strip(), "archived": it.get("archived"),
                                                "path": " / ".join(path)})
    walk(root, [])
    return projects


def search_created(start, end):
    """All workspace tasks created in [start, end). The search API caps a page at 100 and has no
    offset paging, so the window slides by created_at (1 ms overlap, deduplicated by gid)."""
    found, after = {}, start - timedelta(milliseconds=1)
    while True:
        page = api_get(f"/workspaces/{WORKSPACE}/tasks/search", {
            "created_at.after": iso_z(after), "created_at.before": iso_z(end),
            "sort_by": "created_at", "sort_ascending": "true", "limit": 100, "opt_fields": TASK_FIELDS})["data"]
        new = [t for t in page if t["gid"] not in found]
        for t in page:
            found[t["gid"]] = t
        if len(page) < 100 or not new:
            return found
        after = parse_ts(page[-1]["created_at"]) - timedelta(milliseconds=1)


# ---------------------------------------------------------------- report

def collect(d_from, d_to, portfolio):
    start, end = utc_bounds(d_from, d_to)
    projects = portfolio_projects(portfolio)
    found = search_created(start, end)
    searched = len(found)

    cross_total, cross_missing = 0, 0
    for pg in projects:
        for t in paged(f"/projects/{pg}/tasks", {"opt_fields": TASK_FIELDS, "completed_since": iso_z(start)}):
            if start <= parse_ts(t["created_at"]) < end:
                cross_total += 1
                if t["gid"] not in found:
                    cross_missing += 1
                    found[t["gid"]] = t

    parents = {}

    def home(t, depth=0):
        for m in t.get("memberships") or []:
            if m["project"]["gid"] in projects:
                return m["project"]["gid"]
        p = (t.get("parent") or {}).get("gid")
        if not p or depth > 8:
            return None
        if p not in parents:
            parents[p] = api_get(f"/tasks/{p}", {"opt_fields": "name,parent.gid,memberships.project.gid"})["data"]
        return home(parents[p], depth + 1)

    art, outside, near_miss = [], [], []
    for t in found.values():
        tag = art_prefix(t["name"])
        if not tag and not NEAR_MISS_RE.search(t["name"] or ""):
            continue
        pg = home(t)
        rec = {"gid": t["gid"], "name": re.sub(r"\s+", " ", t["name"]).strip(), "url": t["permalink_url"],
               "art": tag, "created_at": t["created_at"],
               "created_kyiv": parse_ts(t["created_at"]).astimezone(KYIV).strftime("%d.%m.%Y %H:%M"),
               "assignee": (t.get("assignee") or {}).get("name"), "completed": t["completed"],
               "parent": (t.get("parent") or {}).get("name"),
               "project_gid": pg, "project": short_project(projects[pg]["name"]) if pg else None,
               "memberships": [m["project"]["name"].strip() for m in t.get("memberships") or []]}
        if tag and pg:
            art.append(rec)
        elif tag:
            outside.append(rec)
        elif pg:
            near_miss.append(rec)
    key = lambda r: ((r["project"] or "").lower(), r["created_at"])
    return {"from": d_from.isoformat(), "to": d_to.isoformat(), "portfolio": portfolio,
            "utc_start": iso_z(start), "utc_end": iso_z(end),
            "generated": datetime.now(KYIV).strftime("%d.%m.%Y %H:%M"),
            "projects_in_portfolio": len(projects), "searched": searched,
            "cross_check": {"top_level_in_range": cross_total, "missing_from_search": cross_missing},
            "art": sorted(art, key=key), "outside": sorted(outside, key=lambda r: r["created_at"]),
            "near_miss": sorted(near_miss, key=key)}


def only_open(data):
    """--open-only: drop completed tasks from every list; completion is as of this run (Roman, 23.10.2026)."""
    kept = dict(data, open_only=True)
    kept["dropped_completed"] = sum(r["completed"] for k in ("art", "outside") for r in data[k])
    for k in ("art", "outside", "near_miss"):
        kept[k] = [r for r in data[k] if not r["completed"]]
    return kept


CSS = """
@page { size: A4; margin: 14mm 12mm; }
body { font-family: 'Segoe UI', Arial, sans-serif; font-size: 10.5pt; color: #1f2328; }
h1 { font-size: 17pt; margin: 0 0 4px; }
.meta { color: #59636e; font-size: 9pt; margin-bottom: 14px; }
.summary { background: #f3f5f8; border-radius: 6px; padding: 8px 12px; margin-bottom: 14px; }
.sec { break-inside: avoid; }
h2 { font-size: 12.5pt; margin: 18px 0 6px; border-bottom: 2px solid #d0d7de; padding-bottom: 3px; }
td.task { width: 55%; }
table.wp td.task { width: 38%; }
table.wp td.proj { width: 30%; }
h2 .n { color: #59636e; font-weight: normal; }
table { width: 100%; border-collapse: collapse; page-break-inside: auto; }
tr { page-break-inside: avoid; }
th { text-align: left; font-size: 9pt; color: #59636e; border-bottom: 1px solid #d0d7de; padding: 4px 6px; }
td { border-bottom: 1px solid #eaeef2; padding: 4px 6px; vertical-align: top; }
td.c { white-space: nowrap; width: 1%; }
a { color: #0b57d0; text-decoration: none; }
.tag { display: inline-block; font-size: 8pt; font-weight: 600; padding: 0 5px; border-radius: 3px;
       background: #e7ecf7; color: #2b4a8b; }
.note { color: #59636e; font-size: 9pt; }
"""


def rows_html(items, with_project=False):
    out = [("<table class=\"wp\">" if with_project else "<table>") + "<tr><th>Задача</th>" +
           ("<th>Проект</th>" if with_project else "") +
           "<th>Тип</th><th>Создана</th><th>Исполнитель</th></tr>"]
    for r in items:
        out.append("<tr><td class=\"task\"><a href=\"%s\">%s</a></td>%s<td class=\"c\"><span class=\"tag\">%s</span></td>"
                   "<td class=\"c\">%s</td><td class=\"c\">%s</td></tr>" % (
                       escape(r["url"]), escape(r["name"]),
                       ("<td class=\"proj\">%s</td>" % escape(", ".join(short_project(m) for m in r["memberships"]) or "—"))
                       if with_project else "",
                       escape(r["art"]), escape(r["created_kyiv"][:5]), escape(r["assignee"] or "—")))
    out.append("</table>")
    return "\n".join(out)


def build_html(data, portfolio_name):
    d1 = date.fromisoformat(data["from"]).strftime("%d.%m.%Y")
    d2 = date.fromisoformat(data["to"]).strftime("%d.%m.%Y")
    groups = {}
    for r in data["art"]:
        groups.setdefault(r["project"], []).append(r)
    by_tag = {}
    for r in data["art"]:
        by_tag[r["art"]] = by_tag.get(r["art"], 0) + 1
    parts = [f"<html><head><meta charset=\"utf-8\"><title>Арт-задачи {d1}–{d2}</title><style>{CSS}</style></head><body>",
             f"<h1>{'Незакрытые арт-задачи' if data.get('open_only') else 'Арт-задачи'}, созданные {d1} – {d2}</h1>",
             f"<div class=\"meta\">Портфель: {escape(portfolio_name)} · префиксы 2D / 3D / VFX / ANIM · "
             + (f"без закрытых на момент выгрузки (убрано {data['dropped_completed']}) · " if data.get("open_only") else "") +
             f"время киевское · сформировано {escape(data['generated'])}</div>",
             "<div class=\"summary\"><b>%d</b> задач в <b>%d</b> проектах%s</div>" % (
                 len(data["art"]), len(groups),
                 (" · " + ", ".join(f"{k}: {v}" for k, v in sorted(by_tag.items()))) if by_tag else "")]
    if not groups:
        parts.append("<p>За этот период арт-задач в проектах портфеля не создавали.</p>")
    for proj, items in sorted(groups.items(), key=lambda x: x[0].lower()):
        parts.append(f"<div class=\"sec\"><h2>{escape(proj)} <span class=\"n\">— {len(items)}</span></h2>")
        parts.append(rows_html(items) + "</div>")
    if data["outside"]:
        parts.append(f"<div class=\"sec\"><h2>Вне портфеля <span class=\"n\">— {len(data['outside'])}</span></h2>")
        parts.append("<p class=\"note\">Арт-задачи того же периода в проектах, которых нет в портфеле — для справки.</p>")
        parts.append(rows_html(data["outside"], with_project=True) + "</div>")
    parts.append("</body></html>")
    return "\n".join(parts)


def html_to_pdf(html, pdf_path):
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        html_path = os.path.join(tmp, "report.html")
        with open(html_path, "w", encoding="utf-8") as f:
            f.write(html)
        if os.path.exists(pdf_path):
            os.remove(pdf_path)
        subprocess.run([EDGE, "--headless", "--disable-gpu", "--no-pdf-header-footer",
                        f"--user-data-dir={os.path.join(tmp, 'profile')}", f"--print-to-pdf={pdf_path}",
                        "file:///" + html_path.replace("\\", "/")],
                       check=True, timeout=180, capture_output=True)
    if not os.path.exists(pdf_path):
        raise RuntimeError("Edge did not produce the PDF")


def verify_pdf(pdf_path, data):
    """Re-read the written PDF: every task must have its clickable link."""
    from pypdf import PdfReader
    reader = PdfReader(pdf_path)
    uris = set()
    for page in reader.pages:
        for a in page.get("/Annots") or []:
            a = a.get_object()
            uri = (a.get("/A") or {}).get("/URI")
            if uri:
                uris.add(str(uri))
    expected = {r["url"] for r in data["art"] + data["outside"]}
    missing = expected - uris
    return len(reader.pages), len(uris & expected), sorted(missing)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="d_from", required=True, help="first day, YYYY-MM-DD (Kyiv), inclusive")
    ap.add_argument("--to", dest="d_to", required=True, help="last day, YYYY-MM-DD (Kyiv), inclusive")
    ap.add_argument("--portfolio", default=DEFAULT_PORTFOLIO, help="portfolio GID or URL (default: Active Portfolio Games)")
    ap.add_argument("--out", help="PDF path (default: art_tasks_week_<from>_<to>[_open].pdf next to this script)")
    ap.add_argument("--open-only", action="store_true", help="keep only tasks that are not completed at run time")
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")

    d_from, d_to = date.fromisoformat(a.d_from), date.fromisoformat(a.d_to)
    if d_to < d_from:
        ap.error("--to is earlier than --from")
    m = re.search(r"portfolio/(\d+)", a.portfolio)
    portfolio = m.group(1) if m else a.portfolio.strip()
    suffix = "_open" if a.open_only else ""
    out = os.path.abspath(a.out or os.path.join(HERE, f"art_tasks_week_{d_from}_{d_to}{suffix}.pdf"))

    data = collect(d_from, d_to, portfolio)
    if a.open_only:
        data = only_open(data)
    pf_name = api_get(f"/portfolios/{portfolio}", {"opt_fields": "name"})["data"]["name"]
    with open(os.path.splitext(out)[0] + ".json", "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    html_to_pdf(build_html(data, pf_name), out)
    pages, linked, missing = verify_pdf(out, data)

    print(f"Period {d_from}..{d_to} (Kyiv) = UTC {data['utc_start']} .. {data['utc_end']}")
    print(f"Portfolio {pf_name}: {data['projects_in_portfolio']} projects; searched {data['searched']} tasks created in range")
    cc = data["cross_check"]
    print(f"Cross-check: {cc['top_level_in_range']} top-level portfolio tasks in range, {cc['missing_from_search']} missing from search (added)")
    if data.get("open_only"):
        print(f"Filter: open only — {data['dropped_completed']} completed art tasks dropped")
    print(f"Art tasks in portfolio: {len(data['art'])}; outside portfolio: {len(data['outside'])}; "
          f"near misses to review: {len(data['near_miss'])}")
    for r in data["near_miss"]:
        print(f"  near miss: {r['project']} | {r['name']} | {r['url']}")
    print(f"PDF: {out} ({pages} pages), links {linked}/{len(data['art']) + len(data['outside'])}"
          + (f" — MISSING {len(missing)}" if missing else " — OK"))
    if missing:
        sys.exit(2)


if __name__ == "__main__":
    main()
