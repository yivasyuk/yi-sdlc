---
name: complete
description: >-
  Finish the current piece of work in one go: find every change in the working tree, untracked files
  included (with --session, only this session's changes), split it into logical changes, and land each one
  on its own branch with its own commit and pull request, squash-merged once its builds pass. With --one-pr,
  everything goes into a single commit and PR instead. An optional free-text prompt steers the run (what to
  include, how to group it, how to word the commits or PRs, what to tell reviewers). Operator-only: runs
  from /yi-sdlc:complete, never on Claude's own initiative. Commit, branch and PR wording follow
  yi-sdlc:git-commit.
disable-model-invocation: true
argument-hint: "[--one-pr] [--session] [prompt]"
---

# Complete: commit, PR, merge

The operator runs `/yi-sdlc:complete` and expects the work to land on main, one pull request per logical
change. Run the steps in order; when something breaks, stop the change it belongs to with what broke and
never paper over a failure to get a merge through.

Conventions for the branch names, the commit subjects and bodies and the PR titles come from
[`../git-commit/SKILL.md`](../git-commit/SKILL.md). Read it first; the repo profile
(`.claude/yi-sdlc/project.md` § Commits) wins where it overrides them.
Arguments, all optional:

- `--one-pr` (or `one-pr`): don't split; everything found in step 1 goes into one commit and one PR.
- `--session` (or `session`): take only this session's changes, not everything in the working tree
  (step 1). `--force` (or `force`) is still accepted and changes nothing, since taking everything is the
  default.
- Any other text is the operator's prompt: free-text instructions for this run, such as which files to
  include or leave out, how to group them, the commit subjects or what the messages should stress, the
  branch names, or notes for the PR bodies. Examples: `/yi-sdlc:complete only the hooks changes`,
  `/yi-sdlc:complete keep the docs and the hook fix together`,
  `/yi-sdlc:complete mention in the PR that the config needs a restart`.

Where the prompt and a step below disagree, the prompt wins, with one exception: it can't lift the hard
limits (no secrets or oversized files committed, no `--no-verify` or amend, no merge while a check fails, no
`--admin`). If the prompt asks for one of those, say it won't be done and carry on with the rest. If the
prompt is unclear in a way that changes what gets committed or merged, ask before step 3.

## 1. Find the changes

Find the default branch (`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`) and look at
what is there to land, without asking the operator to list it: `git status --porcelain` (tracked and
untracked; `.gitignore` applies), `git diff HEAD` for the content, and, on a branch other than the default,
the commits not yet on it (`git log origin/<default>..HEAD`) and its open PR if any
(`gh pr view --json number,url`).

By default every change in the working tree is in scope, including files that predate the session. Don't
ask about individual files. Two limits stay:

- Secrets: leave out anything that looks like one (`.env`, keys, credentials, tokens) and name it in the
  report. A leaked secret costs far more than a second commit.
- Size: leave out single files over ~10 MB (build output, dumps, binaries that `.gitignore` misses) and
  name them in the report.

With `--session`, only what this session changed is in scope. Leave files that were already modified or
untracked before the session started, and anything unrelated, out; say which ones were left out in the
final report. When it is unclear whether a file belongs, ask.

Nothing in scope and no unpushed commits → stop and say so.

## 2. Group into logical changes

Skip this step with `--one-pr`: everything in scope is one group.

Otherwise split the changes into groups, one per logical change: a reason to exist that a reviewer would
judge on its own (a feature, a fix, a refactor, a docs update, a dependency or config bump). Find the
groups from what is already known about the work before guessing from the code, in this order:

1. The prompt, when it says how to group.
2. This session. The conversation records which requests the operator made and which files each one
   touched; each request the session finished is a group, named and explained after that request. A
   follow-up that reworked an earlier request's files (a correction, a rename) belongs to that request's
   group. Session changes and changes that predate the session don't share a group unless the diff shows
   they are one change.
3. Claude's memory, when the session has one (the `MEMORY.md` index and the files it points to, project
   entries first). Use it to tell which piece of earlier or parallel work a change made before this
   session belongs to, and to word that group's commit and PR.
