# Time-triggered ZSK/KSK rollover under inline-signing

This lab reproduces and accepts the requested behaviour on BIND 9.21:

1. Time-triggered ZSK **and** KSK rollover, independent of zone reload.
2. Old + new key material coexisting during the rollover window (dual
   write / pre-publication).
3. Compatibility with the existing `inline-signing yes` configuration.
4. After rollover, the `delv` validation chain stays intact on three
   zones, and a high-concurrency `+dnssec` workload never returns an
   answer missing an RRSIG.

## Why no reload is needed (where the behaviour lives)

Modern BIND removed the legacy `auto-dnssec` knob and drives every
signed zone, including inline-signed ones, through the `dnssec-policy`
key manager. Maintenance is timer driven, not reload driven:

- `zone_timer()` -> `zone_maintenance()` (`lib/dns/zone.c`) fires on the
  zone's one-shot timer; for a primary zone it calls `zone_rekey()` once
  `now >= zone->refreshkeytime`.
- `zone_rekey()` runs `dns_keymgr_run()` (`lib/dns/keymgr.c`), which
  advances each key's lifecycle state machine (created -> published ->
  active -> retired -> removed) and returns the next scheduled event.
- On every run `zone_rekey()` re-arms `zone->refreshkeytime` to either
  the next key event returned by the key manager or
  `dnssec-loadkeys-interval` seconds away, then calls
  `dns__zone_settimer()`. The timer therefore keeps re-arming itself;
  an expired key is replaced when its lifetime elapses, with no reload.
- The key manager keeps the retiring key published/active alongside its
  successor for the propagation/safety interval. During the ZSK overlap,
  live RRsets carry RRSIGs from both key tags; during KSK rollover the
  DNSKEY RRset carries both KSK tags.
- This working tree also clamps an overdue keymgr event to a zero-second
  timer in `zone_rekey()`, preventing the unsigned time delta from wrapping
  into a long delay.

Relevant code:

- `lib/dns/zone.c`: `zone_maintenance`, `zone_rekey`, `set_refreshkeytimer`,
  `dns__zone_set_resigntime`, `zone_timer`.
- `lib/dns/keymgr.c`: `dns_keymgr_run` (key lifecycle / scheduling).
- `lib/dns/zoneproperties.c`: `dns_zone_setrefreshkeyinterval`
  (`dnssec-loadkeys-interval`).

## Layout

- `conf/policy.conf` - short-lived `fastroll` policy (200 s key lifetime,
  small propagation delays) so rollover is observable in minutes.
- `conf/named.conf` - three primary zones, each `inline-signing yes`
  with `dnssec-policy "fastroll"` and its own key directory.
- `00-setup.sh` - regenerate keys/zones/config and a matching rndc
  shared secret.
- `01-start.sh` - start named.
- `02-validate.sh` - build trust anchors from the live KSKs and run
  `delv` for all three zones.
- `03-concurrent.sh` - parallel `dig +dnssec` workload; fail on any
  SERVFAIL/timeout or any answer without an RRSIG.
- `04-acceptance.sh` - one-shot end-to-end acceptance orchestrating all
  of the above and asserting that every zone produced a successor key
  and serves two live KSKs / two live ZSKs, with simultaneous old/new
  `A` RRSIGs, during the overlap window.

## Run

```sh
cd artifacts/lab
WATCH=300 CONC_N=1500 CONC_PAR=96 bash 04-acceptance.sh
```

For a heavier cut-over soak, run `bash 03-concurrent.sh 6000 256` while
the script reports two `A` RRSIG key tags.

Expected tail:

```
== verify old+new RRSIG dual-write on live A RRsets ==
  every zone is dual-signing with its old and new ZSK
== [3/4] delv chain validation for all 3 zones ==
  example.test: fully validated
  example.org: fully validated
  example.net: fully validated
== [4/4] concurrent +dnssec workload ==
total=1500 servfail_or_timeout=0 missing_rrsig=0
CONCURRENT-OK: every answer carried an RRSIG
ACCEPTANCE-OK
```
