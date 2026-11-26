#!/bin/bash
# End-to-end acceptance for time-triggered ZSK/KSK rollover under
# inline-signing + dnssec-policy.
#
#   1. Start named cleanly with 3 inline-signed, dnssec-policy zones.
#   2. Wait until every zone has actually rolled both ZSK and KSK, and
#      observe the dual-write window (old + new key material coexisting).
#   3. Re-validate the full chain with delv for all 3 zones.
#   4. Fire a high-concurrency +dnssec workload and require zero missing
#      RRSIG and zero SERVFAIL/timeout.
set -euo pipefail

ROOT=/home/dev/feedback/uid38802
INST=$ROOT/artifacts/install
LAB=$ROOT/artifacts/lab
export LD_LIBRARY_PATH=$INST/lib
export PATH=$INST/sbin:$INST/bin:$PATH

ZONES="example.test example.org example.net"
WATCH=${WATCH:-300}          # seconds to wait for rollover

cd "$LAB"

echo "== [1/4] clean (re)start =="
if [ -f run/named.pid ] && kill -0 "$(cat run/named.pid)" 2>/dev/null; then
	rndc -c conf/rndc.conf halt >/dev/null 2>&1 || true
	sleep 1
fi
bash 00-setup.sh
setsid named -c "$LAB/conf/named.conf" -g < /dev/null \
	> "$LAB/log/named.run" 2>&1 &
echo $! > run/named.pid

for _ in $(seq 1 30); do
	if rndc -c conf/rndc.conf status >/dev/null 2>&1; then break; fi
	sleep 1
done
rndc -c conf/rndc.conf status >/dev/null
echo "named up, rndc control channel working"

echo "== [2/4] wait for real ZSK+KSK rollover (dual-write) =="
declare -A saw_successor
deadline=$((SECONDS + WATCH))
while [ "$SECONDS" -lt "$deadline" ]; do
	alldone=1
	for z in $ZONES; do
		# A successor key proves the policy created a replacement;
		# two simultaneously-active signers prove the dual-write
		# window rather than a hard cut-over.
		if grep -q '^Successor:' keys/$z/K*.state 2>/dev/null; then
			saw_successor[$z]=1
		fi
		[ "${saw_successor[$z]:-0}" = 1 ] || alldone=0
	done
	[ "$alldone" = 1 ] && break
	sleep 5
done

for z in $ZONES; do
	count=$(ls keys/$z/K*.key 2>/dev/null | wc -l)
	succ=$(grep -l '^Successor:' keys/$z/K*.state 2>/dev/null | wc -l)
	echo "  $z: key-files=$count states-with-successor=$succ"
	[ "${saw_successor[$z]:-0}" = 1 ] || {
		echo "FAIL: $z never produced a successor key within ${WATCH}s"
		exit 1
	}
done

# Show the dual-write evidence: more than one DNSKEY of each role is live.
for z in $ZONES; do
	ksk=$(dig +short -p 5353 @127.0.0.1 "$z" DNSKEY | awk '{print $1}' | grep -c 257 || true)
	zsk=$(dig +short -p 5353 @127.0.0.1 "$z" DNSKEY | awk '{print $1}' | grep -c 256 || true)
	echo "  $z live DNSKEYs: KSK(257)=$ksk ZSK(256)=$zsk"
	if [ "$ksk" -lt 2 ] || [ "$zsk" -lt 2 ]; then
		echo "FAIL: $z did not expose overlapping old+new DNSKEYs"
		exit 1
	fi
done

echo "== verify old+new RRSIG dual-write on live A RRsets =="
dual_deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$dual_deadline" ]; do
	dual_all=1
	for z in $ZONES; do
		tags=$(dig +dnssec +time=2 +tries=1 -p 5353 @127.0.0.1 \
			"www.$z" A +noall +answer 2>/dev/null \
			| awk '$4 == "RRSIG" && $5 == "A" {print $11}' \
			| sort -u)
		count=$(printf '%s\n' "$tags" | sed '/^$/d' | wc -l)
		echo "  $z A RRSIG key tags: ${tags//$'\n'/ }(${count})"
		if [ "$count" -lt 2 ]; then
			dual_all=0
		fi
	done
	[ "$dual_all" = 1 ] && break
	sleep 2
done
if [ "$dual_all" -ne 1 ]; then
	echo "FAIL: did not observe two simultaneous A RRSIG key tags in every zone"
	exit 1
fi
echo "  every zone is dual-signing with its old and new ZSK"

echo "== [3/4] delv chain validation for all 3 zones =="
TA=run/trust-anchors.conf
echo "trust-anchors {" > "$TA"
for z in $ZONES; do
	kf=$(grep -l "DNSKEY.*257 " keys/$z/K*.key | head -1)
	rr=$(grep -v '^;' "$kf" | grep DNSKEY \
		| sed 's/^[^ ]* *[0-9]* *IN *DNSKEY *//' \
		| awk '{flags=$1; alg=$2; ft=$3; $1="";$2="";$3=""; b64=$0;
		         gsub(/^ +| +$/,"",b64);
		         printf "%s %s %s \"%s\"", flags, alg, ft, b64}')
	echo "	$z static-key $rr;" >> "$TA"
done
echo "};" >> "$TA"

for z in $ZONES; do
	res=$(delv -a "$TA" "+root=$z" -p 5353 @127.0.0.1 "www.$z" A 2>&1)
	echo "$res" | grep -q 'fully validated' || {
		echo "FAIL: delv did not validate $z"
		echo "$res" | tail -5
		exit 1
	}
	echo "  $z: fully validated"
done

echo "== [4/4] concurrent +dnssec workload =="
bash 03-concurrent.sh "${CONC_N:-2000}" "${CONC_PAR:-128}"

echo
echo "ACCEPTANCE-OK: time-triggered ZSK/KSK rollover, dual-write window,"
echo "intact validation chains on 3 zones, and zero missing signatures."
