#!/usr/bin/env python3
"""
extract_plan.py — Operation Sub-4
Turn `marathon_plan sub_4hr.html` into structured JSON the app can consume.

The HTML week cards are canonical (per project notes). Swim and strength detail
live in two JS objects, SWIM_DATA and STRENGTH_DATA, keyed by zero-padded week.

Usage:  python3 extract_plan.py "marathon_plan sub_4hr.html" plan.json
"""
import re, sys, json, html
from datetime import date, timedelta
from bs4 import BeautifulSoup

# Week 1 begins Mon 27 Jul 2026. Every plan week is Mon–Sun from there.
WEEK1_MONDAY = date(2026, 7, 27)
DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']

# CSS custom property on the .sw swatch → discipline + intensity
SWATCH = {
    'easy': ('run', 'easy'),
    'long': ('run', 'long'),
    'mp':   ('run', 'marathon_pace'),
    'thr':  ('run', 'threshold'),
    'bike': ('bike', 'easy'),
    'swim': ('swim', None),
    'str':  ('strength', None),
    'rest': ('rest', None),
}


def txt(node, sep=' '):
    return node.get_text(sep, strip=True) if node else None


def js_object(raw, name):
    """Extract a top-level `NAME = { ... }` JS object literal and JSON-parse it."""
    m = re.search(name + r'\s*=\s*\{', raw)
    if not m:
        return {}
    start, depth = m.end() - 1, 0
    for i in range(start, len(raw)):
        if raw[i] == '{':
            depth += 1
        elif raw[i] == '}':
            depth -= 1
            if depth == 0:
                return json.loads(raw[start:i + 1])
    raise ValueError(f'unterminated object: {name}')


def slug(s):
    s = re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')
    return re.sub(r'-{2,}', '-', s)[:40]


