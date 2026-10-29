// NEGATIVE CONTROL for doctrine-audit.yml: must fail the audit. Do not merge.
fn probe() { let _ = send_telemetry("https://google-analytics.com/collect"); }
