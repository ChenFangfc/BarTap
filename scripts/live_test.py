#!/usr/bin/env python3
"""Live scenario tests against the real menu bar.

Drives dist/BarTap.app through bartap:// URL commands and checks what every display's menu bar
actually draws (via BarTapProbe). Run with `python3 -I scripts/live_test.py [scenario ...]`.
Leaves BarTap quit and its debug flags removed when done.
"""
import json, os, pathlib, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The installed copy (scripts/build.sh --install), else a build in dist/. Never both: with two
# copies of one bundle ID, bartap:// commands can launch the other copy as a second instance.
INSTALLED = pathlib.Path("/Applications/BarTap.app")
APP = INSTALLED if INSTALLED.exists() else ROOT / "dist/BarTap.app"
if INSTALLED.exists() and (ROOT / "dist/BarTap.app").exists():
    sys.exit("Both /Applications/BarTap.app and dist/BarTap.app exist; use scripts/build.sh --install first.")
PROBE = ROOT / ".build/debug/BarTapProbe"
STATE = pathlib.Path.home() / "Library/Application Support/BarTap/debug-state.json"
CATALOG = pathlib.Path.home() / "Library/Application Support/BarTap/catalog-classified.json"
DOMAIN = "io.github.chenfangfc.BarTap"

passed = failed = 0
notes = []


def sh(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check).stdout


def cmd(c):
    sh("open", "-g", f"bartap://{c}")


def defaults_write(key, kind, value):
    sh("defaults", "write", DOMAIN, key, f"-{kind}", str(value))


def pid():
    out = sh("pgrep", "-x", "BarTap", check=False).split()
    return int(out[0]) if out else None


def state():
    for attempt in range(3):
        try:
            STATE.unlink()
        except FileNotFoundError:
            pass
        cmd("debug/dump")
        for _ in range(60):
            if STATE.exists():
                try:
                    return json.loads(STATE.read_text())
                except json.JSONDecodeError:
                    pass
            time.sleep(0.05)
    raise RuntimeError("BarTap did not answer debug/dump")


def probe():
    return json.loads(sh(str(PROBE)))["screens"]