def extract(path):
    raw = open(path, encoding='utf-8').read()
    soup = BeautifulSoup(raw, 'lxml')

    swim_data = js_object(raw, 'SWIM_DATA')
    strength_data = js_object(raw, 'STRENGTH_DATA')

    # ---- exercise library ------------------------------------------------------
    # Every strength block with a video URL ("u") is a library movement. Keyed by
    # URL because the same movement is described identically across 56 sessions;
    # this collapses ~500 repetitions to ~20 rows.
    exercises, ex_by_url = {}, {}
    for wk, days in strength_data.items():
        for title, payload in days.items():
            for b in payload.get('blocks', []):
                url = b.get('u')
                if not url:
                    continue
                name = html.unescape(b.get('t', '')).strip()
                if url not in ex_by_url:
                    uid = slug(name) or f'ex-{len(exercises)+1}'
                    while uid in exercises:
                        uid += '-x'
                    ex_by_url[url] = uid
                    exercises[uid] = {
                        'uid': uid, 'name': name, 'video_url': url,
                        'cue': b.get('x'), 'uses': 0,
                    }
                exercises[ex_by_url[url]]['uses'] += 1

    weeks, sessions, warnings = [], [], []

    # NOT `fuel` — the session loop below binds that name for the per-session
    # line, and the loop runs after this, so the section block was being
    # overwritten by the last session's one-line string.
    fuel_block, fuel_warns = parse_fuel(soup)
    warnings.extend(fuel_warns)

    warmup_block, warmup_warns = parse_warmup(soup)
    warnings.extend(warmup_warns)

    for card in soup.select('div.week'):
        wno_raw = txt(card.select_one('.wno')) or '?'
        is_logged = 'done' in (card.get('class') or [])

        if is_logged:                                  # P1–P3 — July, from Strava
            wuid, week_no, monday = f'log-{wno_raw.lower()}', None, None
        else:
            week_no = int(wno_raw)
            wuid = f'wk-{week_no:02d}'
            monday = WEEK1_MONDAY + timedelta(weeks=week_no - 1)

        badge_el = card.select_one('.whead .badge')
        badge_text = txt(badge_el)
        badge_kind = None
        if badge_el is not None:
            classes = [c for c in (badge_el.get('class') or []) if c != 'badge']
            badge_kind = classes[0] if classes else None

        stats = {}
        for sp in card.select('.wstat span'):
            t = txt(sp)
            m = re.match(r'~?([\d.]+)\s+(\w+)', t or '')
            if m:
                stats[m.group(2)] = float(m.group(1))

        weeks.append({
            'uid': wuid,
            'week_no': week_no,
            'label': wno_raw,
            'date_range': txt(card.select_one('.wdate')),
            'start_date': monday.isoformat() if monday else None,
            'tag': txt(card.select_one('.wtag')),
            # The plan's own visual classification, which was never extracted.
            # `kind` is the badge's CSS class — race / peak / cut / done — and
            # is what says which weeks are the hard ones and which are the
            # recovery ones. Inventing that in the app would have meant
            # second-guessing a judgement the plan had already made.
            'badge': badge_text,
            'kind': badge_kind,
            'logged': is_logged,
            'stats': stats,
        })

        seen_days = {}
        for s in card.select('.ses'):
            sw = s.select_one('.sw')
            key = None
            if sw and sw.get('style'):
                m = re.search(r'var\(--(\w+)\)', sw['style'])
                key = m.group(1) if m else None
            discipline, intensity = SWATCH.get(key, ('other', None))

            day = txt(s.select_one('.day'))
            title = txt(s.select_one('.ttl'))
            detail = txt(s.select_one('.det'))
            # The fuel line is a sibling div inside the same card. It was
            # ignored for months — 180 of 260 sessions carry one and none of it
            # reached the app. The lightning bolt is presentation, so it is
            # stripped here rather than shipped into every string.
            fuel = txt(s.select_one('.fuel'))
            if fuel:
                fuel = fuel.replace('\u26a1', '').strip(' \u00b7')
            # Rehearsal marker: the three long runs where the race warm-up gets
            # practised. Same shape as the fuel line, same reason for stripping
            # the glyph — it is presentation, not content.
            prep = txt(s.select_one('.prep'))
            if prep:
                prep = prep.replace('\u21bb', '').strip(' \u00b7')

            seq = seen_days.get(day, 0)
            seen_days[day] = seq + 1

            sdate = None
            if monday and day in DAYS:
                sdate = (monday + timedelta(days=DAYS.index(day))).isoformat()
            elif monday:
                warnings.append(f'{wuid}: unrecognised day "{day}"')

            suid = f'{wuid}-{(day or "x").lower()}-{slug(title or "s")}'
            if seq:
                suid += f'-{seq}'

            rec = {
                'uid': suid,
                'week_uid': wuid,
                'day': day,
                'date': sdate,
                'discipline': discipline,
                'intensity': intensity,
                'title': title,
                'detail': detail,
                'fuel': fuel,
                'prep': prep,
                'seq': seq,
            }

            wk_key = f'{week_no:02d}' if week_no else None

            if discipline == 'swim' and wk_key in swim_data:
                rec['swim_detail'] = swim_data[wk_key]
            elif discipline == 'swim' and wk_key:
                warnings.append(f'{suid}: swim card with no SWIM_DATA["{wk_key}"]')

            if discipline == 'strength' and wk_key:
                block = strength_data.get(wk_key, {})
                hit = block.get(f'{day}|{title}')
                if hit is not None:
                    rec['strength_detail'] = hit
                else:
                    warnings.append(f'{suid}: no STRENGTH_DATA["{wk_key}"]["{day}|{title}"]')

            sessions.append(rec)

    return {
        'meta': {
            'source': path.split('/')[-1],
            'plan': 'Operation Sub-4',
            'week1_monday': WEEK1_MONDAY.isoformat(),
            'race_date': (WEEK1_MONDAY + timedelta(weeks=33, days=6)).isoformat(),
            'target_time': '04:00:00',
            'target_pace_sec_km': 341,
        },
        'weeks': weeks,
        'sessions': sessions,
        'exercises': list(exercises.values()),
        'fuel': fuel_block,
        'warmup': warmup_block,
        'warnings': warnings,
    }


# ---------------------------------------------------------------- fuelling
#
# Sections 09 (Fueling) and 10 (Race day - eat & drink) were never extracted.
# Between them they carry the product table, a g/hr target for every session
# type, the long-run ladder, the race-day timeline and the hydration and
# pacing plan — none of which existed anywhere in the app.
#
# Structure is walked rather than pattern-matched: each section is a flat run
# of siblings after its <h2>, alternating .sublab headings with tables, so the
# position of each table is what identifies it. That is fragile if the document
# is reordered, which is why validate() checks the row counts afterwards.

