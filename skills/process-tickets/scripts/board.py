"""Rank the next YouTrack tickets to work on for a yi-sdlc repo.

Reads the board in one REST call, joins it with the repo's Panes, git branches and roadmap order, and
prints JSON: the ranked candidates (features first, then tasks of features already running in a Pane),
plus what is in flight, blocked, or looks done but is still open on the board.

When the Pane app isn't running it launches it and waits for it (up to 90 s), unless --no-start-pane.

The project, the board's field and its columns come from the repo's .claude/yi-sdlc/project.md
(§ Tracker): columns before the in-progress one are startable, the in-progress, blocked, in-review and
test ones mean someone is on it.

Usage: python board.py [--repo-root PATH] [--top 5] [--no-start-pane]
Needs YOUTRACK_TOKEN (process env or the Windows user env); YOUTRACK_URL or the profile's ticket_url.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

PRIORITY_ORDER = ['Show-stopper', 'Critical', 'Major', 'Normal', 'Minor']
# Column roles that mean someone is already on it, so it is not a fresh candidate.
IN_FLIGHT_ROLES = ('in-progress', 'blocked', 'in-review', 'test')


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


def read_profile(repo_root):
    """What the ranking needs from profile § Tracker; exits when the repo isn't a YouTrack yi-sdlc repo."""
    path = os.path.join(repo_root, '.claude', 'yi-sdlc', 'project.md')
    try:
        text = open(path, encoding='utf-8').read()
    except OSError:
        sys.exit(f'No {path}: this is not a yi-sdlc ticket repo')

    def one(pattern):
        m = re.search(pattern, text)
        return m.group(1).strip().strip('\'"') if m else None

    adapter = one(r'adapter:\s*(\S+)')
    if adapter != 'youtrack':
        sys.exit(f"The profile's tracker adapter is {adapter}: only youtrack is implemented")
    key = re.search(r'\^?([A-Za-z]\w*)-', one(r'id_pattern:\s*(\S+)') or '')
    if not key:
        sys.exit('No id_pattern in the profile § Tracker to take the project key from')

    columns, roles = [], {}
    block = re.search(r'columns:\s*\n((?:\s+-.*\n)+)', text)
    for line in block.group(1).splitlines() if block else []:
        m = re.match(r'\s+-\s*\{\s*name:\s*([^,}]+?)\s*,\s*role:\s*([\w-]+)', line)
        if m:
            columns.append(m.group(1))
            roles[m.group(2)] = m.group(1)
        elif m := re.match(r'\s+-\s*(.+?)\s*$', line):
            columns.append(m.group(1))
    if 'in-progress' not in roles:
        sys.exit('The profile § Tracker columns give no column the in-progress role')

    return {
        'project': key.group(1),
        'ticket_url': one(r'ticket_url:\s*(\S+)'),
        'column_field': one(r'(?m)column_field:\s*([^#\n]+?)\s*(?:#|$)') or 'State',
        'startable': set(columns[: columns.index(roles['in-progress'])]) | {None},
        'in_flight': {roles[r] for r in IN_FLIGHT_ROLES if r in roles},
    }


def base_url(profile):
    url = user_env('YOUTRACK_URL')
    if url:
        return url.rstrip('/')
    m = re.match(r'(https?://[^/\s]+)', profile['ticket_url'] or '')
    if not m:
        sys.exit('No YOUTRACK_URL and no ticket_url in .claude/yi-sdlc/project.md')
    return m.group(1)


