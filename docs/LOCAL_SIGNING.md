# Local signing without a paid Apple account

Repeated Keychain authorization prompts happen when each rebuild has a different ad-hoc code identity. A free, self-signed local code-signing certificate gives local builds a stable designated requirement, so macOS can recognize rebuilt versions as the same app.

## One-time setup

1. Open **Keychain Access**.
2. Choose **Keychain Access → Certificate Assistant → Create a Certificate**.
3. Use the name `nafi Local Development`.
4. Set **Identity Type** to **Self Signed Root**.
5. Set **Certificate Type** to **Code Signing**.
6. Enable **Let me override defaults**, continue, and accept the remaining defaults.
7. Build again with `./scripts/build-app.sh`.

The build script automatically uses that identity when it exists. A different identity can be selected with:

```bash
NAFI_CODESIGN_IDENTITY="My Local Code Signing" ./scripts/build-app.sh
```

The first launch after switching away from ad-hoc signing may ask once for existing Keychain entries. Choose **Always Allow**. Later rebuilds signed by the same identity should keep the same Keychain access identity.

## GitHub Actions

GitHub Actions keeps using ad-hoc signing when no identity is installed, so pull-request and release builds continue to work without an Apple Developer Program membership. A persistent self-signed identity can also be imported from encrypted repository secrets later, but its private key must never be committed to the repository.

Self-signed builds are for local/internal use. They are not notarized and Gatekeeper does not treat them as Developer ID releases.