def _rows(table):
    """Table -> list of dicts keyed by the header cells."""
    out, head = [], []
    for tr in table.select('tr'):
        cells = [txt(c) or '' for c in tr.select('th, td')]
        if not cells:
            continue
        if not head:
            head = cells
            continue
        out.append(dict(zip(head, cells)))
    return out


def _section(soup, num):
    """The h2 whose .num is `num`, and every sibling up to the next h2."""
    for h in soup.select('h2'):
        n = h.select_one('.num')
        if n and n.get_text(strip=True) == num:
            body, sib = [], h.find_next_sibling()
            while sib is not None and sib.name != 'h2':
                body.append(sib)
                sib = sib.find_next_sibling()
            return body
    return []


def parse_warmup(soup):
    """Section 10b — the race-day warm-up.

    Same positional walk as parse_fuel: two tables (the timeline, then the
    mobility circuit), a grid of condition cards, two section-intros and a
    medbox. validate() checks the row counts so a reordered document fails
    rather than shipping empty tables.
    """
    body = _section(soup, '10b')
    if not body:
        return None, ['warm-up: section 10b not found']

    warns = []
    tables = [n for n in body if n.name == 'table']
    intros = [txt(n) for n in body if 'section-intro' in (n.get('class') or [])]

    if len(tables) != 2:
        warns.append(f'warm-up: expected 2 tables, found {len(tables)}')

    def col(row, *names):
        for n in names:
            if n in row:
                return row[n]
        return None

    timeline = [{
        'time':   col(r, 'Time'),
        'action': col(r, 'Do'),
        'detail': col(r, 'Detail'),
    } for r in _rows(tables[0])] if len(tables) > 0 else []

    circuit = [{
        'movement': col(r, 'Movement'),
        'dose':     col(r, 'Dose'),
    } for r in _rows(tables[1])] if len(tables) > 1 else []

    conditions = []
    for n in body:
        if 'grid' in (n.get('class') or []):
            for card in n.select('.card'):
                lab = card.select_one('.lab')
                note = card.select_one('.note')
                conditions.append({
                    'condition': txt(lab),
                    'what': txt(note),
                })
            break

    caution = None
    for n in body:
        if 'medbox' in (n.get('class') or []):
            tag = n.select_one('.tag')
            caution = {
                'tag': txt(tag) if tag else None,
                'text': txt(n).replace(txt(tag) or '', '').strip(),
            }
            break

    return {
        'intro':      intros[0] if intros else None,
        'timeline':   timeline,
        'circuit':    circuit,
        'circuit_note': intros[1] if len(intros) > 1 else None,
        'conditions': conditions,
        'caution':    caution,
    }, warns


