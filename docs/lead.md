# Lead templates

Templates the project lead fills in for workers and reviewers, and a note on how the lead is triggered. The charter is the "Project lead" section of `AGENTS.md`.

## Worker brief

```text
You are the <core | app | designer | tester> worker on Isotope. Work only inside the git worktree `<absolute worktree path>` on branch `<branch>`: `cd` there first and use absolute paths, because your starting directory may be a different checkout. Read AGENTS.md first.

Task: <one paragraph: what to change and why>

- <concrete requirement>
- <concrete requirement>
- Run the tests from AGENTS.md "Build and test": `swift test --package-path IsotopeCore` for IsotopeCore work, and for app work also `xcodegen generate && xcodebuild -project Isotope.xcodeproj -scheme Isotope -derivedDataPath "$TMPDIR/isotope-dd" test`. The app-layer suite starts the real app against the real state folder, so run it only if `! pgrep -x Isotope && out=$(diskutil list external physical) && [ -z "$out" ]` succeeds (run it with the sandbox off); otherwise skip the suite and say so, and the lead runs it. Report the results, then delete `$TMPDIR/isotope-dd`.
- Add or update a test for any behaviour you change. Keep IsotopeCore free of SwiftUI, AppKit, CryptoKit and DiskArbitration.
- Catalog work: run `Scripts/verify-catalog.sh` and report each channel it flags.

Never touch a real USB device, never launch or drive /Applications/Isotope.app, and never read or write ~/Library/Application Support/Isotope or ~/Library/Caches/Isotope (the app-layer suite's own rewrite of release-cache.json is the one known exception). Tests use fakes and temporary directories. Don't commit, push, open a PR, or use ERPNext; the lead does that. Change nothing outside the task, and don't change the version.

Finish with a short report: files changed, test results, anything you were unsure about. For UI work, list the views to look at.
```

Workers are Claude subagents (Agent tool, run in the foreground). A tester worker's brief names the behaviour to check and the test files to extend. It reports bugs to the lead, which files them as Intake tasks in ERPNext.

## Review

Claude reviews every PR before merge, in a fresh subagent that did not write the code. Give it the prompt below with `DIFF:` replaced by "Run `gh pr diff <n>` for the diff."

```text
You are an outside reviewer for the Isotope repo, a macOS app that writes ISO files to, and can erase, the user's USB drives. You did not write this change. Review the pull request whose diff is below (base: main), with the repo checked out in the current directory for context. Read AGENTS.md and any files the diff touches or refers to.

Check correctness: bugs, missing failure cases, claims that don't match the repo (paths, commands, hooks, how it builds, tests or ships), contradictions with AGENTS.md, and rules that would mislead an agent. For code, also check: nothing unverified reaches a drive; a delete or flash can't hit the wrong file or device; IsotopeCore imports only Foundation; no new dependency; tests are offline and use fakes; old drives.json, history.json and custom-sources.json still load; README counts and figures match; no secret, token, personal path or private address in the diff. Skip style nits.

Don't edit files, run the app or the app-layer tests, touch any drive or ~/Library/*/Isotope, use ERPNext, or comment on or approve the PR with `gh`. Reply with exactly one first line, `VERDICT: APPROVE` or `VERDICT: CHANGES`, then a numbered list of findings, each with file:line, what is wrong, and the fix. APPROVE means nothing must change before merge; list optional suggestions separately under "Optional".

DIFF:
```

Codex is a second review for the risky areas in `AGENTS.md` or when Claude is unsure, never for docs-only PRs. Build a prompt file from the prompt above followed by the output of `gh pr diff <n>`, and run `codex exec -m gpt-6.1-terra -s read-only -C <worktree> -o <report file> - < <prompt file>` (`gpt-6.1-sol` for a hard review). The Codex sandbox cannot run `xcodebuild` or `swift test` reliably; if a test fails there with a permission or sandbox error, report it separately from real failures, and the lead reruns it outside the sandbox.

## Version-bump commit

After the tests pass and the review approves, bump the version as one commit that touches only `project.yml` and `Isotope/Info.plist` (see Release in `AGENTS.md`), after every required review has approved. Check `git diff --cached` before you commit, not after. A local hook builds and installs the app when this commit lands, so first check that the app isn't writing to a drive: `lsof -c Isotope 2>/dev/null | grep -E ' /dev/r?disk| /Volumes/'` must print nothing. This commit needs no new review. Wait until the installed `CFBundleVersion` matches before you merge, and for a drive-touching change also wait for Sahil's OK (see step 7 of Each run).

## How the lead is triggered

Three T3 scheduled tasks in the Isotope project start the lead. The weekly checks of Sahil's leads are staggered by day: Sun Makeable, Mon Meterkat, Tue Rummage, Wed Suede Cam, Fri Isotope, Sat Family Tree. Scout's weekly research run for Isotope is on Wednesdays at 08:00, before the Friday check.

- "Isotope lead: event reply": starts when Sahil comments on a task in the Isotope ERPNext project. It reads that task and its comments, replies if Sahil's comment waits on an answer, and settles. It only talks.
- "Isotope lead: daily replies", 07:40 Dubai every day except Friday. It only talks in ERPNext (replies, the Verifier-based comments on Scout's tasks) and passes work to the weekly check through the "For the weekly check (Friday)" list in Lead notes. See Each run in `AGENTS.md` for what it must not do.
- "Isotope lead: weekly check", Fridays at 09:00 Dubai. It starts with that list, checks usage, runs `Scripts/verify-catalog.sh`, triages Intake (Scout's tasks only after the Verifier's comment), and takes every ready task the usage guard allows to `Completed`, highest priority first. Anything that needs Sahil is a flagged task (a comment with `needs_sahil` checked), never a reason to keep the thread open: the run settles its thread when its work is done, and leaves it unsettled with a warning sign only when the run itself failed or could not reach ERPNext.

The lead's ERPNext user is `isotope-lead`, pinned to the Isotope project. It reaches ERPNext through the `erp-lead` MCP in `.mcp.json`, a local stdio server started as `~/.local/bin/erp-mcp isotope-lead`; Scout uses `erp-scout` the same way. Load the `erp-work` skill before touching a task.