def fetch_issues(url, token, project):
    fields = (
        'idReadable,summary,resolved,customFields(name,value(name)),'
        'links(direction,linkType(name),issues(idReadable,summary,resolved,customFields(name,value(name))))'
    )
    query = urllib.parse.urlencode(
        {'query': f'project: {project} #Unresolved', 'fields': fields, '$top': 1000}
    )
    req = urllib.request.Request(
        f'{url}/api/issues?{query}',
        headers={'Authorization': f'Bearer {token}', 'Accept': 'application/json'},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def field(issue, name):
    for cf in issue.get('customFields') or []:
        if cf.get('name') == name:
            value = cf.get('value')
            return value.get('name') if isinstance(value, dict) else value
    return None


def linked(issue, link_name, direction):
    out = []
    for link in issue.get('links') or []:
        if link['linkType']['name'] == link_name and link['direction'] == direction:
            out.extend(link['issues'])
    return out


def slug_of(issue_type, summary):
    if issue_type in ('Feature', 'Epic'):
        m = re.search(r'\(([a-z0-9][a-z0-9-]*)\)\s*$', summary)
    else:
        m = re.match(r'([a-z0-9][a-z0-9-]*):', summary)
    return m.group(1) if m else None


def issue_number(issue_id):
    return int(issue_id.split('-')[-1])


def roadmap_order(repo_root, project):
    """Issue IDs (lower case) in the order the roadmap's Next and Later tables list them (the owner's order)."""
    try:
        text = open(os.path.join(repo_root, 'docs', 'roadmap.md'), encoding='utf-8').read()
    except OSError:
        return {}
    start = text.find('## Next')
    order = {}
    for m in re.finditer(rf'\b{re.escape(project)}-\d+\b', text[start if start >= 0 else 0 :], re.IGNORECASE):
        order.setdefault(m.group(0).lower(), len(order))
    return order


def runpane():
    exe = os.path.join(os.path.expanduser('~'), '.pane', 'bin', 'runpane.cmd')
    return exe if os.path.exists(exe) else 'runpane'


def run_runpane(*args, timeout=60):
    return subprocess.run(
        [runpane(), *args], capture_output=True, text=True, timeout=timeout,
        shell=sys.platform == 'win32',
    )


def pane_reachable():
    try:
        return json.loads(run_runpane('repos', 'list', '--json', timeout=30).stdout).get('ok', False)
    except Exception:
        return False


def pane_app_path():
    """The installed Pane app, as runpane doctor finds it, else the Windows per-user install folder."""
    try:
        out = run_runpane('doctor', '--json').stdout
        # doctor's JSON isn't always valid (unescaped quotes in watchDefaults), so read the one field by pattern
        m = re.search(r'"installedPane":\s*\{\s*"found":\s*true,\s*"path":\s*"((?:[^"\\]|\\.)*)"', out)
        if m:
            return json.loads(f'"{m.group(1)}"')
    except Exception:
        pass
    default = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Programs', 'Pane', 'Pane.exe')
    return default if os.path.exists(default) else None


def ensure_pane(start, timeout=90):
    """Pane's state for the ranking; when the app is down and start is set, launch it and wait for it."""
    if pane_reachable():
        return {'state': 'running'}
    if not start:
        return {'state': 'down', 'reason': 'Pane is not running (--no-start-pane)'}
    if sys.platform == 'darwin':
        app, cmd = 'Pane.app', ['open', '-a', 'Pane']
    else:
        app = pane_app_path()
        if not app:
            return {'state': 'down', 'reason': 'Pane is not running and no installed Pane app was found'}
        cmd = [app]
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP if sys.platform == 'win32' else 0
    # Pane writes backend-debug.log into its working folder, so don't start it from the repo
    cwd = os.path.dirname(app) if os.path.isabs(app) else os.path.expanduser('~')
    subprocess.Popen(
        cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=flags, start_new_session=sys.platform != 'win32', close_fds=True,
    )
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(2)
        if pane_reachable():
            return {'state': 'started', 'app': app}
    return {'state': 'down', 'reason': f'started {app}, but Pane did not answer within {timeout}s'}


def list_panes(repo_root):
    try:
        out = run_runpane('panes', 'list', '--repo', repo_root, '--json')
        return json.loads(out.stdout).get('panes', []), None
    except Exception as exc:  # Pane not running: rank without it, and say so
        return [], f'runpane panes list failed: {exc}'


def list_branches(repo_root):
    out = subprocess.run(
        ['git', '-C', repo_root, 'branch', '-a', '--format=%(refname:short)'],
        capture_output=True, text=True,
    )
    return [b.strip() for b in out.stdout.splitlines() if b.strip() and '->' not in b]


def find_pane(panes, issue_id, slug):
    for pane in panes:
        names = {pane.get('name') or '', os.path.basename(pane.get('worktreePath') or '')}
        if (slug and slug in names) or any(re.search(rf'\b{re.escape(issue_id)}\b', n) for n in names):
            return {
                'id': pane['id'],
                'name': pane.get('name'),
                'worktree': pane.get('worktreePath'),
                'agentState': pane.get('agentState'),
                'status': pane.get('status'),
            }
    return None


def find_branches(branches, issue_id, slug):
    hits = []
    for b in branches:
        short = b.split('/', 1)[1] if b.startswith('origin/') else b
        if re.search(rf'(^|/){re.escape(issue_id)}(-|$)', short) or (slug and short.split('/')[-1] == slug):
            hits.append(b)
    return hits


def task_entry(worktree, slug, issue_id):
    """The tasks.json entry for this ticket in the feature's worktree, if it is broken down yet."""
    if not worktree or not slug:
        return None, False
    path = os.path.join(worktree, 'docs', 'features', slug, 'tasks', 'tasks.json')
    try:
        data = json.load(open(path, encoding='utf-8'))
    except (OSError, ValueError):
        return None, False
    for task in data.get('tasks', []):
        if task.get('ticket') == issue_id:
            return task.get('id'), True
    return None, True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo-root', default=os.getcwd())
    ap.add_argument('--top', type=int, default=5)
    ap.add_argument('--no-start-pane', action='store_true', help="don't launch Pane when it isn't running")
    args = ap.parse_args()
    repo_root = os.path.abspath(args.repo_root)
    profile = read_profile(repo_root)

    token = user_env('YOUTRACK_TOKEN')
    if not token:
        sys.exit('YOUTRACK_TOKEN is not set (process env or Windows user env)')
    issues = fetch_issues(base_url(profile), token, profile['project'])
    pane_app = ensure_pane(start=not args.no_start_pane)
    panes, pane_warning = list_panes(repo_root) if pane_app['state'] != 'down' else ([], pane_app['reason'])
    branches = list_branches(repo_root)
    order = roadmap_order(repo_root, profile['project'])
    startable, in_flight_stages = profile['startable'], profile['in_flight']

    by_id = {}
    for issue in issues:
        iid = issue['idReadable']
        itype = field(issue, 'Type')
        slug = slug_of(itype, issue['summary'])
        children = linked(issue, 'Subtask', 'OUTWARD')
        parents = [p for p in linked(issue, 'Subtask', 'INWARD') if field(p, 'Type') != 'Epic']
        by_id[iid] = {
            'id': iid,
            'type': itype,
            'summary': issue['summary'],
            'slug': slug,
            'priority': field(issue, 'Priority'),
            'stage': field(issue, profile['column_field']),
            'open_blockers': [b['idReadable'] for b in linked(issue, 'Depend', 'INWARD') if not b.get('resolved')],
            'children_total': len(children),
            'children_open': sum(1 for c in children if not c.get('resolved')),
            'parent': parents[0]['idReadable'] if parents else None,
            'pane': find_pane(panes, iid, slug) if itype == 'Feature' else None,
            'branches': find_branches(branches, iid, slug) if itype == 'Feature' else [],
        }

    def rank_key(item):
        pri = PRIORITY_ORDER.index(item['priority']) if item['priority'] in PRIORITY_ORDER else len(PRIORITY_ORDER)
        return (pri, order.get(item['id'].lower(), 10_000), issue_number(item['id']))

    features = [i for i in by_id.values() if i['type'] == 'Feature']
    stale, in_flight, blocked, feature_candidates = [], [], [], []
    for f in features:
        if f['children_total'] and not f['children_open']:
            stale.append({'id': f['id'], 'summary': f['summary'], 'stage': f['stage'],
                          'reason': f"all {f['children_total']} subtasks resolved, ticket still {f['stage']}",
                          'pane': f['pane'], 'branches': f['branches']})
        elif f['pane'] or f['branches'] or f['stage'] in in_flight_stages:
            in_flight.append(f)
        elif f['open_blockers']:
            blocked.append(f)
        elif f['stage'] in startable:
            feature_candidates.append(f)
    stale_ids = {s['id'] for s in stale}

    task_candidates = []
    for f in sorted(in_flight, key=rank_key):
        if f['open_blockers'] or not f['pane']:
            continue  # a branch without a Pane: nothing to add a tab to
        tasks = [t for t in by_id.values() if t['parent'] == f['id'] and t['type'] == 'Task']
        for t in sorted(tasks, key=lambda t: issue_number(t['id'])):
            if t['open_blockers'] or t['stage'] not in startable:
                continue
            task_id, broken_down = task_entry(f['pane']['worktree'], f['slug'], t['id'])
            if not broken_down or not task_id:
                continue  # the feature hasn't reached break-tasks yet, or this ticket isn't in its plan
            task_candidates.append({**t, 'feature': f['id'], 'feature_slug': f['slug'],
                                    'pane': f['pane'], 'task_id': task_id,
                                    'rank_key': rank_key(f) + (issue_number(t['id']),)})

    candidates = []
    for f in sorted(feature_candidates, key=rank_key):
        tasks = sorted((t for t in by_id.values() if t['parent'] == f['id']), key=lambda t: issue_number(t['id']))
        first_task = next((t['id'] for t in tasks if not t['open_blockers']), None)
        candidates.append({'kind': 'feature', 'action': 'new-pane', 'id': f['id'], 'summary': f['summary'],
                           'slug': f['slug'], 'priority': f['priority'], 'stage': f['stage'],
                           'roadmap_pos': order.get(f['id'].lower()), 'tasks_open': f['children_open'],
                           'tasks': [t['id'] for t in tasks], 'first_task': first_task})
    for t in sorted(task_candidates, key=lambda t: t['rank_key']):
        candidates.append({'kind': 'task', 'action': 'tab', 'id': t['id'], 'summary': t['summary'],
                           'priority': t['priority'], 'stage': t['stage'], 'feature': t['feature'],
                           'feature_slug': t['feature_slug'], 'task_id': t['task_id'], 'pane': t['pane']})
    for rank, c in enumerate(candidates, 1):
        c['rank'] = rank

    result = {
        'top': candidates[: args.top],
        'more_candidates': max(0, len(candidates) - args.top),
        'in_flight': [{'id': f['id'], 'summary': f['summary'], 'stage': f['stage'], 'pane': f['pane'],
                       'branches': f['branches'], 'tasks_open': f['children_open']} for f in in_flight],
        'blocked': [{'id': f['id'], 'summary': f['summary'], 'priority': f['priority'],
                     'open_blockers': [{'id': b, 'looks_done': b in stale_ids} for b in f['open_blockers']]}
                    for f in sorted(blocked, key=rank_key)],
        'stale': stale,
        'pane_app': pane_app,
        'warnings': [w for w in [pane_warning] if w],
    }
    json.dump(result, sys.stdout, indent=1)


if __name__ == '__main__':
    main()
