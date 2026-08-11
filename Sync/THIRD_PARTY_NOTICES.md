# Third-party notices

TokenBar Sync is distributed under the repository-root MIT license. The complete license catalog for the locked Windows Sync and Helper dependency graph is generated at [`ThirdPartyLicenses.html`](ThirdPartyLicenses.html) with:

```sh
cargo about generate --manifest-path Sync/Cargo.toml --config Sync/about.toml --locked --fail --output-file Sync/ThirdPartyLicenses.html Helper/about.hbs
```

The Windows build and installer and the Linux packaging script include the repository license and this generated catalog in their release artifacts.
