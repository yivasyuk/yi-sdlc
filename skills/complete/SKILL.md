---
name: complete
description: >-
  Finish the current piece of work in one go: branch off main if needed, commit this session's changes with
  a message that explains them, push, open a pull request, wait for its builds, and squash-merge it once
  they pass. Operator-only: runs from /yi-sdlc:complete, never on Claude's own initiative. Commit, branch
  and PR wording follow yi-sdlc:git-commit.
disable-model-invocation: true
argument-hint: "[commit subject override]"
---

# Complete: commit, PR, merge

The operator runs `/yi-sdlc:complete` and expects the work to land on main. Run the steps in order and
stop at the first failure with what broke; never paper over a failure to get the merge through.

Conventions for the branch name, the commit subject and body and the PR title come from
[`../git-commit/SKILL.md`](../git-commit/SKILL.md). Read it first. A repo profile
(`.claude/yi-sdlc/project.md` § Commits) or the repo's `AGENTS.md` / `CLAUDE.md` wins where they differ.
An argument, when given, is the commit subject to use.

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
configured), and any files left out of the commit.
