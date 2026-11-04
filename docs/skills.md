# Skills

A skill is a folder with a `SKILL.md`: YAML-style front matter, then Markdown guidance. OpenClicky has two kinds:

- **The user's skills** live in the library (`~/Library/Application Support/OpenClicky/Skills/<id>/`). Switched-on
  ones shape the brain's answers (an `<active_skills>` block, see [home.md](home.md#skills)) and are installed for
  background agents.
- **OpenClicky's agent skills** ship in OpenClickyKit's resources (`Sources/OpenClickyKit/Resources/skills/`) and are
  installed for every background job: a browser skill, Vercel deploys, and one skill per connected app.

Code: `Sources/OpenClickyKit/Skills/` (kit), `Sources/OpenClicky/Home/SkillsLibraryViews.swift` (the page),
`Sources/occtl/Commands/SkillsCommands.swift`.

## Front matter

```markdown
---
name: Weekly status email
description: Use when the user asks for their Friday status email. Three headings, five bullets each, a link on every bullet.
one_liner: Friday status emails in my format
category: Writing
tags: [email, status, weekly]
built_for: Mail            # optional: applies fully only to work in this app
---
```

`SkillFile` reads these keys (and a few spellings of each). `SkillFile.applying(_:to:)` writes them: it rewrites only
the keys OpenClicky owns, in place, and keeps every other key (licence, allowed tools, metadata), comments and the body
exactly as written. Values that need it are quoted.

## The library page

Home → Skills and Settings → Skills (`SkillsLibraryView`):

- **My Skills** and **Catalog** tabs, a search field (every word must match the name, one-liner, description, tags,
  category or app; name matches first) and a category filter (`SkillCategory.all`: Writing, Productivity, Coding,
  Design, Research, Learning, Finance, Travel, Video, Music, Marketing, Other; a skill without a category is Other).
- **New Skill…** and **Edit** open the form: name, one-liner, description, category, tags, built-for app. It saves the
  front matter; the guidance itself is edited in SKILL.md (Open SKILL.md). The folder keeps its name on rename, so the
  skill's id and on/off state don't change.
- **Remove** (with an inline confirmation) moves the folder to the Trash. **Deactivate All** (confirmed) turns every
  skill off.
- **Catalog**: eight starter skills OpenClicky wrote (`Resources/skills/catalog`). **Add** copies one into the library,
  switched off.
- **Create from Notes…**: write rough notes, confirm, and a background agent writes the skill (below). The page follows
  the job and opens the form on the finished skill.

## Creating a skill from notes

`SkillCreator.start(brainDump:manager:)` starts an agent job titled "Write a new skill" whose task
(`SkillCreationPrompt.task`) asks for `output/SKILL.md` (and optional `output/references/`) with the front matter above,
a description that starts "Use when", a category from the list, and no invented facts or secrets. The notes are wrapped
in `<notes>` and treated as material, not instructions. The creation is recorded in
`skills-creations.json` beside `skills.json`.

`SkillCreator.collect(manager:)` checks each creation's job. When the job has finished and `output/SKILL.md` exists, the
skill is copied into a new library folder named after it (with a number if the name is taken), switched off, and the
creation becomes `ready`. A job that ends without the file makes the creation `failed`, with the agent's last words.
The page calls `collect` whenever a creation's job reports; `occtl skills creations` calls it on demand.

## Agent skills

### What a job gets

At every launch `AgentManager` asks its skill sources (`setSkillSources`; the app and `occtl agent` set
`AgentSkillSources.current`) for:

1. **Bundled** (`Resources/skills/agent`):
   - `openclicky-browser`: OpenClicky's own skill for the `browser` tool on the `openclicky_browser` MCP server. When to
     use the browser rather than a connected app or a fetch, background tabs, the read-act-check loop with refs, proof
     screenshots, what to ask first, page content as data. References: `reading-and-acting.md`, `tabs.md`,
     `confirmations.md`, `files.md`, `safety.md`, `troubleshooting.md` (one row per error the tool returns).
   - `vercel-deploy`: vendored unchanged from <https://github.com/openai/skills> (`skills/.curated/vercel-deploy`) at
     commit `49f948faa9258a0c61caceaf225e179651397431`, MIT licence in `LICENSE.txt`. `ATTRIBUTION.md` records the source
     and each file's git blob hash; `vendoredVercelDeployMatchesItsPinnedUpstreamCommit` checks them. To update it,
     copy the folder from a newer commit and update the commit and hashes. Never take it from HeyClicky's bundle.