def wait_until(predicate, timeout, step=0.5):
    """Polls until predicate() is true."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(step)
    return predicate()


def catalog():
    """Icons with their sections, as BarTap classifies them (needs Accessibility)."""
    try:
        CATALOG.unlink()
    except FileNotFoundError:
        pass
    cmd("debug/catalog")
    # Accessibility reads every app's icons; with many apps that can take a few seconds.
    for _ in range(160):
        if CATALOG.exists():
            break
        time.sleep(0.05)
    time.sleep(0.2)
    return json.loads(CATALOG.read_text()) if CATALOG.exists() else []


def wait_for_placement(timeout=20):
    """A (re)placement settles once stats items are back and any correction round is done."""
    time.sleep(1.0)
    settled = wait_until(lambda: not state().get("placementSettling", False), timeout)
    check(settled, "placement settles")
    time.sleep(0.5)


def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print(f"    ✗ {msg}")
    return cond


def launch(fresh=False, wait=3.0):
    quit_app()
    if fresh:
        sh("defaults", "delete", DOMAIN, check=False)
    defaults_write("debugCommands", "bool", "true")
    defaults_write("onboardingShown", "bool", "true")
    sh("open", "-g", str(APP))
    for _ in range(100):
        if pid():
            break
        time.sleep(0.05)
    time.sleep(wait)
    running = sh("pgrep", "-x", "BarTap", check=False).split()
    check(len(running) == 1, f"exactly one BarTap running (found {len(running)})")


def quit_app():
    p = pid()
    if not p:
        return
    sh("kill", "-TERM", str(p), check=False)
    for _ in range(60):
        if not pid():
            break
        time.sleep(0.05)
    if pid():
        sh("kill", "-9", str(pid()), check=False)
    time.sleep(1.0)


def by_name(screens):
    return {s["name"]: s for s in screens}


def summary(screens):
    return ", ".join(f'{s["name"]}: {s["drawn"]}/{len(s["row"])} drawn, {s["separators"]} sep' for s in screens)


def toggle_drawn_everywhere(st, screens):
    """Our toggle (by right-distance/width, as reported by the app) is drawn on every display
    whose bar is visible; a notched display may legitimately hide it."""
    rd, t = st.get("toggleRD", -1), st["frames"]["toggle"]
    if rd < 0 or not t:
        return False
    ok = True
    for s in screens:
        hit = [w for w in s["row"] if abs(w["rd"] - rd) <= 3 and abs(w["w"] - t[2]) <= 3]
        if not hit or not hit[0]["on"]:
            if s["notch"]:
                notes.append(f'toggle not drawn on notched {s["name"]}')
            else:
                ok = False
    return ok


# ---------------------------------------------------------------- scenarios

def after_other_bars_ok(screens):
    # No seeding happened, so our items went to the far left: every external still draws ≥ 10 icons.
    return all(len(s["row"]) >= 10 for s in screens if not s["notch"])


def scenario_first_run():
    print("• first run: placement + start collapsed")
    quit_app()
    before = by_name(probe())
    launch(fresh=True, wait=1.0)
    wait_for_placement()
    st, after = state(), probe()
    print(f"    before: {summary(before.values())}")
    print(f"    after:  {summary(after)}")
    check(st["effectiveLevel"] == "collapsed", f'level {st["effectiveLevel"]}')
    check(st["layoutProblem"] == "", f'problem {st["layoutProblem"]}')
    check(not st["toggleUndrawn"], "toggle undrawn")
    check(toggle_drawn_everywhere(st, after), "toggle drawn on every non-notched display")
    for s in after:
        b = before.get(s["name"])
        check(s["separators"] >= 1, f'{s["name"]}: collapsed separator present')
        if s["notch"] and b and b["drawn"] == 0:
            notes.append(f'{s["name"]} bar not visible (asleep/full screen): placement must ignore it')
            check(after_other_bars_ok(after), "with the notched bar asleep, nothing extra was hidden on other displays")
        elif s["notch"] and b:
            # Do no harm: everything that was drawn stays drawn, except ≤1 icon moved to make room.
            check(s["drawn"] >= b["drawn"], f'{s["name"]}: drawn {s["drawn"]} < before {b["drawn"]}')
            check(s["drawn"] == len(s["row"]), f'{s["name"]}: something still behind the notch')


def scenario_show_hide():
    print("• show / hide / show all")
    base = by_name(probe())
    cmd("show"); time.sleep(0.8)
    st, now = state(), by_name(probe())
    check(st["effectiveLevel"] == "revealed", f'level {st["effectiveLevel"]}')
    for name, s in now.items():
        check(s["separators"] == 0, f"{name}: no collapsed separator when revealed")
        if not s["notch"]:
            check(len(s["row"]) > len(base[name]["row"]), f"{name}: hidden icons came back")
    cmd("hide"); time.sleep(0.8)
    st, now = state(), by_name(probe())
    check(st["effectiveLevel"] == "collapsed", f'level {st["effectiveLevel"]}')
    for name, s in now.items():
        # Other apps may add/remove an icon meanwhile; the invariant is "collapsed again".
        check(s["separators"] >= 1 and s["drawnSeparators"] == 0, f'{name}: collapsed again')
    # One divider for every display: each draws the same icons in the same order; a narrow one only
    # leaves some out (macOS drops what doesn't fit, not always the leftmost), never shows others.
    def subsequence(small, big):
        it = iter(big)
        return all(any(x == y for y in it) for x in small)
    runs = {name: [w["w"] for w in reversed(s["row"]) if w["on"]] for name, s in now.items() if any(w["on"] for w in s["row"])}
    if runs:
        widest = max(runs.values(), key=len)
        for name, run in runs.items():
            check(subsequence(run, widest), f"{name}: same icons as the widest display ({run} vs {widest})")
            if len(run) < len(widest):
                notes.append(f"{name} leaves out {len(widest) - len(run)} shown icon(s): too narrow")
        if any(len(r) < len(widest) for r in runs.values()):
            check(state().get("crowding", "") != "", "Settings › Layout names the display that is too narrow")
    cmd("show/all"); time.sleep(0.8)
    check(state()["effectiveLevel"] == "revealedAll", "show/all")
    cmd("hide"); time.sleep(0.8)


def scenario_clean_mode():
    print("• clean menu bar")
    base = by_name(probe())
    cmd("clean/on"); time.sleep(1.2)
    st, now = state(), probe()
    check(st["clean"], "clean flag")
    for s in now:
        if not s["notch"]:
            check(len(s["row"]) <= 4, f'{s["name"]}: {len(s["row"])} icons left in clean mode')
    cmd("clean/off"); time.sleep(1.2)
    st, now = state(), by_name(probe())
    check(not st["clean"], "clean off")
    for name, s in now.items():
        check(len(s["row"]) == len(base[name]["row"]), f'{name}: restored {len(s["row"])} vs {len(base[name]["row"])}')


def scenario_always_hidden():
    print("• always-hidden section")
    defaults_write("alwaysHiddenEnabled", "bool", "true")
    cmd("debug/reload"); time.sleep(1.2)
    st = state()
    check(st["frames"]["always"] != [], "always divider exists")
    check(st["layoutProblem"] == "", f'problem {st["layoutProblem"]}')
    check(st["effectiveLevel"] == "collapsed", f'level {st["effectiveLevel"]}')
    cmd("show"); time.sleep(0.8)
    st = state()
    check(st["lengths"]["always"] > 1000 and st["lengths"]["hidden"] < 100, f'lengths {st["lengths"]}')
    cmd("show/all"); time.sleep(0.8)
    st = state()
    check(st["lengths"]["always"] < 100 and st["lengths"]["hidden"] < 100, f'lengths {st["lengths"]}')
    cmd("hide"); time.sleep(0.8)
    st = state()
    # Collapsed: the hidden divider covers everything; the always divider stays narrow behind it.
    check(st["lengths"]["hidden"] > 1000 and st["lengths"]["always"] < 100, f'lengths {st["lengths"]}')
    for s in probe():
        check(s["drawnSeparators"] == 0, f'{s["name"]}: no divider drawn while collapsed')
    defaults_write("alwaysHiddenEnabled", "bool", "false")
    cmd("debug/reload"); time.sleep(1.0)
    check(state()["frames"]["always"] == [], "always divider removed")


def scenario_auto_rehide():
    print("• auto re-hide")
    defaults_write("rehideDelay", "float", "2")
    cmd("debug/reload"); time.sleep(0.5)
    cmd("show"); time.sleep(1.0)
    check(state()["effectiveLevel"] == "revealed", "still revealed after 1 s")
    time.sleep(2.5)
    st = state()
    if st["lastBusy"] or st["busy"]:
        notes.append(f'auto re-hide postponed because user was busy: {st["busy"] or st["lastBusy"]}')
    else:
        check(st["effectiveLevel"] == "collapsed", f'auto re-hidden (level {st["effectiveLevel"]})')
    defaults_write("rehideDelay", "float", "8")
    cmd("hide"); cmd("debug/reload"); time.sleep(0.6)


def scenario_stress():
    print("• stress: 120 rapid commands")
    p = pid()
    cpu0 = state()["cpuSeconds"]
    seq = ["toggle", "show", "hide", "show/all", "toggle", "clean/on", "clean/off", "debug/screens"]
    for i in range(120):
        cmd(seq[i % len(seq)])
    time.sleep(3.0)
    cmd("clean/off"); cmd("hide"); time.sleep(1.5)
    st = state()
    check(pid() == p, "no crash / restart")
    check(st["effectiveLevel"] == "collapsed" and not st["clean"], f'final state {st["effectiveLevel"]} clean={st["clean"]}')
    check(st["layoutProblem"] == "", f'problem {st["layoutProblem"]}')
    print(f'    CPU for 120 commands: {st["cpuSeconds"] - cpu0:.2f} s, memory {st["memoryMB"]:.1f} MB')
    for s in probe():
        check(s["separators"] >= 1, f'{s["name"]}: collapsed after stress')


def scenario_screens_and_wake():
    print("• display reconfiguration / wake (simulated)")
    for _ in range(10):
        cmd("debug/screens")
    time.sleep(2.0)
    st = state()
    check(st["effectiveLevel"] == "collapsed" and st["layoutProblem"] == "", f'{st["effectiveLevel"]} {st["layoutProblem"]}')


def scenario_panels_without_permission():
    print("• search / shelf without Accessibility")
    cmd("debug/search"); time.sleep(1.0)
    cmd("debug/shelf"); time.sleep(1.0)
    st = state()
    check(pid() is not None, "alive")
    check(st["effectiveLevel"] in ("collapsed", "revealed"), f'level {st["effectiveLevel"]}')
    cmd("hide"); time.sleep(0.5)


def scenario_settings_memory():
    print("• settings window open/close")
    m0 = state()["memoryMB"]
    cmd("debug/settings"); time.sleep(1.5)
    m1 = state()["memoryMB"]
    cmd("debug/close-settings"); time.sleep(1.5)
    m2 = state()["memoryMB"]
    print(f"    memory: idle {m0:.1f} MB → settings open {m1:.1f} MB → closed {m2:.1f} MB")
    check(state()["settingsControllersAlive"] == 0, "settings window controller deallocated after close")
    # Re-open/close repeatedly: footprint must plateau, not climb.
    def cycles(n):
        for _ in range(n):
            cmd("debug/settings"); time.sleep(0.8)
            cmd("debug/close-settings"); time.sleep(0.8)
        return state()["memoryMB"]
    m5, m10 = cycles(5), cycles(5)
    print(f"    after 5 more cycles: {m5:.1f} MB, after 10: {m10:.1f} MB")
    check(m10 < m5 + 3, f"settings open/close plateaus ({m5:.1f} → {m10:.1f} MB)")
    check(state()["settingsControllersAlive"] == 0, "no settings controllers alive")


def scenario_bad_layout():
    print("• dividers in the wrong order → fail open, then repair")
    quit_app()
    # Put the hidden divider at the far right (right of the toggle): collapsing would hide the toggle.
    defaults_write("NSStatusItem Preferred Position tb_hidden", "float", "0.1")
    defaults_write("NSStatusItem Preferred Position tb_toggle", "float", "3000")
    launch(wait=3.0)
    st, now = state(), probe()
    check(st["layoutProblem"] == "hiddenRightOfToggle", f'problem {st["layoutProblem"]!r}')
    check(st["effectiveLevel"] == "revealedAll", f'level {st["effectiveLevel"]}')
    check(all(s["separators"] == 0 for s in now), "nothing collapsed while order is wrong")
    cmd("hide"); time.sleep(0.8)
    check(all(s["separators"] == 0 for s in probe()), "refuses to collapse on request")
    cmd("reset-positions")
    wait_for_placement()
    st = state()
    check(st["layoutProblem"] == "", f'after reset: {st["layoutProblem"]!r}')
    cmd("hide"); time.sleep(1.0)
    st, now = state(), probe()
    check(st["effectiveLevel"] == "collapsed", f'collapses after reset ({st["effectiveLevel"]})')
    check(toggle_drawn_everywhere(st, now), "toggle visible after reset")


def scenario_kill_fail_open():
    print("• crash while collapsed → every icon comes back")
    # How many icons each bar can draw with everything shown (the front app's menus take room).
    cmd("show-all"); time.sleep(1.0)
    fits = {s["name"]: s["drawn"] for s in probe()}
    cmd("hide"); time.sleep(0.8)
    sh("kill", "-9", str(pid()))
    time.sleep(2.0)
    now = probe()
    for s in now:
        check(s["separators"] == 0, f'{s["name"]}: no separator after crash')
        if not s["notch"]:
            check(s["drawn"] >= min(len(s["row"]), fits.get(s["name"], 0)) - 1, f'{s["name"]}: icons drawn as before ({s["drawn"]} vs {fits.get(s["name"])})')
    print(f"    after crash: {summary(now)}")


def proc_cpu_seconds(p):
    t = sh("ps", "-o", "time=", "-p", str(p)).strip()
    parts = t.split(":")
    return float(parts[0]) * 60 + float(parts[1]) if len(parts) == 2 else float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])


def scenario_idle_cpu():
    print("• idle (60 s, collapsed, stats off): no internal activity; CPU reported")
    sh("defaults", "delete", DOMAIN, "stats.modules", check=False)
    launch(wait=3.0)
    cmd("hide"); time.sleep(3.0)
    a = state()
    p = pid()
    t0 = proc_cpu_seconds(p)
    time.sleep(60)
    used = proc_cpu_seconds(p) - t0
    b = state()
    print(f"    CPU over 60 s idle: {used * 1000:.0f} ms ({used / 60 * 100:.3f}%), memory {b['memoryMB']:.1f} MB")
    # Deterministic: BarTap itself must do nothing while idle (no loops, no polling). Any CPU it
    # shows is AppKit redrawing its icons when other apps re-lay out the bar.
    events = b["screenChanges"] - a["screenChanges"]   # real display events (wake, Space, displays)
    if events:
        notes.append(f"{events} display event(s) during the idle window")
    check(b["commits"] - a["commits"] <= 1 + 2 * events, f'idle commits {a["commits"]} → {b["commits"]} with {events} display events')
    check(b["watchdogRuns"] - a["watchdogRuns"] <= 3 * (events + 1), f'idle watchdog {a["watchdogRuns"]} → {b["watchdogRuns"]}')
    check(b["resetCount"] == a["resetCount"], f'idle resets {a["resetCount"]} → {b["resetCount"]}')
    check(used / 60 < 0.01, f"idle CPU {used / 60 * 100:.3f}% ≥ 1%")


def scenario_keep_awake():
    print("• keep awake (power assertion)")
    cmd("keep-awake?minutes=1"); time.sleep(0.8)
    a = sh("pmset", "-g", "assertions")
    check(state()["keepAwake"], "keep-awake flag")
    check("BarTap Keep Awake" in a, "power assertion present")
    cmd("keep-awake/off"); time.sleep(0.8)
    check(not state()["keepAwake"], "flag cleared")
    check("BarTap Keep Awake" not in sh("pmset", "-g", "assertions"), "assertion released")
    cmd("keep-awake?minutes=1"); time.sleep(0.5)
    quit_app()
    check("BarTap Keep Awake" not in sh("pmset", "-g", "assertions"), "assertion released when the app quits")
    launch(wait=3.0)


def scenario_rules():
    print("• rules (large display)")
    defaults_write("ruleLargeScreen", "bool", "true")
    defaults_write("ruleLargeScreenWidth", "float", "800")
    cmd("debug/reload"); time.sleep(1.5)
    st = state()
    check(st["ruleLevel"] == "revealed" and st["effectiveLevel"] == "revealed", f'rule active: {st["ruleLevel"]} / {st["effectiveLevel"]}')
    cmd("toggle"); time.sleep(0.8)
    check(state()["effectiveLevel"] == "collapsed", "user can still hide while a rule is active")
    defaults_write("ruleLargeScreenWidth", "float", "10000")
    cmd("debug/reload"); time.sleep(1.5)
    st = state()
    check(st["ruleLevel"] == "collapsed" and st["effectiveLevel"] == "collapsed", f'rule inactive: {st["ruleLevel"]} / {st["effectiveLevel"]}')
    defaults_write("ruleLargeScreen", "bool", "false")
    cmd("debug/reload"); time.sleep(0.8)


def scenario_menu_and_language():
    print("• menu + Chinese UI")
    cmd("debug/menu"); time.sleep(0.6)
    check(state()["menuItems"] >= 10, f'menu items {state()["menuItems"]}')
    defaults_write("language", "string", "zh-Hans")
    cmd("debug/reload"); cmd("debug/settings"); cmd("debug/menu"); time.sleep(1.5)
    st = state()
    check(st["menuItems"] >= 10 and st["settingsOpen"], "zh menu + settings built")
    cmd("debug/close-settings"); time.sleep(0.5)
    sh("defaults", "delete", DOMAIN, "language", check=False)
    cmd("debug/reload"); time.sleep(0.5)
    check(pid() is not None, "alive")
    check(state()["hotkeyFailures"] == [], f'hotkeys registered: failures {state()["hotkeyFailures"]}')


def scenario_control_center_restart():
    print("• Control Center restarts while icons are hidden")
    cmd("hide")
    # Wait until two consecutive probes agree (the previous scenario may still be re-laying out).
    before, prev = None, None
    for _ in range(10):
        time.sleep(1.0)
        cur = by_name(probe())
        if prev is not None and summary(cur.values()) == summary(prev.values()):
            before = cur
            break
        prev = cur
    before = before or prev
    sh("killall", "ControlCenter", check=False)
    time.sleep(6.0)
    st, now = state(), by_name(probe())
    print(f"    before: {summary(before.values())}")
    print(f"    after:  {summary(now.values())}")
    check(pid() is not None, "BarTap survived")
    check(st["effectiveLevel"] == "collapsed", f'level {st["effectiveLevel"]}')
    from collections import Counter
    for name, s in now.items():
        b = before[name]
        check(s["separators"] >= 1 and s["drawnSeparators"] == 0, f"{name}: still collapsed")
        lost = Counter(round(w["w"]) for w in b["row"]) - Counter(round(w["w"]) for w in s["row"])
        gained = Counter(round(w["w"]) for w in s["row"]) - Counter(round(w["w"]) for w in b["row"])
        if lost or gained:
            notes.append(f"{name}: other apps' icons changed across the restart (lost widths {dict(lost)}, gained {dict(gained)})")
    # BarTap's own items must all be back: toggle + every stats item, by exact width.
    ext = [s for s in now.values() if not s["notch"]]
    pad = st.get("itemSpacing") or 16
    own = [st["frames"]["toggle"][2]] + [l + pad for l in st["stats"]["widths"].values()]
    for wdt in own:
        check(all(any(abs(w["w"] - wdt) <= 2 for w in s["row"]) for s in ext), f"BarTap item of width {wdt} is back after the restart")
    cmd("show"); time.sleep(1.0)
    for name, s in by_name(probe()).items():
        check(s["separators"] == 0, f"{name}: reveal works after restart")
    cmd("hide"); time.sleep(0.8)


def stats_on(modules):
    sh("defaults", "write", DOMAIN, "stats.modules", "-array", *modules)
    cmd("debug/reload")


def stats_items_beside_toggle(st, screens):
    """Every stats item is drawn in the Shown section (right of the toggle). Matched by width and
    by position with a tolerance that absorbs other apps' icons resizing (iStat changes width
    every second). Other apps' icons may legitimately sit between the toggle and our items."""
    widths = st["stats"]["widths"]
    if not widths:
        return True, ""
    rds = st["stats"].get("rds", {})
    toggle_rd = st.get("toggleRD", 1e9)
    pad = st.get("itemSpacing") or 16
    missing = []
    for name, length in widths.items():
        rd = rds.get(name)
        ok = rd is not None and rd < toggle_rd and any(
            any(abs(r["w"] - (length + pad)) <= 2 and abs(r["rd"] - rd) <= 30 and r["on"] for r in x["row"]) for x in screens)
        if not ok:
            missing.append(name)
    return (not missing), f"not drawn right of the toggle: {missing}"


