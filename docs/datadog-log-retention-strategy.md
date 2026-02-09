# Datadog Long-Term Log Retention Strategy (90+ Days)

## 1. Problem Statement

The BrezyWeather application currently has no centralized logging, no observability
platform, and no log retention policy. Logs are ephemeral -- they vanish when Azure
App Service instances recycle. This document defines the strategy for integrating
Datadog as the logging platform with a **minimum 90-day retention** for all
application logs.

---

## 2. Retention Tier Architecture

Datadog offers two built-in retention mechanisms plus a third archival layer we
control. The strategy uses **all three tiers** together:

```
Tier 1: Datadog Online Indexes     (hot)    -- 90 days, searchable in Log Explorer
Tier 2: Datadog Online Archives    (warm)   -- 90 days, rehydratable on demand
Tier 3: Azure Blob Storage Archive (cold)   -- 365 days, cheapest long-term store
```

### Tier 1 -- Datadog Log Indexes (90-Day Searchable Retention)

| Setting            | Value                                     |
|--------------------|-------------------------------------------|
| Index name         | `brezyweather-production`                 |
| Retention          | **90 days**                               |
| Filter query       | `service:brezyweather env:production`     |
| Daily quota        | Configurable per cost budget              |
| Exclusion filters  | Health-check endpoints, static assets     |

Datadog index retention is configured in **Datadog UI > Logs > Configuration >
Indexes**. The retention period on each index is set to 90 days. This is the
*minimum* the strategy targets -- all logs remain fully searchable in Log Explorer
for the entire 90-day window.

**Key configuration steps in Datadog:**
1. Navigate to Logs > Configuration > Indexes.
2. Create index `brezyweather-production` with filter `service:brezyweather env:production`.
3. Set retention to **90 days**.
4. Add exclusion filters to drop noise (health probes, `/favicon.ico`, etc.).

### Tier 2 -- Datadog Online Archives (Rehydration)

Online Archives keep logs beyond the index retention period in a compressed,
queryable-on-demand format within Datadog itself.

| Setting            | Value                                     |
|--------------------|-------------------------------------------|
| Enabled            | Yes                                       |
| Linked index       | `brezyweather-production`                 |
| Rehydration window | Up to 90 additional days                  |

This means logs up to **180 days old** can be rehydrated back into a temporary
index for investigation without ever touching cold storage.

### Tier 3 -- Azure Blob Storage Archive (365 Days)

For compliance and cost efficiency, all logs are simultaneously archived to Azure
Blob Storage in a dedicated container. This is the cheapest long-term store and
serves as the system of record.

| Setting                 | Value                                        |
|-------------------------|----------------------------------------------|
| Archive destination     | Azure Blob Storage                           |
| Storage account         | `brezyweatherlogsarchive`                    |
| Container               | `datadog-log-archives`                       |
| Path prefix             | `/dt=YYYYMMDD/hour=HH/`                     |
| Archive format          | JSON (gzipped)                               |
| Lifecycle policy        | Move to Cool after 30 days, Archive after 90 |
| Deletion policy         | Delete after **365 days**                    |
| Rehydration from Datadog| Yes, via Log Rehydration feature             |

**Datadog archive configuration:**
1. Navigate to Logs > Configuration > Archives.
2. Add Azure Blob Storage archive.
3. Set integration via Azure tenant registration or SAS token.
4. Set query filter: `*` (archive everything).
5. Enable "Include All" to capture all log attributes.

**Azure Blob lifecycle rules (IaC defined below):**
- Base tier: Hot (0-30 days)
- Transition to Cool: 30 days
- Transition to Archive: 90 days
- Delete: 365 days

---

## 3. Log Pipeline Design

```
Application (.NET 6)
  |
  |-- Serilog (structured JSON logging)
  |     |
  |     |-- Console Sink (stdout)
  |     |-- Datadog Sink (direct API ingestion)
  |
  v
Datadog Intake API
  |
  |-- Processing Pipeline (parsing, enrichment, geoIP)
  |-- Index: brezyweather-production (90-day retention)
  |-- Archive: Azure Blob Storage (365-day lifecycle)
```

### Why Serilog + Datadog Sink (not the Datadog Agent)?

Since this app runs on **Azure App Service** (PaaS, not containers), installing
a Datadog Agent sidecar is not straightforward. The recommended approach for
App Service is:

1. **Serilog with Datadog Sink** -- sends logs directly to the Datadog Logs
   API (`https://http-intake.logs.datadoghq.com`).
