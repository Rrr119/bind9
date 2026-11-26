#!/bin/bash
set -euo pipefail
ROOT=/home/dev/feedback/uid38802
INST=$ROOT/artifacts/install
LAB=$ROOT/artifacts/lab
export LD_LIBRARY_PATH=$INST/lib
PATH=$INST/sbin:$INST/bin:$PATH

cd "$LAB"
TA=run/trust-anchors.conf
echo "trust-anchors {" > "$TA"

for z in example.test example.org example.net; do
	# Pick the currently-omnipresent KSK (flag 257) key file.
	kf=$(grep -l "DNSKEY.*257 " keys/$z/K*.key | head -1)
	rr=$(grep -v '^;' "$kf" | grep DNSKEY \
		| sed 's/^[^ ]* *[0-9]* *IN *DNSKEY *//' \
		| awk '{flags=$1; alg=$2; ft=$3; $1="";$2="";$3=""; b64=$0; gsub(/^ +| +$/,"",b64); printf "%s %s %s \"%s\"", flags, alg, ft, b64}')
	echo "	$z static-key $rr;" >> "$TA"
done
echo "};" >> "$TA"

echo "== trust anchors =="
cat "$TA"

for z in example.test example.org example.net; do
	echo "== delv validation: $z =="
	delv -a "$TA" "+root=$z" -p 5353 @127.0.0.1 www.$z A 2>&1 \
		| grep -E "fully validated|bogus|SERVFAIL|inexp|No trusted" | head -3
done
