# Security policy

## Reporting a vulnerability

Report vulnerabilities privately to [support@lorislab.fr](mailto:support@lorislab.fr).
Do not open a public issue for a vulnerability and do not attach access tokens,
private keys, transcripts, research-vault contents or other personal data.

Include only the information needed to reproduce the issue:

- affected Throttle version and platform;
- affected component, such as the macOS app, companion, Vault helper or Edge;
- reproduction steps using synthetic data when possible;
- observed impact and any suggested mitigation.

LorisLabs will acknowledge the report, establish a private coordination channel
and communicate the remediation status. A public disclosure date is agreed with
the reporter after affected users have a practical mitigation or update.

## Scope and safe testing

Security reports may cover code distributed from this repository and the
official Throttle release channel. Test only systems and accounts you own or
have explicit permission to test. Do not access another person's sessions,
CloudKit data, devices, credentials or self-hosted Edge service. Do not degrade
the public service or send secrets as proof.

The current source tree and a published binary have separate evidence. Include
the exact commit or downloaded artifact SHA-256 when that distinction matters.

## Release and support boundary

Security fixes are qualified through the repository's test, signing and release
gates. A local patch or green test does not mean a signed update is available.
The current published release is the supported distribution; development
branches and unnotarized local builds are pre-release evidence.

This policy does not define a bug bounty and does not change the licence or the
public/proprietary classification of any repository path.
