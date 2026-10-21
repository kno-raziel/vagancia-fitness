# Brand source and mirrors

`fitness-mark-v8.svg` and `fitness-wordmark.svg` are the current vector sources used by the Apple product. The copies in Apple asset catalogs must match these files; `scripts/check-contracts` checks them. They remain assets, not executable platform code.

The asset composition manifest is at `apple/Apps/VaganciaFitness/Resources/Brand/manifest-v8.json`. Its source paths describe artwork in the earlier branding workspace, not files promised in this repository. It records geometry transformations and hashes, but does not establish redistribution rights. The app icon is a generated raster asset; its source generator remains under `apple/scripts/`.

The maintainer authorizes inclusion and distribution of the current brand assets with this project and reserves trademark rights. See the [brand notice](NOTICE.md). This statement does not authorize third-party FitShow screenshot distribution or imply independent verification of historical artwork inputs. See [third-party notices](../../THIRD_PARTY_NOTICES.md).

The bundled Asimovian, Inter and Lekton fonts have a separate [provenance manifest](../../apple/Apps/VaganciaFitness/Resources/Brand/font-manifest.json). It pins Fontsource package releases, archive integrity, original WOFF hashes and converted TTF hashes. The offline [regeneration script](../../apple/scripts/regenerate-fonts.py) reproduces those TTF bytes from explicitly supplied package contents. Font licenses and the input-directory convention are described in [third-party notices](../../THIRD_PARTY_NOTICES.md#fonts).
