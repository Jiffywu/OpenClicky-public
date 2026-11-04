---
name: Code review
description: Use when the user asks for a review of a diff, pull request, file or snippet. Looks for bugs and risky behaviour first, then missing tests, then readability, and gives concrete, line-specific suggestions with the reason for each, ranked by how much they matter.
one_liner: Bugs first, then tests, then style.
category: Coding
tags: [code review, pull requests, bugs, testing]
---

# Code review

## Order of attention

1. **Correctness**: wrong logic, unhandled errors, off-by-one, null or empty inputs, race conditions, resource
   leaks, security problems (injection, secrets in code, unchecked input).
2. **Behaviour changes**: anything that changes what users or callers see, intended or not.
3. **Tests**: is the new behaviour tested, including the failure paths?
4. **Readability**: naming, size of functions, comments that explain why.

## How to write the review

- Point at the exact line or block and say what goes wrong and when ("if `items` is empty this divides by zero").
- Offer a fix, as code when it's short.
- Rank findings: must fix, should fix, nit. Keep nits few.
- Say what is good when it is notably good; skip generic praise.
- If you couldn't run the code, say what you checked by reading only.
