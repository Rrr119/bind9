#!/bin/bash
set -euo pipefail
ROOT=/home/dev/feedback/uid38802
INST=$ROOT/artifacts/install
LAB=$ROOT/artifacts/lab
export LD_LIBRARY_PATH=$INST/lib
export PATH=$INST/sbin:$INST/bin:$PATH

cd "$LAB"
if [ -f run/named.pid ] && kill -0 "$(cat run/named.pid)" 2>/dev/null; then
	echo "named already running pid $(cat run/named.pid)"
	exit 0
fi
setsid named -c conf/named.conf -g < /dev/null > log/named.run 2>&1 &
echo $! > run/named.pid
sleep 3
if kill -0 "$(cat run/named.pid)" 2>/dev/null; then
	echo "named started pid $(cat run/named.pid)"
else
	echo "named failed to start, see log/named.run"
	tail -20 log/named.run
	exit 1
fi
