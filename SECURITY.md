# Security

## Reporting a vulnerability

Please report privately through
[GitHub's advisory form](https://github.com/mrskiro/sill/security/advisories/new)
rather than opening a public issue. Include what you did, what happened, and the
versions of Sill and macOS or iOS involved.

Only the latest release is supported.

## What is interesting

Sill has no account and no server, so the surface is small and specific:

- **Pairing.** A one-time token is offered for a short window — as a QR code for an
  iPhone, as a copyable code between two Macs. Both sides then remember each other by
  certificate fingerprint.
- **Transport.** Devices talk over mutual TLS with pinned self-signed certificates on
  the local network. Anything that lets an unpaired device complete a session, or that
  weakens the pinning, is worth reporting.
- **Device identity.** The certificate and its private key live in the keychain.
- **Notes at rest.** A single SQLite file inside the app's sandbox container.

## When you send us logs

`Application Support/Sill/sync.log` is the useful log, but it names your devices and
records the first characters of pairing codes. Read it before attaching it, and send
it through the private advisory rather than a public issue.