def toggle_drawn_on(st, s):
    rd, t = st.get("toggleRD", -1), st["frames"]["toggle"]
    return any(abs(w["rd"] - rd) <= 5 and abs(w["w"] - t[2]) <= 3 and w["on"] for w in s["row"])


def scenario_stats_live():
    print("• stats: values, fixed widths, visibility, dropdowns")
    stats_on(["cpu", "memory", "disk", "network", "sensors", "battery", "gpu", "time"])
    time.sleep(6)
    st = state()["stats"]
    check(sorted(st["items"]) == sorted(["cpu", "memory", "disk", "network", "sensors", "battery", "gpu", "time"]), f'items {st["items"]}')
    check(0 <= st["cpu"] <= 1, f'cpu {st["cpu"]}')
    check(0 < st["memory"] < 1, f'memory {st["memory"]}')
    check(st["netDown"] >= 0, "net")
    check(st["cpuTemp"] == -1 or 15 < st["cpuTemp"] < 115, f'cpu temp {st["cpuTemp"]}')
    check(st["volumes"] != [], "volumes")
    widths = []
    for _ in range(5):
        widths.append(state()["stats"]["widths"])
        time.sleep(2.2)
    check(all(w == widths[0] for w in widths), f"widths changed over time: {widths}")
    # Every stats item must actually be on the bar (right of the toggle, i.e. Shown) while collapsed.
    cmd("hide"); time.sleep(1.5)
    # BarTap's run, found the way the app finds it: the toggle, then every stats item, by exact widths.
    check(wait_until(lambda: state().get("ownRunOn"), 6), "stats items are drawn right of the toggle while icons are hidden")
    for m in ["cpu", "gpu", "memory", "disk", "network", "sensors", "battery", "time"]:
        cmd(f"debug/stats-open-{m}")
    time.sleep(1.5)
    check(state()["stats"]["openPanels"] == 8, "all panels open")
    time.sleep(3.5)
    check(state()["stats"]["openPanels"] == 0, "panels released after closing")
    check(pid() is not None, "alive")


