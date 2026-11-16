#!/usr/bin/env bash
# TEMPORARY debugging aid, not for merge.
# Repeatedly runs a surefire test selection and, when a run exceeds the limit,
# captures the state of the forked test JVM and the Maven JVM before killing them.
#
# Usage: repro-loop.sh <test-selector> <duration-minutes> <per-run-limit-seconds>
set -u
SELECTOR=$1
DURATION_MIN=$2
LIMIT=$3
DIAG=$PWD/hang-diag
mkdir -p "$DIAG"
MOD_DIR=hadoop-yarn-project/hadoop-yarn/hadoop-yarn-server/hadoop-yarn-server-resourcemanager
END=$(( $(date +%s) + DURATION_MIN * 60 ))
runs=0; hangs=0; fails=0

dump_java_pid() {
  local p=$1 d=$2
  {
    echo "### pid $p"
    tr '\0' ' ' < /proc/$p/cmdline | cut -c1-600; echo
    cat /proc/$p/status
    echo "### fds"; ls -l /proc/$p/fd
    echo "### threads (tid state utime stime wchan comm)"
    for t in /proc/$p/task/*; do
      echo "$(basename $t) $(awk '{print $3, $14, $15}' $t/stat 2>/dev/null) $(cat $t/wchan 2>/dev/null) $(cat $t/comm 2>/dev/null)"
    done
  } > "$d/proc-$p.txt" 2>&1
  timeout 60 jstack -l $p > "$d/jstack-$p.txt" 2>&1; echo "jstack rc=$?" >> "$d/jstack-$p.txt"
  timeout 60 jcmd $p Thread.print -e > "$d/jcmd-thread-print-$p.txt" 2>&1
  # Native view, in case the JVM is frozen and cannot answer attach requests.
  sudo timeout 180 gdb -p $p -batch -ex "set pagination off" -ex "thread apply all bt 25" \
    > "$d/gdb-$p.txt" 2>&1
  sudo timeout 180 "$JAVA_HOME/bin/jhsdb" jstack --pid $p > "$d/jhsdb-jstack-$p.txt" 2>&1
  # Second Java-level sample to tell a deadlock from a busy loop.
  sleep 5
  timeout 60 jstack -l $p > "$d/jstack-$p-second.txt" 2>&1
}

while [ "$(date +%s)" -lt "$END" ]; do
  runs=$((runs+1))
  log=$DIAG/../run.log
  ./mvnw $MAVEN_ARGS -pl :hadoop-yarn-server-resourcemanager test -Dtest="$SELECTOR" \
    -Dsurefire.excludesFile=$PWD/.github/gha-tests/exclude-tests.txt > "$log" 2>&1 &
  mvn_pid=$!
  start=$(date +%s); hung=0
  while kill -0 $mvn_pid 2>/dev/null; do
    sleep 2
    if [ $(( $(date +%s) - start )) -ge "$LIMIT" ]; then
      hung=1; hangs=$((hangs+1))
      d=$DIAG/hang-$hangs; mkdir -p "$d"
      echo "::warning::run $runs HUNG, collecting diagnostics into $d"
      cp "$log" "$d/maven.log"
      ps -eLo pid,ppid,lwp,stat,pcpu,etime,wchan:24,comm > "$d/ps-threads.txt" 2>&1
      ps -eo pid,ppid,stat,etime,args | cut -c1-400 > "$d/ps.txt" 2>&1
      for p in $(pgrep java); do dump_java_pid $p "$d"; done
      mkdir -p "$d/target"
      cp -r $MOD_DIR/target/surefire-reports "$d/target/" 2>/dev/null
      cp -r $MOD_DIR/target/surefire "$d/target/" 2>/dev/null
      find $MOD_DIR -maxdepth 2 -name "*.dump*" -exec cp {} "$d/" \; 2>/dev/null
      pkill -9 -f surefirebooter
      sleep 2
      kill -9 $mvn_pid 2>/dev/null; pkill -9 -f "org.apache.maven.wrapper" 2>/dev/null
      break
    fi
  done
  wait $mvn_pid 2>/dev/null; rc=$?
  if [ $hung -eq 0 ] && [ $rc -ne 0 ]; then
    fails=$((fails+1))
    f=$DIAG/fail-$fails; mkdir -p "$f"
    cp "$log" "$f/maven.log"
    cp -r $MOD_DIR/target/surefire-reports "$f/" 2>/dev/null
    echo "::warning::run $runs FAILED rc=$rc"
    grep -E "Tests run:|ERROR" "$log" | head -20
  fi
  echo "run $runs: hung=$hung rc=$rc elapsed=$(( $(date +%s) - start ))s  (total hangs=$hangs fails=$fails)"
  if [ $hangs -ge 3 ]; then break; fi
done
echo "SUMMARY selector=$SELECTOR runs=$runs hangs=$hangs fails=$fails" | tee "$DIAG/summary.txt"
