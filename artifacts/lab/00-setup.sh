#!/bin/bash
# Reproduction lab: time-triggered ZSK/KSK rollover under inline-signing.
set -euo pipefail

ROOT=/home/dev/feedback/uid38802
INST=$ROOT/artifacts/install
LAB=$ROOT/artifacts/lab
export LD_LIBRARY_PATH=$INST/lib
export PATH=$INST/sbin:$INST/bin:$PATH

ZONES="example.test example.org example.net"

cd "$LAB"
rm -rf zones keys run log conf
mkdir -p zones keys run log conf

# One shared HMAC secret for both the named control channel and rndc.
export LD_LIBRARY_PATH=$INST/lib
export PATH=$INST/sbin:$INST/bin:$PATH
tsig-keygen rndc-key | awk -F'"' '/secret/{print $2}' > run/rndc.secret

# dnssec-policy with short, test-friendly lifetimes and explicit ZSK + KSK.
cat > conf/policy.conf <<'EOF'
dnssec-policy "fastroll" {
	dnskey-ttl 60;
	max-zone-ttl 60;
	parent-ds-ttl 60;
	zone-propagation-delay 1;
	parent-propagation-delay 1;
	publish-safety 0;
	retire-safety 0;
	signatures-validity 300;
	signatures-refresh 240;
	signatures-jitter 0;
	keys {
		ksk key-directory lifetime 200 algorithm 13;
		zsk key-directory lifetime 200 algorithm 13;
	};
};
EOF

for z in $ZONES; do
	cat > zones/$z.db <<EOF
\$TTL 30
@   IN SOA ns1.$z. admin.$z. ( 1 30 30 60 30 )
@   IN NS  ns1.$z.
ns1 IN A   127.0.0.1
www IN A   127.0.0.2
EOF
done

cat > conf/named.conf <<EOF
include "$LAB/conf/policy.conf";

options {
	directory "$LAB";
	pid-file "$LAB/run/named.pid";
	listen-on port 5353 { 127.0.0.1; };
	listen-on-v6 { none; };
	recursion no;
	dnssec-validation no;
	managed-keys-directory "$LAB/run";
	session-keyfile "$LAB/run/session.key";
};
controls {
	inet 127.0.0.1 port 9553 allow { 127.0.0.1; }
		keys { rndc-key; };
};
key rndc-key {
	algorithm hmac-sha256;
	secret "$(cat "$LAB/run/rndc.secret")";
};
EOF

for z in $ZONES; do
	cat >> conf/named.conf <<EOF
zone "$z" {
	type primary;
	file "$LAB/zones/$z.db";
	inline-signing yes;
	dnssec-policy "fastroll";
	key-directory "$LAB/keys/$z";
};
EOF
	mkdir -p keys/$z
done

cat > conf/rndc.conf <<EOF
key rndc-key {
	algorithm hmac-sha256;
	secret "$(cat "$LAB/run/rndc.secret")";
};
options {
	default-key rndc-key;
	default-server 127.0.0.1;
	default-port 9553;
};
EOF

named-checkconf -t / conf/named.conf 2>/dev/null || named-checkconf conf/named.conf
echo "setup OK"