def scenario_stats_combined():
    print("• stats: combined item")
    stats_on(["cpu", "memory", "network"])
    sh("defaults", "write", DOMAIN, "stats.combined", "-bool", "true")
    cmd("debug/reload"); time.sleep(2.0)
    st = state()["stats"]
    check(st["combined"] and st["items"] == [], f'combined {st}')
    sh("defaults", "write", DOMAIN, "stats.combined", "-bool", "false")
    cmd("debug/reload"); time.sleep(1.5)
    st = state()["stats"]
    check(not st["combined"] and sorted(st["items"]) == ["cpu", "memory", "network"], f'separate {st["items"]}')


def scenario_stats_cost():
    print("• stats: CPU cost (measured with ps)")
    stats_on(["cpu", "memory", "disk", "network"])
    time.sleep(4)
    p = pid()
    t0 = proc_cpu_seconds(p); time.sleep(60); used = proc_cpu_seconds(p) - t0
    print(f"    4 items (CPU, memory, disk, network) @ default 1 s: {used * 1000:.0f} ms / 60 s = {used / 60 * 100:.3f}% CPU, {state()['memoryMB']:.1f} MB")
    # Each menu bar item update costs a few ms in AppKit's macOS 26 status-item hosting; ~1 % is
    # the measured norm for 4 changing items every 2 s on three displays (iStat Menus: ~7.8 %).
    check(used / 60 < 0.03, f"stats CPU {used / 60 * 100:.3f}% ≥ 3%")
    sh("defaults", "delete", DOMAIN, "stats.modules", check=False)
    cmd("debug/reload"); time.sleep(3)
    t0 = proc_cpu_seconds(p); time.sleep(30); used = proc_cpu_seconds(p) - t0
    print(f"    stats off: {used * 1000:.0f} ms / 30 s")
    check(state()["stats"]["items"] == [], "items removed")
    check(used < 0.3, f"engine stopped (used {used:.3f}s)")


