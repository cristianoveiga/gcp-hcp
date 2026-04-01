.PHONY: sync-gemini-skills

# Copy shared skills from Claude plugin to Gemini extension
sync-gemini-skills:
	cp claude-plugin/gcp-hcp/skills/gcp-hcp-architecture/SKILL.md \
	   gemini-extension/skills/gcp-hcp-architecture/SKILL.md
