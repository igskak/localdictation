# Closed-beta activation configuration

The Windows client now has the complete activation path, but ordinary local and
CI builds deliberately carry neither an authority nor an endpoint. A distributed
beta build receives two non-secret, fixed values at build time:

- `WitnessBetaLicensePublicKey`: the Base64 Ed25519 public key for the isolated
  Windows beta authority;
- `WitnessBetaActivationEndpoint`: an exact HTTPS URL ending in `/v1/activate`,
  without user info, query or fragment.

They are embedded as assembly metadata. There is no settings field, environment
read or command-line switch in the installed app, so a user cannot redirect the
email address. The signing private key is never a build input and must exist
only in the isolated beta service's secret store and an approved offline backup.

## Infrastructure boundary

Before setting the build values:

1. Provision a separate beta service and database from Mac production. Do not
   point a Windows beta at `api.witnessmac.com`.
2. Create a new Ed25519 identity outside this repository. Put only the public
   half in the build secret; put the private half only in the beta service's
   secret store. Do not use the committed parity fixture seed.
3. Disable server-side production analytics for the beta. Windows client events
   remain local-only.
4. Configure transactional beta mail, rate limits and deletion/retention, then
   complete `LEGAL/WINDOWS_BETA_PRIVACY.md` with the actual host, processor,
   region, retention and controller contact.
5. Verify the beta health endpoint reports that its signing key matches the
   public authority. Issue a synthetic trial key and verify it in the packaged
   app on the same derived device ID before inviting a tester.

The server keeps the existing wire contract: activation sends exactly `device`
and `email`; release sends exactly `device` and `key`. No Windows-specific field
is added.

## GitHub packaging

Create repository or protected-environment secrets:

```text
WINDOWS_BETA_LICENSE_PUBLIC_KEY
WINDOWS_BETA_ACTIVATION_ENDPOINT
```

Run **Windows unsigned internal package** with `configure_activation: true`.
The job fails before compilation when either value is absent, and MSBuild also
enforces the required configuration. With `configure_activation: false`, the
same workflow creates a local-only build whose screen explains that a manual
key cannot verify without an authority.

This does not make the artifact externally distributable. Windows code signing,
SmartScreen evidence, approved legal text and the W8 tester kit remain separate
gates.

## Local verification build

Use explicit MSBuild properties only for a controlled verification build:

```powershell
dotnet publish Windows/src/Witness.App/Witness.App.csproj `
  --configuration Release `
  -p:PublishProfile=Beta `
  -p:WitnessRequireBetaActivation=true `
  -p:WitnessBetaLicensePublicKey="$env:WINDOWS_BETA_LICENSE_PUBLIC_KEY" `
  -p:WitnessBetaActivationEndpoint="$env:WINDOWS_BETA_ACTIVATION_ENDPOINT"
```

Do not place either value in a runtime settings file. Although the two values
are public by nature, keeping them out of ordinary builds prevents accidental
contact with beta infrastructure and keeps CI deterministic.
