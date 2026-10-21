# FitShow reference policy

FitShow screenshots are private working references. No screenshots, redacted copies, screenshot manifests or mask policies are distributed with this source tree. Only this policy document is public. Originals and redacted reference copies remain under ignored `.local/references/` on the maintainer's machine; private manifests retain their checksums.

Opaque masks remove personal information, but do not grant distribution rights for another app's interface. The maintainer has chosen to keep these assets private. FitShow names and protocol discussion in engineering documentation do not imply endorsement or ownership of its artwork. These references are not hardware verification evidence.

The interactive prototype under `design/prototype/` does not load the private images. A fresh checkout can build, run checks and use the prototype without any private reference data.

For local reference work only, supply neutral input names `reference-01.png` through `reference-10.png` and an explicitly supplied local mask policy:

```sh
scripts/redact-references INPUT NEW_OUTPUT --policy PRIVATE_POLICY.json
```

The tool requires Python and Pillow, refuses to overwrite existing output images, and writes within ignored `.local/` or outside the repository. It does not ship a private mask policy. Do not regenerate existing references merely to prepare a source release.

The public inventory and generated `.gitignore` exclude reference assets and local evidence. `scripts/check-public-files` rejects reference assets placed alongside this README and checks that Git exclusions match the distribution policy. Keep public product captures synthetic or independently approved for distribution.
