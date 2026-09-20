# skills

Agent skills collected for reuse across projects. Each directory is a self-contained
skill: a `SKILL.md` file with frontmatter (`name`, `description`) and optional
`references/`, `scripts/`, `rules/` or `agents/` subdirectories.

This repository is a **copy**. The skills remain installed where OpenCode loads them
from, so nothing breaks if this repository is not used.

## Included skills

| Skill | Upstream source |
| --- | --- |
| `analytics-strategy` | [rampstackco/claude-skills](https://github.com/rampstackco/claude-skills) |
| `architecture-optimization` | [wondelai/skills](https://github.com/wondelai/skills) |
| `clean-architecture` | [wondelai/skills](https://github.com/wondelai/skills) (MIT) |
| `clean-code` | [jackjin1997/ClawForge](https://github.com/jackjin1997/ClawForge) |
| `database-design` | [vudovn/ag-kit](https://github.com/vudovn/ag-kit) |
| `observability-and-instrumentation` | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) |
| `performance-optimization` | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) |
| `react-component-performance` | [dimillian/skills](https://github.com/dimillian/skills) |
| `sql-optimization-patterns` | [wshobson/agents](https://github.com/wshobson/agents) |
| `vercel-composition-patterns` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) |
| `vercel-react-best-practices` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) |
| `web-design-guidelines` | [vercel](https://vercel.com) (via OpenCode) |

`clean-architecture` existed in two places (globally and inside the TJournal project)
with identical content; only one copy is kept here.

## Using these skills

OpenCode discovers skills from `.opencode/skills/` in a project and from configured
skill directories. To load a skill from this repository without copying it, add the
directory to the global OpenCode configuration:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "skills": ["~/Documents/Programming/opencode-tools/skills"],
}
```

Alternatively, copy the skill you need into your project's `.opencode/skills/` or
into `~/.config/opencode/skills/`.

The sources above keep their own licenses and attribution; check each upstream
repository before redistributing.