def scenario_takeover_hunt():
    print("• 40 hide/show cycles with stats items: a collapsed divider is never drawn")
    stats_on(["cpu", "memory", "disk", "network"])
    time.sleep(3)
    bad = 0
    for i in range(40):
        cmd("hide"); time.sleep(1.6)   # watchdog (0.35 s) + one nudge/confirm (0.7 s)
        screens = probe()
        drawn_sep = sum(s["drawnSeparators"] for s in screens)
        nearly_empty = [s["name"] for s in screens if not s["notch"] and s["drawn"] < 3]
        if drawn_sep or nearly_empty:
            bad += 1
            print(f"    cycle {i}: drawn separators {drawn_sep}, bars nearly empty on {nearly_empty}; {summary(screens)}")
        cmd("show"); time.sleep(0.8)
    st = state()
    for line in st.get("watchdogLog", []):
        print(f"    watchdog: {line}")
    check(bad == 0, f"{bad} cycles left a display without its icons")
    check(st["layoutProblem"] == "", f'problem {st["layoutProblem"]!r}')
    cmd("hide"); time.sleep(1)


def scenario_reset_with_stats():
    print("• reset positions with stats items: they come back right of the toggle, once")
    stats_on(["cpu", "memory", "network"])
    time.sleep(3)
    before = state()["resetCount"]
    cmd("reset-positions")
    wait_for_placement()
    cmd("hide"); time.sleep(1.5)
    st = state()
    check(st["resetCount"] == before + 1, f'exactly one reset ({before} → {st["resetCount"]})')
    check(st["layoutProblem"] == "" and st["effectiveLevel"] == "collapsed", f'{st["effectiveLevel"]} {st["layoutProblem"]!r}')
    ext = [x for x in probe() if not x["notch"]]
    ok, detail = stats_items_beside_toggle(st, ext)
    check(ok, f"stats items visible right of the toggle after reset ({detail})")
    time.sleep(5)
    check(state()["resetCount"] == before + 1, "no further resets afterwards")


