# ``Beacon``

A lightweight analytics routing layer for Swift apps. One `track()` call reaches every provider you've configured — with offline queuing, retries, and consent gating handled automatically.

## Overview

Create an ``AnalyticsClient`` with your providers, set the user's consent, and start tracking:

```swift
let analytics = AnalyticsClient(providers: [FirebaseProvider(), HTTPBatchProvider(endpoint: url)])
analytics.setConsent(granted: [.analytics])
analytics.track("signup_completed", properties: ["method": "apple"])
```

## Topics

### Essentials

- ``AnalyticsClient``
- ``AnalyticsEvent``
- ``AnalyticsValue``

### Providers

- ``AnalyticsProvider``
- ``HTTPBatchProvider``
- ``ConsoleProvider``
- ``BatchRejectedError``

### Consent

- ``ConsentCategory``
- ``ConsentState``
- ``ConsentStorage``
- ``UserDefaultsConsentStorage``
- ``InMemoryConsentStorage``

### Processing

- ``EventProcessor``
- ``PropertyEnricher``
- ``PIIRedactor``
- ``EventFilter``
- ``ClosureProcessor``

### Persistence

- ``EventStore``
- ``FileEventStore``
- ``InMemoryEventStore``
