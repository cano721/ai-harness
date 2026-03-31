# Security Policy

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| 1.x     | :white_check_mark: |

## Reporting a Vulnerability

AI Harness is a security-focused framework for AI agents. We take security issues seriously.

### How to Report

**Do NOT open a public issue for security vulnerabilities.**

Instead, please report security vulnerabilities by emailing:

- **Email**: [Create a private security advisory](https://github.com/cano721/ai-harness/security/advisories/new)

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 1 week
- **Fix release**: Depends on severity

### Scope

The following are in scope:

- Hook bypass vulnerabilities (e.g., circumventing `block-dangerous.sh`)
- Secret leakage through audit logs
- Arbitrary code execution via hook scripts
- Configuration injection attacks

### Out of Scope

- Vulnerabilities in Claude Code itself (report to Anthropic)
- Social engineering attacks
- Issues requiring physical access to the machine

## Security Best Practices

When using AI Harness:

1. **Never commit** `.ai-harness/logs/` to version control
2. **Review** hook configurations before applying to production
3. **Keep** Node.js and Claude Code updated
4. **Use** the `secret-scanner` hook in all projects