def scenario_first_run_with_stats():
    print("• first run with 4 stats items pre-enabled (the shipped configuration)")
    quit_app()
    sh("defaults", "delete", DOMAIN, check=False)
    sh("defaults", "write", DOMAIN, "stats.modules", "-array", "cpu", "memory", "disk", "network")
    before = by_name(probe())
    launch(wait=1.0)
    wait_for_placement()
    st, after = state(), probe()
    print(f"    before: {summary(before.values())}")
    print(f"    after:  {summary(after)}  (placement fixes: {st['stats'].get('placementFixes', 0)})")
    check(st["effectiveLevel"] == "collapsed" and st["layoutProblem"] == "", f'{st["effectiveLevel"]} {st["layoutProblem"]!r}')
    check(sorted(st["stats"]["items"]) == ["cpu", "disk", "memory", "network"], f'items {st["stats"]["items"]}')
    for s in after:
        b = before.get(s["name"])
        if s["notch"] and b and b["drawn"] > 0:
            check(toggle_drawn_on(st, s), f'{s["name"]}: toggle fits beside the notch with the stats items')
            check(s["drawn"] == len(s["row"]), f'{s["name"]}: nothing left behind the notch')
    ext = [x for x in after if not x["notch"]]
    ok, detail = stats_items_beside_toggle(st, ext)
    check(ok, f"stats items sit right of the toggle and are drawn ({detail})")


