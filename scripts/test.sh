#!/bin/bash
# Usage: scripts/test.sh [Suite | Suite/test()]
# Generates the Xcode project and runs the tests, optionally limited to one suite or test.
# Prints the failures and a summary, and fails if no tests ran (a misspelt suite name, say).
#
# The whole suite runs as several copies of the app at once, each with a share of the tests picked
# from scripts/test-timings.json to take about as long as the others. SHARDS sets how many. Tests
# that fail there run once more on their own, as some time what they do and a busy machine is slow;
# the ones that then pass are listed, and the ones that fail again fail the run.
#
# The app under test is built outside the project. Inside ~/Documents, macOS asks for leave to
# read the folder for every new build of every copy.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1

xcodegen generate --quiet || exit $?

derived=${README_TEST_BUILD:-$HOME/Library/Caches/com.rajanchavda.Readme.tests}/DerivedData
work=build/test-run
timings=scripts/test-timings.json
shown='^([^[:space:]]+: )?(fatal )?error:|^/.*: (fatal )?(error|warning):|^✘|^\*\* .*FAILED|^Testing failed:|^The test runner'
rm -rf "$work" && mkdir -p "$work" || exit 1

xcodebuild build-for-testing -project Readme.xcodeproj -scheme Readme -destination 'platform=macOS' \
  -derivedDataPath "$derived" > "$work/build.log" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
  grep -E "$shown" "$work/build.log"
  exit "$status"
fi
run=$(ls -t "$derived"/Build/Products/*.xctestrun | head -1)

if [ -n "$1" ]; then
  shards=1
  echo "-only-testing:ReadmeTests/$1" > "$work/shard-0.args"
else
  shards=${SHARDS:-6}
  python3 scripts/test_shards.py plan "$timings" "$shards" "$work" || exit 1
fi

started=$SECONDS
pids=()
for ((n = 0; n < shards; n++)); do
  [ -f "$work/shard-$n.args" ] || continue
  args=()
  while IFS= read -r line; do args+=("$line"); done < "$work/shard-$n.args"
  # TEST_RUNNER_ hands the rest of the name to the app under test, which keeps its settings by shard.
  TEST_RUNNER_README_TEST_SHARD=$n xcodebuild test-without-building -xctestrun "$run" \
    -destination 'platform=macOS' -resultBundlePath "$work/shard-$n.xcresult" "${args[@]}" \
    > "$work/shard-$n.log" 2>&1 &
  pids+=($!)
done

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=$?
done

if [ -z "$1" ] && [ "$status" -ne 0 ]; then
  python3 scripts/test_shards.py failed "$work"/shard-*.xcresult > "$work/retry.args"
  if [ -s "$work/retry.args" ]; then
    echo "Failed alongside the others, so run again alone:"
    sed -E 's/^-only-testing:ReadmeTests\//  /' "$work/retry.args"
    args=()
    while IFS= read -r line; do args+=("$line"); done < "$work/retry.args"
    mkdir "$work/first" && mv "$work"/shard-*.log "$work/first/"
    xcodebuild test-without-building -xctestrun "$run" -destination 'platform=macOS' \
      -resultBundlePath "$work/retry.xcresult" "${args[@]}" > "$work/shard-retry.log" 2>&1
    status=$?
    retried=$(wc -l < "$work/retry.args" | tr -d ' ')
  fi
fi

cat "$work"/shard-*.log | grep -E "$shown"

# Swift Testing ends with "Test run with N tests ... passed|failed".
ran=0
for log in "$work"/shard-*.log "$work"/first/shard-*.log; do
  [ -f "$log" ] || continue
  count=$(sed -nE 's/^[^ ]* Test run with ([0-9]+) tests?.*/\1/p' "$log" | tail -1)
  ran=$((ran + ${count:-0}))
done
if [ "$status" -eq 0 ] && [ "$ran" -eq 0 ]; then
  echo "error: no tests ran${1:+ for '$1'}" >&2
  exit 1
fi
if [ -z "$1" ] && [ "$status" -eq 0 ] && [ -z "$retried" ]; then
  python3 scripts/test_shards.py record "$timings" "$work"/shard-*.xcresult > /dev/null || exit 1
fi
ran=$((ran - ${retried:-0}))
echo "Summary: $ran tests run in $((SECONDS - started))s, exit status $status"
exit "$status"