def parse_fuel(soup):
    nine, ten = _section(soup, '09'), _section(soup, '10')
    if not nine or not ten:
        return None, ['fuelling: section 09 or 10 not found']

    warns = []

    def tables(body):
        return [n for n in body if n.name == 'table']

    def intros(body):
        return [txt(n) for n in body if 'section-intro' in (n.get('class') or [])]

    def medbox(body):
        for n in body:
            if 'medbox' in (n.get('class') or []):
                tag = n.select_one('.tag')
                return {
                    'tag': txt(tag) if tag else None,
                    'text': txt(n).replace(txt(tag) or '', '').strip(),
                }
        return None

    t9 = tables(nine)
    if len(t9) != 3:
        warns.append(f'fuelling: expected 3 tables in section 09, found {len(t9)}')

    i9 = intros(nine)

    def col(row, *names):
        for n in names:
            if n in row:
                return row[n]
        return None

    products = [{
        'name':     col(r, 'Product'),
        'carbs':    col(r, 'Carbs'),
        'caffeine': col(r, 'Caffeine'),
        'use':      col(r, 'Use'),
    } for r in _rows(t9[0])] if len(t9) > 0 else []

    per_session = [{
        'session': col(r, 'Session'),
        'target':  col(r, 'Target'),
        'take':    col(r, 'What to take'),
    } for r in _rows(t9[1])] if len(t9) > 1 else []

    ladder = [{
        'run':   col(r, 'Long run'),
        'carbs': col(r, '~Carbs'),
        'take':  col(r, 'Take'),
    } for r in _rows(t9[2])] if len(t9) > 2 else []

    t10 = tables(ten)
    if len(t10) != 1:
        warns.append(f'fuelling: expected 1 table in section 10, found {len(t10)}')
    timeline = [{
        'time':  col(r, 'Time'),
        'dist':  col(r, '~Dist'),
        'take':  col(r, 'Take'),
        'total': col(r, 'Total in'),
    } for r in _rows(t10[0])] if t10 else []

    before = []
    for n in ten:
        if n.name == 'ul':
            before = [txt(li) for li in n.select('li')]
            break

    hydration = pacing = None
    for n in ten:
        if 'grid' in (n.get('class') or []):
            cards = n.select('.card')
            # Each card's text starts with its own heading word, which would
            # then be printed twice — once as the section title in the app and
            # once inside the paragraph.
            def _body(card):
                s = txt(card) or ''
                head = txt(card.select_one('b, .sublab, strong'))
                if head and s.startswith(head):
                    return s[len(head):].strip()
                for w in ('Hydration', 'Pacing'):
                    if s.startswith(w):
                        return s[len(w):].strip()
                return s
            if len(cards) > 0: hydration = _body(cards[0])
            if len(cards) > 1: pacing = _body(cards[1])
            break

    i10 = intros(ten)

    data = {
        'intro':       i9[0] if i9 else None,
        'timing_rule': i9[1] if len(i9) > 1 else None,
        'products':    products,
        'per_session': per_session,
        'ladder':      ladder,
        'caution':     medbox(nine),
        'race_day': {
            'intro':     i10[0] if i10 else None,
            'before':    before,
            'timeline':  timeline,
            'totals':    i10[1] if len(i10) > 1 else None,
            'hydration': hydration,
            'pacing':    pacing,
            'caution':   medbox(ten),
        },
    }
    return data, warns



