# Security Policy

## Supported Versions

Security fixes are applied to the latest release.

| Version | Supported |
| ------- | --------- |
| latest  | Yes       |
| < latest| No        |

## Reporting a Vulnerability

Please **do not open a public issue** for security vulnerabilities. Instead,
report them privately by emailing the maintainer, or open a
[private security advisory](https://github.com/cg689/SkillBridge/security/advisories/new)
on GitHub.

Please include:

- The affected script and line if known.
- A minimal reproduction.
- The impact you believe it has.

You should receive a response within 5 business days. If the issue is
confirmed, a fix will be released as soon as possible, and you will be credited
(if you wish).

## Scope

SkillBridge reads a CC Switch skills directory and creates links in configured
tool directories. Security-sensitive concerns include:

- **Path traversal / injection**: config values are treated as filesystem paths;
  do not run a `config.json` from an untrusted source.
- **Skills executed by agents**: SkillBridge only links skill folders; it does
  not execute them. Still, only sync skill libraries you trust — the agents that
  load them may execute their instructions.
