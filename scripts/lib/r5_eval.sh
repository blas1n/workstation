# r5_eval.sh — pure helpers for the BStalk3r R5 prospective evaluation.
#
# Sourced by scripts/bstalk3r-r5-eval.sh and tests/test_bstalk3r_r5_eval.sh.
# The live return here is an APPROXIMATION from the trade logs' `equity $…`
# line (printed by each 04:30 KST mr-trade run, i.e. intraday 15:30 ET). The
# pre-registration's verdict uses Alpaca portfolio history closes.

# r5_log_equity <logfile> — the equity number from the run summary, no commas.
r5_log_equity() {
  grep -o 'equity \$[0-9,.]*' "$1" 2>/dev/null | head -1 | sed 's/equity \$//; s/,//g'
}

# r5_window_logs <logdir> <start YYYYMMDD> <end YYYYMMDD>
# First and last trade-YYYYMMDD.log inside [start, end] that carry an equity line.
r5_window_logs() {
  local dir=$1 start=$2 end=$3 f d found=()
  for f in "$dir"/trade-????????.log; do
    [ -e "$f" ] || continue
    d=$(basename "$f" .log); d=${d#trade-}
    [ "$d" -lt "$start" ] || [ "$d" -gt "$end" ] && continue
    [ -n "$(r5_log_equity "$f")" ] && found+=("$f")
  done
  [ "${#found[@]}" -ge 2 ] || return 1
  printf '%s\n%s\n' "${found[0]}" "${found[${#found[@]}-1]}"
}

# r5_live_return <logdir> <start> <end> — end/start - 1, 6 decimals. Fails
# (non-zero, no output) when the window has fewer than two usable logs.
r5_live_return() {
  local pair first last a b
  pair=$(r5_window_logs "$1" "$2" "$3") || return 1
  first=$(echo "$pair" | head -1); last=$(echo "$pair" | tail -1)
  a=$(r5_log_equity "$first"); b=$(r5_log_equity "$last")
  awk -v a="$a" -v b="$b" 'BEGIN { if (a <= 0) exit 1; printf "%.6f\n", b / a - 1 }'
}

# r5_should_run <today YYYYMMDD> <marker> — run once, on or after 2027-01-05.
# launchd's calendar has no year, so the marker stops it from re-firing yearly.
r5_should_run() {
  [ "$1" -ge 20270105 ] && [ ! -e "$2" ]
}