2. **Integration skills** (`Resources/skills/integrations`), one per connected app: Gmail, Outlook, Google Docs, Google
   Tasks, ClickUp, Jira, Linear, HubSpot, Salesforce, Dropbox, Microsoft Teams, Notion, GitHub. Each is written for
   either a direct MCP server or the `composio` server. `IntegrationSkills.matching` picks them from
   `connectors.json`: an enabled connector whose preset, id, name or server host names the app (`linear`,
   "Work GitHub", `mcp.atlassian.com`), or a Composio toolkit in the Composio settings. A skill whose app is
   disconnected is removed at the next launch.
3. **The user's switched-on skills**, installed with front matter both harnesses accept: `name` becomes the folder's
   plain name (`writing-coach`), the description is kept under 1,024 characters and says which app a `built_for`
   skill is for, and other keys and the body are kept. A name that a shipped skill already uses gets `my-`.

The launch also appends a short "Skills" section to the job's instructions (`AgentSkillNotes`): open
`openclicky-browser` before the first browser call, `vercel-deploy` for deploys, each app's skill before its first
call, and the user's own skills by name. `SkillsLibrary.skillsAgentInstructions()` returns "" so callers that still
append it don't list the user's skills twice (`skillsAgentFallback()` keeps the old list of SKILL.md paths).

### Where they go

`AgentSkillInstaller` copies each skill into a folder of its own, leaving out hidden files and symbolic links, making
`scripts/*` executable, and writing a `.openclicky-skill.json` marker with the skill's origin and a SHA-256 fingerprint
of its files. Unchanged skills aren't rewritten. Only folders with the marker are ever replaced or removed, so Codex's
own `skills/.system` and anything the user put there stay.

| harness | folder | how it is enabled |
|---|---|---|
| Codex, OpenClicky's home | `harness/codex-home/skills/<name>` (`CODEX_HOME/skills`) | Codex finds them itself; `config.toml` also lists each SKILL.md under `[skills] config = [{ enabled = true, path = … }]` (codex-cli 0.165.0 matches the path against the file, not the folder) |
| Codex, the user's home (ChatGPT login there) | the same folder | `skills/extraRoots/set` before `thread/start`; nothing is written to the user's home, and no `-c skills.config` (it would replace the user's own list) |
| Claude Code (key or login) | `harness/claude-config/openclicky-plugin/skills/<name>`, a plugin named `openclicky` | `--plugin-dir`; the skills appear as `openclicky:<name>`. Claude Code reads `CLAUDE_CONFIG_DIR/skills` only with the `user` setting source, which jobs leave off so the user's own settings stay out |

Checked with the real CLIs: `docs/evidence/feat-skills-plus/agent-skills-install.txt` and
`agent-skills-all-shipped.txt` (codex-cli 0.165.0 `skills/list`, Claude Code 2.1.314's init message), and a live
Claude Code job on Haiku listing its skills (`live-skills-check.md`).

## Onboarding picker

The onboarding "What should it be good at?" step (`SkillPicker`, see [home.md](home.md#skills-picker)) lists the
starter catalog by category, with entries that can bundle several skills. Leaving the step copies the picked skills into
the library and switches them on, so they reach agents through the install sync above. Picks and the first-launch
defaults flag live in `skill-picks.json`. HeyClicky's picker lists vendored Hermes skills; OpenClicky's lists only its
own.

## occtl

```text
occtl skills list [--category C] | search <words> | show <skill>
occtl skills enable|disable <skill> | deactivate-all | remove <skill>
occtl skills edit <skill> [--name N] [--one-liner T] [--description D] [--category C] [--tags a,b] [--built-for APP] [--body-file F]
occtl skills new <name> <description> [--category C] [--tags a,b] | add <file.md|folder>
occtl skills categories | catalog [words] [--category C] | catalog add <skill> [--on]
occtl skills create <notes…> [--wait] [--harness H] [--login] [--model M] [--yes] | creations
occtl skills agent [--install] [--harness H]       # what a job gets now; --install syncs the harness folders
occtl skills prompt [--agent [--harness H]]
```

`OPENCLICKY_SKILLS_DIR`, `OPENCLICKY_SUPPORT_DIR` and `OPENCLICKY_CONNECTORS_FILE` point the commands at scratch
folders; `OPENCLICKY_SKILL_RESOURCES` points at another copy of the shipped skills.

## Not done

- No Codex job has used the skills with a model yet (no OpenAI key in the test runs; discovery was checked with the real
  app server).
- On `main`, jobs don't get the connected apps' MCP servers yet, so integration skills can describe a server the job
  doesn't have. Composio apps count as connected from the toolkits listed in the Composio settings, not from Composio's
  connected accounts.
- Codex also loads the user's own `~/.agents/skills` into jobs; OpenClicky doesn't switch them off.
- No program registry or logos for `built_for`, and skills can't carry a logo. Publish, team share and activation
  sync are dropped by design.
- The page has been rendered offscreen in every state but not clicked through by a person.