def validate(d):
    """Fail loudly rather than import bad data."""
    errs, warns = [], list(d['warnings'])

    # Fuelling. The section parser walks siblings by position, so a reordered
    # document would silently produce empty tables rather than fail — these
    # counts are what turn that into a build error.
    f = d.get('fuel')
    if not f:
        errs.append('fuelling: section 09/10 not extracted')
    else:
        for key, want in (('products', 3), ('per_session', 7), ('ladder', 5)):
            got = len(f.get(key) or [])
            if got != want:
                errs.append(f'fuelling: {key} has {got} rows, expected {want}')
        rd = f.get('race_day') or {}
        if len(rd.get('timeline') or []) != 10:
            errs.append(f'fuelling: race timeline has '
                        f'{len(rd.get("timeline") or [])} rows, expected 10')
        if len(rd.get('before') or []) != 4:
            errs.append('fuelling: race-day "before" list is not 4 items')
        for k in ('hydration', 'pacing'):
            if not rd.get(k):
                errs.append(f'fuelling: race_day.{k} missing')
        if not (f.get('caution') or {}).get('text'):
            errs.append('fuelling: the caffeine caution did not parse')
        n = sum(1 for s in d['sessions'] if s.get('fuel'))
        if n < 150:
            errs.append(f'fuelling: only {n} sessions carry a fuel line')

    # Week badges. These drive how the Plan tab weights each week, so a
    # missing one is a week that quietly stops standing out.
    kinds = {}
    for wk in d['weeks']:
        kinds[wk.get('kind')] = kinds.get(wk.get('kind'), 0) + 1
    for kind, want in (('race', 2), ('peak', 2), ('done', 3)):
        if kinds.get(kind, 0) != want:
            errs.append(f'badges: {kinds.get(kind, 0)} weeks marked "{kind}", '
                        f'expected {want}')
    if kinds.get('cut', 0) < 10:
        errs.append(f'badges: only {kinds.get("cut", 0)} cutback weeks found')

    # Warm-up. Same positional-walk fragility as the fuelling parser.
    w = d.get('warmup')
    if not w:
        errs.append('warm-up: section 10b not extracted')
    else:
        for key, want in (('timeline', 9), ('circuit', 7), ('conditions', 4)):
            got = len(w.get(key) or [])
            if got != want:
                errs.append(f'warm-up: {key} has {got} rows, expected {want}')
        if not (w.get('caution') or {}).get('text'):
            errs.append('warm-up: the caution did not parse')
        # Four: the three rehearsal long runs, plus race day itself. Race day
        # was missed at first — the one morning the protocol is actually run
        # was the only session in the plan with no link to it.
        prep = [s for s in d['sessions'] if s.get('prep')]
        if len(prep) != 4:
            errs.append(f'warm-up: {len(prep)} prep markers, expected 4')
        if not any('MARATHON' in (s.get('title') or '') for s in prep):
            errs.append('warm-up: race day carries no prep marker')
    plan_weeks = [w for w in d['weeks'] if not w['logged']]
    plan_sess = [s for s in d['sessions'] if not s['uid'].startswith('log-')]

    nums = sorted(w['week_no'] for w in plan_weeks)
    if nums != list(range(1, 35)):
        errs.append(f'week numbering not 1..34 (got {nums[:3]}..{nums[-3:]}, n={len(nums)})')

    uids = [s['uid'] for s in d['sessions']]
    dupes = {u for u in uids if uids.count(u) > 1}
    if dupes:
        errs.append(f'duplicate session uids: {sorted(dupes)[:5]}')

    for s in plan_sess:
        if not s['date']:
            errs.append(f'{s["uid"]}: no date')

    # every session date must fall inside its own week
    byweek = {w['uid']: w for w in d['weeks']}
    for s in plan_sess:
        w = byweek.get(s['week_uid'])
        if w and w['start_date'] and s['date']:
            start = date.fromisoformat(w['start_date'])
            if not (start <= date.fromisoformat(s['date']) <= start + timedelta(days=6)):
                errs.append(f'{s["uid"]}: date {s["date"]} outside week {w["start_date"]}')

    for s in plan_sess:
        if s['discipline'] == 'other':
            warns.append(f'{s["uid"]}: unmapped swatch colour')

    # every strength/swim card must carry its detail
    for s in plan_sess:
        if s['discipline'] == 'strength' and 'strength_detail' not in s:
            errs.append(f'{s["uid"]}: strength card without detail')
        if s['discipline'] == 'swim' and 'swim_detail' not in s:
            errs.append(f'{s["uid"]}: swim card without detail')

    # exercise library sanity
    if not d['exercises']:
        errs.append('exercise library is empty')
    for e in d['exercises']:
        if not e['video_url'].startswith('http'):
            errs.append(f'{e["uid"]}: bad video url')

    return errs, warns


if __name__ == '__main__':
    src = sys.argv[1] if len(sys.argv) > 1 else 'marathon_plan sub_4hr.html'
    out = sys.argv[2] if len(sys.argv) > 2 else 'plan.json'

    data = extract(src)
    errs, warns = validate(data)

    import collections
    disc = collections.Counter(s['discipline'] for s in data['sessions'])

    print(f"weeks      {len(data['weeks'])}  "
          f"({sum(1 for w in data['weeks'] if not w['logged'])} plan + "
          f"{sum(1 for w in data['weeks'] if w['logged'])} logged)")
    print(f"sessions   {len(data['sessions'])}   {dict(disc)}")
    print(f"exercises  {len(data['exercises'])}")
    print(f"swim detail attached      {sum(1 for s in data['sessions'] if 'swim_detail' in s)}")
    print(f"strength detail attached  {sum(1 for s in data['sessions'] if 'strength_detail' in s)}")
    print(f"race date  {data['meta']['race_date']}")

    if warns:
        print(f"\n⚠  {len(warns)} warnings")
        for w in warns[:15]:
            print('   ', w)
    if errs:
        print(f"\n✖  {len(errs)} ERRORS — not written")
        for e in errs[:15]:
            print('   ', e)
        sys.exit(1)

    json.dump(data, open(out, 'w'), indent=1, ensure_ascii=False)
    print(f"\n✔  validation passed → {out}")
