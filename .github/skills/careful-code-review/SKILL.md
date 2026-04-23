---
name: careful-code-review
description: "Use when: reviewing code, implementing features, refactoring, or debugging. Structured workflow to reduce mistakes through explicit assumptions, minimal changes, and verified success criteria."
---

# Careful Code Review & Implementation

A structured workflow to reduce common coding mistakes through deliberate thinking, simplicity-first constraints, surgical edits, and goal-driven verification.

## When to Use This Skill

- **Code review or refactoring** — Before making edits, think about tradeoffs
- **Feature implementation** — Avoid scope creep and overcomplication
- **Debugging** — Define reproducible test cases first
- **Multi-step tasks** — Track progress and verify at each checkpoint
- **Uncertain requirements** — Surface assumptions and ask instead of guessing

## Workflow

### Step 1: Think Before Coding

**Goal**: Avoid assumptions, surface ambiguities, and identify simpler approaches

**Actions**:
- State your assumptions explicitly
- If uncertain about interpretation, present options instead of picking silently
- Ask clarifying questions if scope is unclear
- Suggest simpler approaches if applicable
- Name what's confusing before implementing

**Completion Check**:
- All ambiguities surfaced ✓
- User confirmed interpretation (if needed) ✓
- Assumptions stated in writing ✓

### Step 2: Simplicity First

**Goal**: Deliver minimum code that solves the problem; reject speculation

**Constraints**:
- No features beyond what was asked
- No abstractions for single-use code
- No "flexibility" or "configurability" that wasn't requested
- No error handling for impossible scenarios
- Rewrite if it's 200 lines and could be 50

**Self-Check**: "Would a senior engineer say this is overcomplicated?" → If yes, simplify before committing.

**Completion Check**:
- Each line of code traces directly to user's request ✓
- No speculative generality added ✓
- Simpler approach rejected only if justified ✓

### Step 3: Surgical Changes

**Goal**: Edit only what's necessary; preserve existing style and code

**Guidelines for Existing Code**:
- Don't "improve" adjacent code, comments, or formatting
- Don't refactor things that aren't broken
- Match existing style, even if different from your preference
- Mention unrelated dead code instead of deleting it

**Guidelines for Cleanup**:
- Remove imports/variables/functions that *your changes* made unused
- Don't remove pre-existing dead code (unless explicitly asked)

**Completion Check**:
- Every changed line traces to the user's request ✓
- Unrelated code untouched ✓
- Style matches existing codebase ✓
- No unintended orphans created ✓

### Step 4: Goal-Driven Execution

**Goal**: Define verifiable success criteria and loop until confirmed

**Transform Vague Requests into Goals**:
- "Add validation" → Write tests for invalid inputs, then make them pass
- "Fix the bug" → Write a test that reproduces it, then make it pass
- "Refactor X" → Ensure tests pass before and after

**Plan For Multi-Step Tasks**:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

**Completion Check**:
- Clear success criteria defined ✓
- Each step has a verification checkpoint ✓
- Final state verified against criteria ✓

## Example Prompts

1. **"Review this code for security issues"** + this skill
   - Clarify scope (all files? specific module?)
   - State assumptions (e.g., API-only, no DB queries assumed)
   - Present findings in priority order
   - Suggest minimal fixes, not full rewrites
   - Verify each fix independently

2. **"Add a feature X to this module"** + this skill
   - Ask: Does it need a new function, or extend existing?
   - Define scope: What's included? What's out of scope?
   - Implement minimum code
   - Verify no unrelated changes introduced
   - Test edge cases if applicable

3. **"The deploy script sometimes fails"** + this skill
   - Clarify: When does it fail? Reproducible?
   - Define: What should "success" look like?
   - Fix the root cause, not symptoms
   - Test on reproduced failure case
   - Verify it passes before/after

## Quality Signals

**This workflow is working if you observe**:
- Fewer unnecessary changes in diffs
- Fewer rewrites due to overcomplication
- Clarifying questions come *before* implementation rather than after mistakes
- Each PR or change has clear justification
- Less back-and-forth with reviewers

## Anti-Patterns to Avoid

- ❌ "I'll refactor this too" (if not asked) → Stay surgical
- ❌ "This should support X use case later" → No speculation
- ❌ "I added error handling for edge case Y" → Implement only what's asked
- ❌ Changing code style/formatting in unrelated lines → Preserve existing style
- ❌ Vague success criteria ("make it work") → Define measurable checks

## Integration with Your Workflow

This skill is workspace-scoped and applies to:
- Code reviews of the Gentoo installation scripts
- Feature additions or hardening improvements
- Refactoring for clarity or maintainability
- Debugging installation failures

When reviewing your shell scripts, use Step 1-4 to:
1. Clarify scope (all scripts? specific phase?)
2. Audit for security/reliability (Step 2: simplicity check)
3. Make minimal fixes only (Step 3: surgical edits)
4. Verify each fix independently (Step 4: test beforehand)
