# Security

Atmosplorer is a read-only browser: it fetches public CAR archives and
decodes them locally; it holds no credentials or private data.

Still, if you find something — a crash on a malicious CAR, memory-safety
issue in the Zig core, or anything else that looks exploitable — please
report it privately rather than opening a public issue:

- Use **GitHub's Security Advisories** for this repo ("Report a
  vulnerability" on the repo's *Security* tab), or
- Email the maintainers at the address listed on the GitHub profile.

Please include:

- the affected version / commit
- the input that triggers it (CAR file or handle/DID)
- reproduction steps, if any

We'll acknowledge reports within a few days and keep you posted on fixes.
