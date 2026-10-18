## Description
Provide a concise explanation of what this pull request changes or adds.

## Type of Change
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that alters existing protocol or behavior)
- [ ] Performance improvement / Code hygiene
- [ ] Documentation update

## Verification & Testing
Describe the tests you ran to verify your changes:
- [ ] `swift test` passed cleanly
- [ ] `./scripts/e2e-test.sh` passed cleanly
- [ ] Offline self-test verified: `.build/debug/RemoteDesk --self-test`
- [ ] Real-capture tested between two Macs (if applicable)

## Checklist
- [ ] My code adheres to the zero-external-dependency requirement (pure native macOS frameworks).
- [ ] I have verified that no secrets, personal file paths (`/Users/<username>`), or credentials are committed.
- [ ] My code introduces no new compiler warnings (`swift build -c release`).
- [ ] I have updated `CHANGELOG.md` under `[Unreleased]` with relevant changes.
- [ ] Documentation (`README.md`, `docs/ARCHITECTURE.md`) has been updated if applicable.
