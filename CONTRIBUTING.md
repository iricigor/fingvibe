# Contributing

## Parallel feature work

Keep changes within the owning module whenever possible. Coordinate changes to shared models and contracts before editing them, and keep pull requests focused on one feature or structural refactor.

Current ownership boundaries:

- `MainWindow.xaml.cs` owns shell initialization, page routing, navigation, and top-level wiring.
- `MainWindow.Scan.cs` owns scan start, cancellation, progress, and completion status.
- `MainWindow.Results.cs` owns result collection, filtering, sorting, comparer state, and result summaries.
- `MainWindow.NetworkIdentity.cs` owns local network selection and public/local network identity display.
- `MainWindow.Snapshots.cs` owns snapshot restoration, persistence status, and saved-scan state.
- `MainWindow.DeviceDetails.cs` owns the selected-device details view.
- `LanScannerService` owns scan orchestration and probe lifecycle. `IScanResultEnricher` and `ScanResultEnricher` own device name, vendor, MAC, and port enrichment.

Keep page-specific layout and state with the page when adding or substantially changing a page. Limit shell changes to route registration and top-level wiring. Add regression tests alongside the module whose behavior they cover, and avoid unrelated formatting or cleanup in parallel pull requests.

## Architecture discussions with Architect

The repository's `.github/agents/architect.agent.md` defines **Architect**, a discussion-first partner for architecture decisions and implementation tradeoffs. It is manually selected rather than automatically delegated based on task similarity.

### Selecting Architect

In the GitHub Copilot app, select **Architect** from the agent picker in the prompt box before or during a session, or type `/agent` and choose it. Continue the discussion in the same session to preserve its conversation context.

In Copilot CLI, start an interactive session from this checkout with `copilot --agent architect`, or use `/agent` in an existing interactive session to select it. Use the filename stem, `architect`, for the command-line flag.

The definition must be present in the checkout used by the session. After adding it or pulling the change, reopen the agent picker; if it is not discovered, start a new session from the updated checkout. An existing worktree does not automatically receive files merged into another checkout. Agent availability and GitHub write operations also depend on the host's supported features, permissions, and authentication.

Typing "Architect, what do you think about...?" alone does not select or switch agents. After selecting Architect, that phrasing is simply a conversational cue. Asking a different active agent to delegate a question to Architect instead creates a separate subagent interaction; it does not switch the main chat's active agent. Do not assume separate invocations share context: provide the prior decisions, issue, and any authorization explicitly, or use the active Architect session for ongoing discussion.

The profile grants repository read/search, edit, and command-execution tools for its full workflow. Its discussion-first and confirmation gates are behavioral instructions, not a read-only security sandbox. Normal host permissions still apply. A host without issue, push, PR, or comment permissions cannot complete delivery; Architect must disclose the limitation rather than claim success.

### Example conversation and delivery

After selecting Architect:

> **User:** Architect, what do you think about separating snapshot persistence from the window?
>
> **Architect:** Inspects the relevant code, explains alternatives and tradeoffs, and asks about requirements that materially affect the design. No files are changed and no issue is created yet.
>
> **User:** I agree with that scope. Capture it in an issue.
>
> **Architect:** Creates the agreed GitHub issue and shares its link. Implementation has not started.
>
> **User:** Implement this issue.
>
> **Architect:** Checks all current open PRs, including drafts, against the planned changes. With no potential conflicts, proceeds without redundant confirmation. If there is a potential conflict, explains the affected PRs and components and waits for an additional explicit confirmation. An incomplete or failed assessment also requires confirmation.
>
> **User, only if another confirmation is needed:** Proceed despite the conflicts you identified.
>
> **Architect:** Implements the agreed scope, validates it, commits and pushes the changes, and opens or updates a GitHub PR linked to the issue. It does not merge the PR.
>
> **Architect:** Shares the PR link and discusses **Unclear or underspecified requirements** and **Suggested additions** here in the interactive session. Asks one focused question at a time and waits for the user's answers rather than ending with a PR comment.
>
> **User:** Discusses an ambiguity or a suggested addition, or indicates that no further discussion is needed.
>
> **Architect:** Continues the discussion, then records its outcome in a supplementary retrospective PR comment. Optional additions remain proposals unless separately requested.

Interactive discussion is the primary intent: Architect preserves the interactive nature of the session through the retrospective. A PR comment is a record of that conversation, not its replacement. In a non-interactive run, Architect instead posts the retrospective directly on the PR and summarizes it in the final output without waiting for unavailable input.

Material uncertainties must be clarified during the work, not left only for the final retrospective. If no ambiguities or useful additions were found, Architect says so explicitly rather than inventing discussion points.

The selection syntax and profile fields follow GitHub's [app customization guide](https://docs.github.com/en/copilot/how-tos/github-copilot-app/customize-github-copilot-app#using-custom-agents) and [custom-agent configuration reference](https://docs.github.com/en/copilot/reference/custom-agents-configuration). CLI invocation can also be checked with `copilot --help` and `copilot help commands`. Local smoke checks do not establish picker discovery or write permissions in every host; verify those in the intended session.