4. The diffs themselves, for whatever is left: read the content, not just the paths. Two files in one
   folder can be unrelated, and a code change with its tests, docs and config belongs together.

Memory and the session tell you which change a file belongs to; the diff has the final say over what the
file actually holds. Rules:

- A file goes into exactly one group, whole. When one file holds hunks of two changes, the groups it
  touches merge into one.
- Groups must stand alone: each has to build and pass checks on top of the default branch without the
  others. When one needs another, they are one logical change; merge them.
- On a branch other than the default with unpushed commits or an open PR, that work is the first group
  and stays on that branch; uncommitted changes that belong to it join it.
- When in doubt, fewer groups. A slightly broad PR is cheaper than one that can't pass alone.

The prompt can override the grouping ("keep X and Y together", "split the docs out"). One group left →
carry on as with `--one-pr`. Show the plan in a few lines (each group's subject and files) and carry on
without waiting, saying for each group where it came from (this session's request, a memory entry, or
the diff); ask only when a grouping choice would change what lands together in a way that matters.

## 3. Branch and commit each group

For each group in turn:

1. Branch. The first group of a run started on a non-default branch stays on that branch. Every other
   group gets a new `<group>/<name>` branch as git-commit describes, named after the change, cut from the
   tip of the default branch: `git fetch origin` once, then `git switch -c <branch> origin/<default>`.
   Uncommitted changes of the remaining groups travel with the switch; files already committed on the
   previous group's branch drop out of the working tree until that group merges. If the switch refuses
   because of local changes, `git stash push --include-untracked`, switch, `git stash pop`.
2. Stage by path (`git add -- <paths>`, renames and deletions included), then check `git status --short`
   shows exactly the group's files staged.
3. Commit. Subject as git-commit says. For anything beyond a one-liner, a body wrapped at ~72 chars: what
   changed and why, plus migrations, contract changes and follow-ups. End with the attribution line the
   session gives for commits. Pass the message through a heredoc (`git commit -F -`). If a hook fails, fix
   the cause and make a new commit; don't `--no-verify` or amend.
4. Push and open the PR. `git push -u origin <branch>`. If the branch already has an open PR, the push
   updated it; reuse it. Otherwise `gh pr create --base <default> --title <subject> --body-file -` with a
   body of: what changed, why, links to the feature docs or ADRs when there are any, and reviewer notes
   (migrations, config or secret changes, follow-ups). When the run opened several PRs, list the sibling
   PRs in each body. End it with the attribution line the session gives for PRs.

Open every group's PR before waiting on any build, so their checks run side by side.

## 4. Wait for the builds, then merge

Checks can take a few seconds to register after a push. Then wait on each PR:

```
gh pr checks <number> --watch --fail-fast
```

Run these in the background or with the longest timeout, since builds can take minutes. Merge each PR as
soon as its own result is in; one PR's failure doesn't hold back the others, since every group stands
alone.

- **All passed** → merge.
- **No checks reported** (the repo has no CI) → merge.
- **A check failed** → don't merge that PR. Show which check failed and its failing log
  (`gh run view <run-id> --log-failed`, trimmed to the error), leave the PR open and go on with the rest.
  The operator decides whether to fix it and run `/yi-sdlc:complete` again.

Merge with `gh pr merge <number> --squash --delete-branch`. If the repo doesn't allow squash, use the
method it allows (`gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed`). If a
merge is refused because the branch is behind the default branch (branch protection that requires it up to
date), run `gh pr update-branch <number>`, wait for its checks again and retry. If it is refused for any
other reason (required reviews, other protection), report why and leave that PR open; never use `--admin`.

## 5. Sync and report

Switch to the default branch and `git pull`. In a git worktree whose default branch is checked out
elsewhere, skip the switch and just `git fetch`. Changes of a group whose PR stayed open live on its branch,
not in the working tree; say so.

Report one line per group: the merge commit hash and subject or why it didn't merge, the PR link, and the
checks result (passed, failed, or none configured). Then any files left out, and any part of the prompt that
wasn't followed and why.
