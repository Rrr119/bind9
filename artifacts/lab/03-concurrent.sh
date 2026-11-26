#!/bin/bash
set -euo pipefail
ROOT=/home/dev/feedback/uid38802
INST=$ROOT/artifacts/install
LAB=$ROOT/artifacts/lab
export LD_LIBRARY_PATH=$INST/lib
DIG=$INST/bin/dig

cd "$LAB"
N=${1:-2000}
PAR=${2:-128}
find run -maxdepth 1 -name 'q-*' -delete 2>/dev/null || true

echo "firing $N +dnssec queries across 3 zones (parallelism $PAR)..."
seq 1 "$N" | xargs -P "$PAR" -I{} bash -c '
	i=$1
	z=$(printf "example.%s\n" test org net | sed -n "$((i % 3 + 1))p")
	'"$DIG"' +time=5 +tries=2 -p 5353 @127.0.0.1 "www.$z" A +dnssec \
		> "run/q-$i.out" 2>&1
' _ {}

total=$(find run -maxdepth 1 -name 'q-*.out' | wc -l)
nosig=0
servfail=0
for f in run/q-*.out; do
	if ! grep -q 'status: NOERROR' "$f"; then
		servfail=$((servfail + 1))
	# RRSIG covering the A rrset: line begins with owner and contains "RRSIG A"
	elif ! grep -Eq 'IN[[:space:]]+RRSIG[[:space:]]+A[[:space:]]' "$f"; then
		nosig=$((nosig + 1))
	fi
done

echo "total=$total servfail_or_timeout=$servfail missing_rrsig=$nosig"
if [ "$servfail" -eq 0 ] && [ "$nosig" -eq 0 ]; then
	echo "CONCURRENT-OK: every answer carried an RRSIG"
else
	echo "CONCURRENT-FAIL"
	exit 1
fi
