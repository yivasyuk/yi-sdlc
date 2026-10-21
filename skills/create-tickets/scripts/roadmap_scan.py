"""Read a yi-sdlc repo's roadmap and its YouTrack project, and print what create-tickets needs as JSON.

Parses docs/roadmap.md (steps, the fog table, open decisions, the dependency graph, the shipped table),
checks whether the roadmap is stale, reads every issue of the project in one REST call, and says which
open steps a ticket already covers. Reads only: it never writes to git, the roadmap or the tracker.

Usage: python roadmap_scan.py [--repo-root PATH] [--no-tracker]
Needs YOUTRACK_TOKEN (process env or the Windows user env); YOUTRACK_URL or the profile's ticket_url.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

MARKER = re.compile(r'Roadmap step\s+([0-9]+[a-z]?)\b', re.IGNORECASE)


def user_env(name):
    value = os.environ.get(name)
    if value:
        return value
    if sys.platform == 'win32':
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
                return winreg.QueryValueEx(key, name)[0]
        except OSError:
            return None
    return None


def git(repo_root, *args):
    result = subprocess.run(['git', '-C', repo_root, *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


# --- profile -------------------------------------------------------------------------------------


def read_profile(repo_root):
    path = os.path.join(repo_root, '.claude', 'yi-sdlc', 'project.md')
    try:
        text = open(path, encoding='utf-8').read()
    except OSError:
        return None

    def one(pattern):
        m = re.search(pattern, text)
        return m.group(1).strip().strip('\'"') if m else None

    id_pattern = one(r'id_pattern:\s*(\S+)')
    project = None
    if id_pattern:
        m = re.search(r'\^?([A-Za-z][\w]*)-', id_pattern)
        project = m.group(1) if m else None

    columns, roles = [], {}
    block = re.search(r'columns:\s*\n((?:\s+-.*\n)+)', text)
    if block:
        for line in block.group(1).splitlines():
            m = re.match(r'\s+-\s*\{\s*name:\s*([^,}]+?)\s*,\s*role:\s*([\w-]+)', line)
            if m:
                columns.append(m.group(1))
                roles[m.group(2)] = m.group(1)
            else:
                m = re.match(r'\s+-\s*(.+?)\s*$', line)
                if m:
                    columns.append(m.group(1))

    sdlc = re.search(r'sdlc_mode:\s*\n\s+field:\s*\{\s*name:\s*([^,]+?)\s*,\s*values:\s*\{([^}]*)\}', text)
    sdlc_field, sdlc_values = None, {}
    if sdlc:
        sdlc_field = sdlc.group(1)
        for pair in sdlc.group(2).split(','):
            if ':' in pair:
                k, v = pair.split(':', 1)
                sdlc_values[k.strip()] = v.strip()

    types = {}
    m = re.search(r'^type:\s*\{(.*)\}\s*$', text, re.MULTILINE)
    if m:
        for key, values in re.findall(r'([\w-]+):\s*\[([^\]]*)\]', m.group(1)):
            types[key] = [v.strip() for v in values.split(',') if v.strip()]

    return {
        'path': path,
        'adapter': one(r'adapter:\s*(\S+)'),
        'mcp_server': one(r'mcp_server:\s*(\S+)'),
        'ticket_url': one(r'ticket_url:\s*(\S+)'),
        'project': project,
        'column_field': one(r'column_field:\s*(.+)'),
        'columns': columns,
        'roles': roles,
        'sdlc_mode_field': sdlc_field,
        'sdlc_mode_values': sdlc_values,
        'types': types,
    }


# --- roadmap -------------------------------------------------------------------------------------


def sections(text):
    out, current = {}, None
    for line in text.splitlines():
        m = re.match(r'^##\s+(.+?)\s*$', line)
        if m:
            current = m.group(1)
            out[current] = []
        elif current:
            out[current].append(line)
    return out


def split_row(line):
    line = line.strip()
    if not line.startswith('|'):
        return None
    cells = [c.strip() for c in line.strip('|').split('|')]
    if all(re.fullmatch(r':?-{2,}:?', c) for c in cells if c):
        return None
    return cells


def table(lines):
    rows = [r for r in (split_row(l) for l in lines) if r is not None]
    if not rows:
        return []
    header = [h.lower() for h in rows[0]]
    return [dict(zip(header, r)) for r in rows[1:]]


def find_section(secs, *starts):
    for name, lines in secs.items():
        if any(name.lower().startswith(s) for s in starts):
            return lines
    return []


def plain(cell):
    cell = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', cell)
    return cell.replace('**', '').replace('`', '').strip()


def tickets_in(text, project):
    if not project:
        return []
    found = re.findall(rf'\b({re.escape(project)}-\d+)\b', text, re.IGNORECASE)
    return sorted({f.lower() if project.islower() else f.upper() for f in found}, key=lambda s: int(s.split('-')[1]))


def step_numbers(cell):
    return re.findall(r'\b([0-9]+[a-z]?)\b', cell or '')


def parse_roadmap(text, project):
    front = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
    updated_at = None
    if front:
        m = re.search(r'updated_at:\s*"?([^"\n]+)"?', front.group(1))
        updated_at = m.group(1) if m else None

    secs = sections(text)
    steps = []
    for row in table(find_section(secs, 'steps')):
        num = row.get('#', '').strip()
        step_cell = row.get('step', '')
        m = re.search(r'\*\*(.+?)\*\*\s*(?:\((\[?`([^`]+)`\]?(?:\(([^)]+)\))?)\))?\s*:?\s*(.*)', step_cell)
        name = m.group(1) if m else plain(step_cell)
        slug = m.group(3) if m else None
        doc = m.group(4) if m else None
        summary = plain(m.group(5)) if m else ''
        steps.append({
            'num': num,
            'name': name,
            'slug': slug,
            'doc': doc,
            'summary': summary,
            'source': row.get('source', ''),
            'size': plain(row.get('size', '')),
            'status': plain(row.get('status', '')).lower(),
            'row_tickets': tickets_in(' '.join(row.values()), project),
        })

    fog = []
    for row in table(find_section(secs, 'not yet specified')):
        fog.append({
            'area': plain(row.get('area', '')),
            'learn': plain(row.get("what we'd have to learn", row.get('what we would have to learn', ''))),
            'blocks': step_numbers(row.get('blocks', '')),
            'sharpened_by': plain(row.get('how it gets sharpened', '')),
        })

    decisions = []
    for row in table(find_section(secs, 'open decisions')):
        decisions.append({
            'id': plain(row.get('#', '')),
            'question': plain(row.get('question', '')),
            'owner': plain(row.get('owner', '')),
            'blocks': step_numbers(row.get('blocks', '')),
        })

    graph_text = '\n'.join(find_section(secs, 'dependency graph'))
    nodes = {n: s for n, s in re.findall(r'(\w+)\["([0-9]+[a-z]?)\s*·', graph_text)}
    edges = []
    for a, label, b in re.findall(r'(\w+)\s*-->\s*(?:\|"([^"]*)"\|\s*)?(\w+)', graph_text):
        if a in nodes and b in nodes:
            edges.append({'from': nodes[a], 'to': nodes[b], 'why': label})

    shipped_rows = set()
    for row in table(find_section(secs, 'shipped')):
        m = re.match(r'\s*([0-9]+[a-z]?)\s*·', row.get('step', ''))
        if m:
            shipped_rows.add(m.group(1))

    return {
        'updated_at': updated_at,
        'steps': steps,
        'fog': fog,
        'decisions': decisions,
        'edges': edges,
        'shipped_table': sorted(shipped_rows),
    }


# --- tracker -------------------------------------------------------------------------------------


def base_url(profile):
    url = user_env('YOUTRACK_URL')
    if url:
        return url.rstrip('/')
    m = re.match(r'(https?://[^/\s]+)', (profile or {}).get('ticket_url') or '')
    return m.group(1) if m else None


def fetch_issues(url, token, project):
    fields = (
        'idReadable,summary,description,resolved,project(id),customFields(name,value(name)),'
        'links(direction,linkType(name),issues(idReadable))'
    )
    query = urllib.parse.urlencode({'query': f'project: {project}', 'fields': fields, '$top': 2000})
    req = urllib.request.Request(
        f'{url}/api/issues?{query}',
        headers={'Authorization': f'Bearer {token}', 'Accept': 'application/json'},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def field_values(url, token, project, names):
    """The values each field accepts, from YouTrack's search suggestions: the agent account usually can't
    read the project's field settings, but the query assistant lists the values anyway."""
    out = {}
    for name in names:
        query = f'project: {project} {{{name}}}: '
        req = urllib.request.Request(
            f'{url}/api/search/assist?fields=suggestions(option)',
            data=json.dumps({'query': query, 'caret': len(query)}).encode(),
            method='POST',
            headers={'Authorization': f'Bearer {token}', 'Accept': 'application/json', 'Content-Type': 'application/json'},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                options = [s['option'] for s in json.load(resp).get('suggestions', [])]
            out[name] = [o for o in options if o not in ('-', '*')]
        except Exception as e:  # noqa: BLE001 - reported, the skill decides
            out[name] = f'unreadable: {e}'
    return out


def field(issue, name):
    for cf in issue.get('customFields') or []:
        if cf.get('name') == name:
            value = cf.get('value')
            return value.get('name') if isinstance(value, dict) else value
    return None


def compact(issue, profile):
    links = {'parent': [], 'subtasks': [], 'depends_on': [], 'required_for': [], 'relates': []}
    for link in issue.get('links') or []:
        kind = (link.get('linkType') or {}).get('name')
        ids = [i['idReadable'] for i in link.get('issues') or []]
        if not ids:
            continue
        direction = link.get('direction')
        if kind == 'Subtask':
            links['subtasks' if direction == 'OUTWARD' else 'parent'] += ids
        elif kind == 'Depend':
            links['required_for' if direction == 'OUTWARD' else 'depends_on'] += ids
        elif kind == 'Relates':
            links['relates'] += ids
    marker = MARKER.search(issue.get('description') or '')
    return {
        'id': issue['idReadable'],
        'summary': (issue.get('summary') or '').strip(),
        'type': field(issue, 'Type'),
        'stage': field(issue, (profile or {}).get('column_field') or 'Stage'),
        'sdlc_mode': field(issue, (profile or {}).get('sdlc_mode_field') or 'sdlc-mode'),
        'resolved': bool(issue.get('resolved')),
        'roadmap_step': marker.group(1) if marker else None,
        **{k: v for k, v in links.items() if v},
    }


# --- staleness and coverage ----------------------------------------------------------------------


def changelog_exists(repo_root, slug):
    folder = os.path.join(repo_root, 'docs', 'features', slug or '')
    if not slug or not os.path.isdir(folder):
        return False
    return any(f.lower() == 'changelog.md' for f in os.listdir(folder))


def analyse(repo_root, roadmap, issues):
    stale, info = [], []
    rel = 'docs/roadmap.md'

    dirty = git(repo_root, 'status', '--porcelain', '--', rel)
    if dirty:
        stale.append(f'{rel} has uncommitted changes ({dirty.split()[0]}): the plan would be built on an unmerged roadmap')
    if git(repo_root, 'rev-parse', '--verify', '--quiet', 'origin/main'):
        behind = git(repo_root, 'diff', '--name-only', 'HEAD', 'origin/main', '--', rel)
        if behind:
            stale.append(f'{rel} differs from origin/main as last fetched: pull before planning')

    by_id = {i['id'].lower(): i for i in issues}
    shipped_table = set(roadmap['shipped_table'])
    for step in roadmap['steps']:
        num, status = step['num'], step['status']
        shipped = status == 'shipped'
        if shipped and num not in shipped_table:
            stale.append(f'step {num} is shipped but missing from the Shipped table')
        if not shipped and num in shipped_table:
            stale.append(f'step {num} is in the Shipped table but its status is "{status}"')
        if not shipped and changelog_exists(repo_root, step['slug']):
            stale.append(f'step {num} ({step["slug"]}) has a CHANGELOG.md but its status is "{status}"')
        if not shipped and step['slug'] and os.path.isdir(os.path.join(repo_root, 'docs', 'features', step['slug'])):
            info.append(f'step {num}: docs/features/{step["slug"]}/ already exists (work has started)')

        marked = [i['id'] for i in issues if i['roadmap_step'] and i['roadmap_step'].lower() == num.lower()]
        row = {r.lower() for r in step['row_tickets']}
        # The write-back links a step's representative only; its children reach the row through their parent.
        unlinked = [
            t for t in marked
            if t.lower() not in row and not any(p.lower() in row for p in by_id[t.lower()].get('parent', []))
        ]
        if unlinked:
            stale.append(f'step {num}: {", ".join(unlinked)} name it as their roadmap step, but its row does not link them')
        tickets = sorted({*step['row_tickets'], *marked}, key=lambda s: int(s.split('-')[1]))
        step['tickets'] = tickets
        known = [by_id[t.lower()] for t in tickets if t.lower() in by_id]
        open_ = [t['id'] for t in known if not t['resolved']]
        done = [t['id'] for t in known if t['resolved']]
        if not shipped and done and not open_:
            stale.append(f'step {num} is "{status}" but its ticket(s) {", ".join(done)} are resolved')
        if shipped and open_ and not done:
            stale.append(f'step {num} is shipped but its ticket(s) {", ".join(open_)} are still open')
        step['covered'] = bool(known)
        missing = [t for t in tickets if t.lower() not in by_id]
        if missing and issues:
            info.append(f'step {num} links {", ".join(missing)}, which the tracker did not return')

    return stale, info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo-root', default='.')
    parser.add_argument('--no-tracker', action='store_true', help='skip the YouTrack read')
    args = parser.parse_args()
    repo_root = os.path.abspath(args.repo_root)
    sys.stdout.reconfigure(encoding='utf-8')  # roadmaps carry arrows and dashes; the Windows console is cp1252

    out = {'repo_root': repo_root, 'warnings': []}
    profile = read_profile(repo_root)
    out['profile'] = profile
    if not profile:
        out['warnings'].append('no .claude/yi-sdlc/project.md: this is not a yi-sdlc ticket repo')

    remote = git(repo_root, 'remote', 'get-url', 'origin') or ''
    m = re.match(r'(?:https://|git@)github\.com[/:]([^/]+)/(.+?)(?:\.git)?$', remote)
    out['repo_web'] = f'https://github.com/{m.group(1)}/{m.group(2)}/blob/main' if m else None

    path = os.path.join(repo_root, 'docs', 'roadmap.md')
    if not os.path.isfile(path):
        out['roadmap'] = 'missing'
        print(json.dumps(out, indent=1, ensure_ascii=False))
        return
    roadmap = parse_roadmap(open(path, encoding='utf-8').read(), (profile or {}).get('project'))
    if not roadmap['steps']:
        out['warnings'].append('docs/roadmap.md has no "## Steps" table the scanner could read')

    issues = []
    if not args.no_tracker and profile and profile.get('project'):
        token, url = user_env('YOUTRACK_TOKEN'), base_url(profile)
        if not token or not url:
            out['warnings'].append('YOUTRACK_TOKEN or the YouTrack URL is not set: tracker not read, coverage unknown')
        else:
            try:
                names = ['Type', profile.get('column_field') or 'Stage', profile.get('sdlc_mode_field') or 'sdlc-mode']
                out['field_values'] = field_values(url, token, profile['project'], names)
                raw = fetch_issues(url, token, profile['project'])
                # create_issue wants the project's internal id (e.g. 0-1), not its short name.
                out['project_id'] = next(((i.get('project') or {}).get('id') for i in raw if i.get('project')), None)
                issues = [compact(i, profile) for i in raw]
            except Exception as e:  # report, don't crash: the skill decides whether to go on
                out['warnings'].append(f'tracker read failed: {e}')
    out['tracker_read'] = bool(issues)

    stale, info = analyse(repo_root, roadmap, issues)
    # Shipped steps only matter as dependency endpoints and for the stale checks above: keep them short.
    open_nums = {s['num'] for s in roadmap['steps'] if s['status'] != 'shipped'}
    roadmap['steps'] = [
        s if s['num'] in open_nums else {k: s[k] for k in ('num', 'name', 'slug', 'status', 'tickets')}
        for s in roadmap['steps']
    ]
    roadmap['edges'] = [e for e in roadmap['edges'] if e['to'] in open_nums]
    out['roadmap'] = {k: v for k, v in roadmap.items() if k != 'shipped_table'}
    out['stale'] = stale
    out['info'] = info
    out['open_steps'] = [s['num'] for s in roadmap['steps'] if s['status'] != 'shipped']
    out['uncovered_steps'] = [s['num'] for s in roadmap['steps'] if s['status'] != 'shipped' and not s['covered']]
    out['open_issues'] = [i for i in issues if not i['resolved']]
    print(json.dumps(out, indent=1, ensure_ascii=False))


if __name__ == '__main__':
    main()
