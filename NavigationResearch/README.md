# Navigation core experiment

Keep main and the existing MapKit UI unchanged. Upstream: https://github.com/maplibre/maplibre-navigation-ios . Inspected Package.swift and MapboxCoreNavigation/RouteController.swift on upstream main. Core is a separate target but not a published library product. RouteController requires MapboxDirections.Route and Directions; MKRoute cannot be passed directly. Do not fabricate lane, junction, maneuver or road-level data missing from MapKit. Verify upstream license before copying sources (LICENSE lookup returned 404).

## Gates
1. Pin upstream revision and expose core-only library in a fork; compile on iOS 17+ without MapLibre rendering.
2. Validate route-model conversion using actual MKRoute steps and geometry; if required data is unavailable, reject conversion or evaluate a compatible routing provider. Never silently invent data.
3. Use one location manager during navigation, and one camera owner; replay recorded GPS traces before real driving. Test course validity, low-speed heading, parallel roads, reroutes, arrival, camera stability, and cleanup.
4. Keep experimental navigation disabled until tests pass. Apple map display remains unchanged. No paid service or VPS by default. Bridge level switching is not guaranteed by either engine.

Status: source review only; no SDK integration or build verification yet.
