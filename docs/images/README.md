# Native app captures

These images show the checked-in native SwiftUI apps in Spanish on an iPhone simulator and the actual PNG produced by the native share-card renderer. System share actions reflect the simulator's installed apps and language settings. All workout and diagnostic values come from isolated synthetic UI-test scenarios. They contain no hardware-session exports, operator notes, health records, real device identifiers or third-party FitShow screenshots. The product brand retains its [separate notice](../../shared/brand/NOTICE.md).

| Image | Native UI test | Attachment name |
| --- | --- | --- |
| [Home](app-home.png) | `VaganciaFitnessUITests.testCaptureProductScreensAcrossThePrimaryFlows` | `product-home` |
| [Workout](app-workout.png) | Same product test | `product-active-workout` |
| [History](app-history.png) | Same product test | `product-activity` |
| [Results](app-results.png) | Same product test | `product-workout-summary` |
| [Share sheet](app-share-sheet.png) | `VaganciaFitnessUITests.testStopKeepsSummaryUntilExplicitReturnAndImageOpensShareSheet` | `product-image-system-share-083` |
| [Exported image](app-share-card.png) | Same sharing test | Native renderer output from the simulator app's temporary `VaganciaFitnessShare/` directory; not an XCTest attachment |
| [Debug](app-debug.png) | `SessionFlowTests.testNativeLiquidGlassTabsKeepHistoricalMetricsAndMotorGates` | `liquid-glass-session` |

The results capture shows a program workout. The exported image and share sheet use a separate free-workout test session and therefore show different values. The exported image carries the native simulated-example label; it does not represent a physical workout or a HealthKit save.

Run `./apple/scripts/test ui-product` and `./apple/scripts/test ui-debug` with an installed supported simulator. The tests retain the named screenshot attachments in their `.xcresult` bundles under ignored `build/apple/Results/`. Export attachments with `xcrun xcresulttool export attachments --path RESULT_BUNDLE --output-path NEW_DIRECTORY`; its `manifest.json` maps test identifiers and attachment names to files. Keep the full run and attachment manifest private under `build/`.

Visually review the selected captures, then use the metadata-only [exporter](../../apple/scripts/export-documentation-screenshots.py) to refresh the fixed filenames:

```sh
./apple/scripts/export-documentation-screenshots.py build/product-attachments --kind product
./apple/scripts/export-documentation-screenshots.py build/product-attachments --kind sharing
./apple/scripts/export-documentation-screenshots.py build/debug-attachments --kind debug
```

For the exported card, use the PNG produced by the sharing test in the matching simulator app container. With that simulator booted, locate the container with `xcrun simctl get_app_container booted PRODUCT_BUNDLE_ID data`, using the product bundle identifier from the local generated project. Copy the matching `tmp/VaganciaFitnessShare/vagancia-sesion-*.png` into an ignored working directory. Match its filename to the image presented by the test's share sheet and visually confirm the simulated-example label. The filename identifies a synthetic test record. Keep the original filename, container paths and provenance private under `build/`.

```sh
./apple/scripts/export-documentation-screenshots.py build/reviewed-share-card.png --kind share-card
```

The helper requires the expected test identifiers and attachment names for screenshots, or an explicitly selected native PNG in `share-card` mode. It validates selected PNG chunks and paths before writing, and removes EXIF, XMP, text and timestamp metadata. It preserves pixel data and required color/transparency chunks byte for byte. Existing images at the seven fixed filenames are replaced deliberately; original inputs remain unchanged. This is metadata removal, not automatic visual anonymization, so review the pixels before invoking it.

Refresh captures when the represented native interface changes. Keep captions explicit about synthetic data, review pixels for identifiers and verify that each image matches its source flow. The HTML prototype is a design reference, not the source of these native screenshots.