2. Alternatively, Serilog writes JSON to stdout and Azure App Service Diagnostic
   Logs forward to an Azure Event Hub, which Datadog's Azure integration
   consumes. This strategy uses the **direct sink** for simplicity.

---

## 4. Log Enrichment & Standards

Every log line will carry these standard attributes:

| Attribute       | Source                     | Example                        |
|-----------------|----------------------------|--------------------------------|
| `service`       | Serilog property           | `brezyweather`                 |
| `env`           | Environment variable       | `production`                   |
| `version`       | Assembly version           | `1.2.0`                        |
| `host`          | Machine name               | `brezyweather-987`             |
| `source`        | Serilog source context     | `BrezyWeather.Pages.IndexModel`|
| `trace_id`      | Correlation ID middleware  | `abc123-def456`                |
| `http.method`   | Request enricher           | `GET`                          |
| `http.url`      | Request enricher           | `/Weather`                     |
| `http.status`   | Response enricher          | `200`                          |
| `duration_ms`   | Request timing middleware  | `42`                           |

---

## 5. Log Levels & Volume Management

| Level       | Index? | Archive? | Examples                              |
|-------------|--------|----------|---------------------------------------|
| Fatal       | Yes    | Yes      | Unhandled exceptions, crash           |
| Error       | Yes    | Yes      | Failed DB queries, 5xx responses      |
| Warning     | Yes    | Yes      | Slow queries, deprecated usage        |
| Information | Yes    | Yes      | Request start/end, business events    |
| Debug       | No*    | Yes      | Detailed diagnostics                  |
| Verbose     | No     | No       | Not emitted in production             |

*Debug logs are excluded from the index (to save cost) but still archived.

**Exclusion filters on the index:**
- `@http.url:/health*` -- health probe noise
- `@http.url:*.ico` -- favicon requests
- `@http.url:/lib/*` -- static asset requests

---

## 6. Cost Optimization

| Lever                     | Impact                                      |
|---------------------------|---------------------------------------------|
| Index exclusion filters   | Reduces indexed volume by ~40-60%           |
| Debug logs archive-only   | Keeps debug data without index cost         |
| Azure Blob lifecycle      | Cool + Archive tiers cut storage cost ~80%  |
| Sampling (if needed)      | Datadog index sampling can reduce by 50%+   |
| Daily quota on index      | Hard cap prevents runaway costs             |

---

## 7. Monitoring the Logging Pipeline

| Monitor                           | Alert Condition                   |
|-----------------------------------|-----------------------------------|
| Log volume anomaly                | >2x daily baseline                |
| Zero logs received                | 0 logs for 15 minutes            |
| Archive lag                       | Archive files >1 hour behind     |
| Error rate spike                  | Error logs >5% of total          |

---

## 8. Implementation Summary

The coding changes required fall into four areas:

### A. NuGet Packages
- `Serilog.AspNetCore` -- core Serilog integration for ASP.NET Core
- `Serilog.Sinks.Datadog.Logs` -- direct log shipping to Datadog API
- `Serilog.Enrichers.Environment` -- adds machine name, env
- `Serilog.Enrichers.Thread` -- adds thread ID
- `Serilog.Expressions` -- for filtering/exclusion in config

### B. Application Code Changes
- `Program.cs` -- replace default logging with Serilog bootstrap
- `appsettings.json` -- Serilog configuration with Datadog sink settings
- `Middleware/RequestLoggingMiddleware.cs` -- structured request/response logging

### C. Configuration & Secrets
- `DD_API_KEY` -- stored as Azure App Service application setting (secret)
- `DD_ENV` -- environment tag (`production`, `staging`)
- `DD_SERVICE` -- service name (`brezyweather`)
- `DD_VERSION` -- application version

### D. Infrastructure (Azure Blob Storage for Archives)
- Storage account with lifecycle management policy
- SAS token or Azure AD integration for Datadog archive access
- Defined in the Terraform/Bicep files (see `infra/` directory)

---

## 9. Retention Summary Matrix

| Data Location            | Retention | Searchable?      | Cost    |
|--------------------------|-----------|------------------|---------|
| Datadog Index            | 90 days   | Yes, immediate   | $$$     |
| Datadog Online Archive   | +90 days  | Yes, rehydration | $$      |
| Azure Blob (Hot)         | 0-30 days | Manual download  | $$      |
| Azure Blob (Cool)        | 30-90 days| Manual download  | $       |
| Azure Blob (Archive)     | 90-365 days| Rehydrate first | cents   |

**Net result:** Logs are immediately searchable for 90 days, rehydratable for up
to 180 days, and available in cold storage for 365 days.
