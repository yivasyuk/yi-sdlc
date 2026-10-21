---
name: complete
description: >-
  Finish the current piece of work in one go: branch off main if needed, commit this session's changes
  (with --force, everything in the working tree, untracked files included) with a message that explains
  them, push, open a pull request, wait for its builds, and squash-merge it once
  they pass. An optional free-text prompt steers the run (what to include, how to word the commit or PR,
  what to tell reviewers). Operator-only: runs from /yi-sdlc:complete, never on Claude's own initiative.
  Commit, branch and PR wording follow yi-sdlc:git-commit.
disable-model-invocation: true
argument-hint: "[--force] [prompt]"
---

# Complete: commit, PR, merge

The operator runs `/yi-sdlc:complete` and expects the work to land on main. Run the steps in order and
stop at the first failure with what broke; never paper over a failure to get the merge through.

Conventions for the branch name, the commit subject and body and the PR title come from
[`../git-commit/SKILL.md`](../git-commit/SKILL.md). Read it first; the repo profile
(`.claude/yi-sdlc/project.md` § Commits) wins where it overrides them.
Arguments, both optional:

- `--force` (or `force`): commit everything in the working tree, not only this session's changes (step 2).
- Any other text is the operator's prompt: free-text instructions for this run, such as which files to
  include or leave out, the commit subject or what the message should stress, the branch name, or notes
  for the PR body. Examples: `/yi-sdlc:complete only the hooks changes`,
  `/yi-sdlc:complete subject "Retry the gate driver on timeout"`,
  `/yi-sdlc:complete mention in the PR that the config needs a restart`.

Where the prompt and a step below disagree, the prompt wins, with one exception: it can't lift the hard
limits (no secrets or oversized files staged, no `--no-verify` or amend, no merge while a check fails, no
`--admin`). If the prompt asks for one of those, say it won't be done and carry on with the rest. If the
prompt is unclear in a way that changes what gets committed or merged, ask before step 2.

## 1. Branch

Find the default branch (`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`).

- On the default branch: create `<group>/<name>` (`git switch -c`) as git-commit describes, named after
  the change.
- On any other branch: stay on it.

## 2. Stage

Stage only what this session changed, by path (`git add -- <paths>`, renames included). Leave files that
were already modified or untracked before the session started, and anything unrelated, out of the commit;
say which ones were left out in the final report. When it is unclear whether a file belongs, ask. Never
stage secrets (`.env`, keys, credentials).

With `--force`, the operator has already decided that everything goes in: stage every change in the
working tree, tracked and untracked, including files that predate the session (`git add -A`; `.gitignore`
still applies). Don't ask about individual files. Two limits stay:

- Secrets: unstage anything that looks like one (`.env`, keys, credentials, tokens) and name it in the
  report. A leaked secret costs far more than a second commit.
- Size: unstage single files over ~10 MB (build output, dumps, binaries that `.gitignore` misses) and name
  them in the report.

Before committing, list what is staged (`git status --short`) and write the commit body to cover all of
it, not only this session's part.

Nothing to commit and no unpushed commits → stop and say so.

## 3. Commit

Subject as git-commit says. For anything beyond a one-liner, a body wrapped at ~72 chars: what changed and
why, plus migrations, contract changes and follow-ups. End with the attribution line the session gives for
commits. Pass the message through a heredoc (`git commit -F -`). If a hook fails, fix the cause and make a
new commit; don't `--no-verify` or amend.

## 4. Push and open the PR

`git push -u origin <branch>`.

If the branch already has an open PR (`gh pr view --json number,url`), the push updated it; reuse it.
Otherwise `gh pr create --base <default> --title <subject> --body-file -` with a body of: what changed,
why, links to the feature docs or ADRs when there are any, and reviewer notes (migrations, config or secret
changes, follow-ups). End it with the attribution line the session gives for PRs.

## 5. Wait for the builds, then merge

Checks can take a few seconds to register after a push. Then wait on them:

```
gh pr checks <number> --watch --fail-fast
```

Run it in the background or with the longest timeout, since builds can take minutes.

- **All passed** → merge.
- **No checks reported** (the repo has no CI) → merge.
- **A check failed** → don't merge. Show which check failed and its failing log
  (`gh run view <run-id> --log-failed`, trimmed to the error), and stop. The operator decides whether to
  fix and run `/yi-sdlc:complete` again.

Merge with `gh pr merge <number> --squash --delete-branch`. If the repo doesn't allow squash, use the
method it allows (`gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed`). If the
merge is refused (required reviews, branch protection), report why and stop; never use `--admin`.

## 6. Sync and report

Switch to the default branch and `git pull`. In a git worktree whose default branch is checked out
elsewhere, skip the switch and just `git fetch`.

Report in a few lines: the merge commit hash and subject, the PR link, the checks result (passed, or none
configured), any files left out of the commit, and any part of the prompt that wasn't followed and why.
