"""Offline test for art_tasks_week.py — real task names from the workspace (18.10.2026).

    python test_art_tasks_week.py
"""
from datetime import date
import art_tasks_week as a

# Must be counted as art tasks: department tag is a leading [..] tag starting with 2D/3D/VFX/ANIM.
MUST_PASS = {
    "[2D ART] <RiC>: <3.14>: <Оновити екран Результатів>": "2D",
    "[3D ART] созвоны по прототипам": "3D",
    "[2D ASO Icon Promo Art]  <bundle_id> Название проекта": "2D",
    "[VFX ART] [VFX] < DriveCSX>: < 1.2.0>: < Environment Activities >": "VFX",
    "[TechArt] [VFX ART] Направляющие стрелочки": "VFX",
    "[ANIM ART] тутор стрілки": "ANIM",
    "VFX - Маршрут-напрямок на трасі після прийняття активності": "VFX",
    # Name-only rule; such tasks live outside the game portfolio and drop out on attribution.
    "[Бєлоусова Тетяна] [2D ART/ UI/UX ART] Недовантажений": "2D",
}

# Must NOT be counted: token is not the department prefix.
MUST_BLOCK = [
    "[Promo Art ASO] Money Maker: Idle Tycoon",          # parent of the 2D ASO subtasks
    "[DEV] Ресерч анимаций и VFX",
    "[DEV] <12.12.15><com.GamesEZ.CarMehanic3D> Android Update",
    "[Dev] < RiC >: < 3.14 >: < Полішинг режима >",
    "[CAS PRODUCT ART] Design new loader animation and default icon to replace the Cat",
    "Кіца Денис  [Animation & VFX] Недовантажений",
    "Володимир Демченко [3D ART] Недовантажений",
    "[DEV] Fix two bosses art + animations",
]

# Kyiv calendar days -> UTC window; 25.10.2026 is the DST switch (UTC+3 -> UTC+2).
BOUNDS = [
    ((date(2026, 10, 12), date(2026, 10, 16)), ("2026-10-11T21:00:00.000Z", "2026-10-16T21:00:00.000Z")),
    ((date(2026, 10, 23), date(2026, 10, 26)), ("2026-10-22T21:00:00.000Z", "2026-10-26T22:00:00.000Z")),
]

PROJECT_NAMES = {
    "RiC: [com.unrealgames.RacinginCar2020 / 1570315891]": "RiC",
    "AI Prototype 1 Money Maker: Idle Tycoon <com.psv.idle_tycoon.money_maker>": "AI Prototype 1 Money Maker: Idle Tycoon",
    "Car Jumping: Crash & Fly [com.psv.crash.fly.car.jumping]": "Car Jumping: Crash & Fly",
    "AI Framework": "AI Framework",
}

# --open-only on real records of the 19–23.10.2026 run: completed ones go, open ones stay (23.10.2026).
REC = lambda gid, name, done: {"gid": gid, "name": name, "completed": done}
OPEN_ONLY_IN = {
    "art": [REC("1219732937109862", "[2D ART] Скин 1 для AI Block Blast", False),
            REC("1219691759490953", "[2D ASO Icon Promo Art] <6824512679> Obby All Games", True)],
    "outside": [REC("1219815099491955", "3D Скопировать / генерировать core gameplay", False)],
    "near_miss": [REC("1219732937109853", "[PO] Подготовка списка необходимого арта", True),
                  REC("1219748864354629", "[CAS REST ART] CAS Publishing | DriveCSX – Product-Led Monetization Case Study Design", False)],
}
OPEN_ONLY_WANT = {"art": ["1219732937109862"], "outside": ["1219815099491955"], "near_miss": ["1219748864354629"],
                  "dropped_completed": 1}


def main():
    fails = 0
    for name, want in MUST_PASS.items():
        got = a.art_prefix(name)
        if got != want:
            fails += 1
            print(f"FAIL pass  {name!r}: {got} != {want}")
    for name in MUST_BLOCK:
        got = a.art_prefix(name)
        if got is not None:
            fails += 1
            print(f"FAIL block {name!r}: {got}")
    for (d1, d2), want in BOUNDS:
        s, e = a.utc_bounds(d1, d2)
        got = (a.iso_z(s), a.iso_z(e))
        if got != want:
            fails += 1
            print(f"FAIL bounds {d1}..{d2}: {got} != {want}")
    for full, want in PROJECT_NAMES.items():
        if a.short_project(full) != want:
            fails += 1
            print(f"FAIL short {full!r}: {a.short_project(full)!r}")
    got = a.only_open(OPEN_ONLY_IN)
    got = {k: [r["gid"] for r in got[k]] for k in ("art", "outside", "near_miss")} | {"dropped_completed": got["dropped_completed"]}
    if got != OPEN_ONLY_WANT:
        fails += 1
        print(f"FAIL open-only: {got} != {OPEN_ONLY_WANT}")
    total = len(MUST_PASS) + len(MUST_BLOCK) + len(BOUNDS) + len(PROJECT_NAMES) + 1
    print(f"{total - fails}/{total} OK")
    raise SystemExit(1 if fails else 0)


if __name__ == "__main__":
    main()
