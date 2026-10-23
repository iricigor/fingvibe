# Contributing

## Parallel feature work

Keep changes within the owning module whenever possible. Coordinate changes to shared models and contracts before editing them, and keep pull requests focused on one feature or structural refactor.

Current ownership boundaries:

- `MainWindow.xaml.cs` owns shell initialization, page routing, navigation, and top-level wiring.
- `MainWindow.Scan.cs` owns scan start, cancellation, progress, and completion status.
- `MainWindow.Results.cs` owns result collection, filtering, sorting, comparer state, and result summaries.
- `MainWindow.NetworkIdentity.cs` owns local network selection and public/local network identity display.
- `MainWindow.Snapshots.cs` owns snapshot restoration, persistence status, and saved-scan state.
- `MainWindow.DeviceDetails.cs` owns the selected-device details view.
- `LanScannerService` owns scan orchestration and probe lifecycle. `IScanResultEnricher` and `ScanResultEnricher` own device name, vendor, MAC, and port enrichment.

Keep page-specific layout and state with the page when adding or substantially changing a page. Limit shell changes to route registration and top-level wiring. Add regression tests alongside the module whose behavior they cover, and avoid unrelated formatting or cleanup in parallel pull requests.