def idle_seconds():
    out = sh("ioreg", "-c", "IOHIDSystem", "-d", "4", check=False)
    for line in out.splitlines():
        if "HIDIdleTime" in line:
            return int(line.split()[-1]) / 1e9
    return 0.0


def wait_idle(seconds=3.0, timeout=600):
    """Moving icons needs the user away from the mouse and keyboard (any input stops it)."""
    return wait_until(lambda: idle_seconds() >= seconds, timeout, step=1.0)


def arrangement(rows):
    pinned_ids = {"com.apple.menuextra.controlcenter", "com.apple.menuextra.clock"}
    a = {"shown": [], "hidden": [], "always": [], "pinned": []}
    for r in rows:
        if r["section"] == "shown" and r.get("id") in pinned_ids:
            a["pinned"].append(r["key"])
        else:
            a[{"shown": "shown", "hidden": "hidden", "alwaysHidden": "always"}[r["section"]]].append(r["key"])
    return a


def settled_arrangement():
    """The bar's order as Settings › Layout reads it: every icon out and BarTap's stats items
    slim (so a crowded bar draws them all); an icon that isn't drawn reports a stale place."""
    cmd("debug/slim-on"); cmd("debug/layout-open"); time.sleep(2.5)
    a = arrangement(catalog())
    cmd("debug/slim-off"); time.sleep(0.8)
    return a


def base_order(a):
    """Rows as apps' icons, left to right: an app's icons are numbered by position, so compare without the number."""
    return {k: [x.rsplit("#", 1)[0] for x in a[k]] for k in ("always", "hidden", "shown", "pinned")}


def same_order(got, wanted):
    """Rows match for every app both readings saw: an app that answers Accessibility too slowly
    is left out of one reading for a while, though its icons never left the bar."""
    seen = lambda a: {x for row in base_order(a).values() for x in row}
    present = seen(got) & seen(wanted)
    keep = lambda a: {k: [x for x in v if x in present] for k, v in base_order(a).items()}
    if seen(got) ^ seen(wanted):
        notes.append(f"layout: in one reading only (slow to answer Accessibility, or just appeared): {sorted(seen(got) ^ seen(wanted))}")
    return keep(got) == keep(wanted)


def apply_rows(a, timeout=120):
    """Writes the request, runs Settings › Layout's Apply, and returns its outcome line."""
    req = pathlib.Path.home() / "Library/Application Support/BarTap/layout-request.json"
    req.write_text(json.dumps(a))
    before = state().get("layoutApply", "")
    cmd("debug/layout-apply")
    done = lambda: (lambda st: st.get("layoutApply", "") != before and not st.get("layoutApplying") and not st.get("layoutApply", "").startswith("running"))(state())
    wait_until(done, timeout, step=0.5)
    time.sleep(1.0)
    req.unlink(missing_ok=True)
    return state().get("layoutApply", "")


def scenario_layout_apply():
    print("• Settings › Layout: Apply moves icons between rows and along them, then restores")
    if not state().get("axTrusted"):
        notes.append("layout scenario skipped: Accessibility not granted")
        return
    quit_app()
    defaults_write("placementPending", "bool", "false")
    launch(wait=1.0)
    time.sleep(2)
    # The page reveals every icon only while it captures them, then puts the bar back as it was.
    # (Not when the toggle can't be drawn: BarTap then keeps everything shown on purpose.)
    cmd("hide"); time.sleep(0.8)
    if state().get("toggleUndrawn"):
        notes.append("layout: the toggle isn't drawn on any display (too little room beside the notch): BarTap stays open")
    else:
        cmd("debug/layout-page-open"); time.sleep(1.5)
        check(state()["effectiveLevel"] == "revealedAll", "icons revealed for capturing when the page opens")
        check(wait_until(lambda: state()["effectiveLevel"] == "collapsed", 15), "bar hidden again while the page stays open")
        check(state().get("imageCache", 0) > 0, "icons captured")
        cmd("debug/layout-page-close"); time.sleep(0.5)
    cmd("debug/layout-open"); time.sleep(3)
    check(state()["effectiveLevel"] == "revealedAll", "every icon shown for the moves")
    original = settled_arrangement()
    if len(original["hidden"]) + len(original["shown"]) < 4:
        notes.append("layout scenario: too few icons")
        cmd("debug/layout-close")
        return
    tests = []
    h = original["hidden"]
    pair = next((i for i in range(len(h) - 1) if h[i].split("|")[0] != h[i + 1].split("|")[0]), None)
    if pair is not None:
        swapped = dict(original, hidden=h[:pair] + [h[pair + 1], h[pair]] + h[pair + 2:])
        tests.append(("swap two hidden icons", swapped))
    if h:
        across = dict(original, hidden=h[:-1], shown=[h[-1]] + original["shown"])
        tests.append(("rightmost hidden icon → shown", across))
    # BarTap's own stats items move like any icon: the last one shown goes to the end of Hidden.
    own = [k for k in original["shown"] if "|bartap.stats." in k]
    if own:
        stats_hidden = dict(original, hidden=h + [own[-1]], shown=[k for k in original["shown"] if k != own[-1]])
        tests.append(("a BarTap stats item → hidden", stats_hidden))
    for name, wanted in tests:
        if not wait_idle():
            notes.append(f"layout: {name} skipped (the mouse or keyboard stayed in use)")
            continue
        out = apply_rows(wanted)
        got = settled_arrangement()
        print(f"    {name}: {out.split('[')[0].strip()}")
        if "interrupted" in out:
            notes.append(f"layout: {name} interrupted by input")
        else:
            check(same_order(got, wanted), f"{name}: bar matches ({base_order(got)} vs {base_order(wanted)})")
        # Put the user's arrangement back, waiting out any input.
        for _ in range(3):
            wait_idle()
            out = apply_rows(original)
            if "interrupted" not in out:
                break
        restored = settled_arrangement()
        print(f"    restore: {out.split('[')[0].strip()}")
        check(same_order(restored, original), f"{name}: original order restored ({base_order(restored)})")
    check(state()["layoutProblem"] == "", "no layout problem afterwards")
    cmd("debug/layout-close"); time.sleep(1.5)
    check(state()["effectiveLevel"] == "collapsed", "collapses again when the page closes")


