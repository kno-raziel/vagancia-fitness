# Third-party notices and provenance

## Fonts

The app bundles Asimovian, Inter, and Lekton font files under `apple/Apps/VaganciaFitness/Resources/Fonts/`. Each family is accompanied by its SIL Open Font License 1.1 text in that directory. The family copyright and source notices are in the corresponding license files.

The checked-in [font manifest](apple/Apps/VaganciaFitness/Resources/Brand/font-manifest.json) records the source paths, WOFF and TTF SHA-256 hashes, embedded OpenType version names, conversion method, OFL hashes and published package metadata for each bundled weight. All five inputs match the published `5.3.0` archives of [`@fontsource/asimovian`](https://registry.npmjs.org/@fontsource/asimovian/5.3.0), [`@fontsource/inter`](https://registry.npmjs.org/@fontsource/inter/5.3.0) and [`@fontsource/lekton`](https://registry.npmjs.org/@fontsource/lekton/5.3.0). The manifest pins each archive URL and npm SHA-512 integrity value. The retained OFL texts also match those packages. Embedded font versions identify Asimovian 3.000, Inter 4.001 (`git-66647c0bb`) and Lekton 34.000; these font versions are distinct from the Fontsource package release.

[Font regeneration](apple/scripts/regenerate-fonts.py) uses only Python's standard library and runs offline. Supply the published package contents beneath a directory containing `@fontsource/<family>/package.json`, `LICENSE` and `files/`. For example, from the repository root:

```sh
./apple/scripts/regenerate-fonts.py --source-root ./.local/font-inputs --output-dir ./build/regenerated-fonts
```

The script verifies package names and versions, every original WOFF hash, each OFL and every resulting TTF hash before writing output. It decompresses WOFF 1 sfnt tables, preserves outlines, names and timestamps, and recalculates the font checksum. Omitting `--output-dir` restores the bundled TTF files after the same complete validation. Inputs stay caller supplied; regeneration does not download packages or install tools. `scripts/check-contracts` verifies bundled output hashes and retained OFL notices; the resource-tool tests also exercise conversion with synthetic WOFF bytes.

## Brand and other assets

The app bundles brand SVGs and an app icon. The maintainer authorizes inclusion and distribution of the v8 logo, wordmark and icon with this project and reserves trademark rights. This is a maintainer-provided rights statement, not independent verification of the historical artwork chain. The asset manifest records the composition and hashes of its earlier inputs. See the [brand notice](shared/brand/NOTICE.md); inclusion in source or a build does not grant trademark rights.

FitShow screenshots, including redacted copies and their manifests/mask policies, are private working references under ignored `.local/references/`. They are not included in the public source distribution or the MIT grant. Only the [reference policy](docs/references/fitshow/README.md) is public. Redaction does not grant distribution rights, and no permission to redistribute FitShow artwork is asserted.

The FitShow documentation identifies QZ Fitness as a protocol reference. A reference does not establish source-code reuse or determine this project's license. Any future source reuse must be separately reviewed and attributed.

## Project code

The project code and original engineering documentation use the [MIT License](LICENSE). Third-party font licenses remain separate. The MIT license does not grant trademark rights or rights to third-party screenshots. The current v8 mark, wordmark and icon are authorized for inclusion in source and builds under the maintainer's recorded permission, with trademark rights reserved; fonts retain OFL and private FitShow references remain excluded.
