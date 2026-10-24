# Deferred ideas

This is the canonical backlog of deferred or rejected FingVibe ideas. Keep the decision, its reasons, and the conditions for reconsideration here so future discussions do not repeat the same investigation.

## Usage and maintenance

- Consult relevant entries before proposing or investigating an idea again. Surface the prior blocker and check whether its reconsideration conditions have changed.
- Record only user-confirmed decisions, not tentative suggestions. Summarize the conclusion rather than copying a conversation; link evidence and discussions where available and distinguish facts from assumptions.
- Use **deferred** for an idea that may become viable after a stated change, and **rejected** for an idea not being pursued under current requirements. Neither status is a permanent ban.
- Revisit an entry only when a recorded condition changes or the user explicitly chooses to reconsider. State what changed before repeating an investigation.
- Update the existing entry for the same idea instead of adding a duplicate. Preserve its identifier and earlier rationale in dated decision-history notes. If a later decision replaces it, mark the old decision **superseded** and link the replacement decision or implementation task.
- Assign the next unused `DI-NNN` identifier and use ISO dates (`YYYY-MM-DD`). Do not renumber existing entries.
- State "None known" for unknown reconsideration conditions, and "None" or "Not discussed" for missing references or alternatives as appropriate. Do not invent evidence or alternatives.

Architect should offer to add or update an entry when an idea is abandoned, summarizing the proposed rationale and reconsideration conditions. Wait for explicit user confirmation to record that specific decision.

That confirmation authorizes the recording workflow: create a simple GitHub task (or reuse an applicable existing one) describing the approved entry and acceptance criteria, then proceed directly to a documentation PR without asking for a second implementation approval. Follow the conflict assessment, any required conflict-risk confirmation, Active-label lifecycle, publication verification, and retrospective steps in the [Architect workflow](../.github/agents/architect.agent.md).

This exception covers only recording the confirmed decision. It does not authorize application code changes, implementing the abandoned idea, or recording other ideas. Normal feature implementation still requires separate explicit approval.

## Entry template

Copy this template into the entries section only for an approved decision.

```markdown
### DI-NNN: Descriptive idea title

- **Status:** Deferred / Rejected
- **Decision date:** YYYY-MM-DD
- **Idea and intended benefit:** What was proposed and why it was appealing.
- **Reason for stopping:** Concrete blockers, constraints, or tradeoffs. Identify evidence and assumptions.
- **Alternatives considered:** What was explored and why it did not resolve the blocker, or "Not discussed".
- **References:** Relevant issue, PR, discussion, or evidence links, or "None".
- **Revisit only if:** Specific changes that justify reopening the discussion, or "None known".
- **Decision history:** Dated changes and links to superseding decisions, or "Initial decision".
```

## Entries

No decisions recorded yet.