def scenario_jitter():
    print("• fixed elements never move when values change length (pixel check)")
    cmd("debug/jitter"); time.sleep(1.0)
    j = state()["jitter"]
    for k, v in sorted(j.items()):
        check(v, f"{k}")
    check(len(j) >= 5, f"jitter results {j}")


def scenario_time_module():
    print("• time module: clock item + panel, updates once per minute")
    stats_on(["time"])
    time.sleep(3)
    st = state()["stats"]
    check(st["items"] == ["time"], f'items {st["items"]}')
    cmd("debug/stats-open-time"); time.sleep(1.0)
    check(state()["stats"]["openPanels"] == 1, "time panel opens")
    time.sleep(3.5)
    a = state()["stats"]["performedUpdates"]
    time.sleep(10)
    b = state()["stats"]["performedUpdates"]
    check(b - a <= 1, f"clock redrew {b - a} times in 10 s (once per minute expected)")


def scenario_ai_usage():
    print("• AI usage: first read, menu bar item, dropdown, CPU, and off releases the reader")
    stats_on(["ai"])
    deadline = time.time() + 90
    ai = {}
    while time.time() < deadline:
        time.sleep(2)
        ai = state()["stats"].get("ai", {})
        if ai.get("days", 0) > 0 and ai.get("progress", 0) == -1:
            break
    print(f'    detected {ai.get("detected")}, {ai.get("days")} days, today {ai.get("todayTokens")} tokens / ${ai.get("todayCost", 0):.2f}, plans {ai.get("plans")}, prices {ai.get("pricesFetched")}')
    check(ai.get("running") and ai.get("days", 0) > 0, f"AI reader ran: {ai}")
    st = state()["stats"]
    check(st["items"] == ["ai"] and st["widths"].get("ai", 0) > 20, f'AI item {st["items"]} {st["widths"]}')
    cmd("debug/stats-open-ai"); time.sleep(1.0)
    check(state()["stats"]["openPanels"] == 1, "AI dropdown opens")
    time.sleep(3.5)
    p = pid()
    t0 = proc_cpu_seconds(p); time.sleep(30); used = proc_cpu_seconds(p) - t0
    print(f"    AI item alone: {used * 1000:.0f} ms / 30 s = {used / 30 * 100:.2f}% CPU, {state()['memoryMB']:.1f} MB")
    check(used / 30 < 0.02, f"AI item CPU {used / 30 * 100:.2f}% ≥ 2%")
    sh("defaults", "delete", DOMAIN, "stats.modules", check=False)
    cmd("debug/reload"); time.sleep(2)
    ai = state()["stats"].get("ai", {})
    check(not ai.get("running"), "turning AI usage off stops the reader")


SCENARIOS = {
    "first_run": scenario_first_run,
    "show_hide": scenario_show_hide,
    "clean": scenario_clean_mode,
    "always": scenario_always_hidden,
    "rehide": scenario_auto_rehide,
    "stress": scenario_stress,
    "screens": scenario_screens_and_wake,
    "panels": scenario_panels_without_permission,
    "settings": scenario_settings_memory,
    "bad_layout": scenario_bad_layout,
    "kill": scenario_kill_fail_open,
    "idle": scenario_idle_cpu,
    "keep_awake": scenario_keep_awake,
    "rules": scenario_rules,
    "menu_lang": scenario_menu_and_language,
    "control_center": scenario_control_center_restart,
    "stats_live": scenario_stats_live,
    "stats_combined": scenario_stats_combined,
    "stats_cost": scenario_stats_cost,
    "takeover": scenario_takeover_hunt,
    "reset_stats": scenario_reset_with_stats,
    "first_run_stats": scenario_first_run_with_stats,
    "layout": scenario_layout_apply,
    "jitter": scenario_jitter,
    "time": scenario_time_module,
    "ai": scenario_ai_usage,
}

if __name__ == "__main__":
    chosen = sys.argv[1:] or list(SCENARIOS)
    try:
        for name in chosen:
            SCENARIOS[name]()
    finally:
        quit_app()
        sh("defaults", "delete", DOMAIN, "debugCommands", check=False)
    for n in notes:
        print(f"  note: {n}")
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
