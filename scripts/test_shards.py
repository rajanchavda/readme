#!/usr/bin/env python3
"""Splits the tests into shards of about equal running time, and records how long each test takes.

plan <timings> <shards> <dir>   writes <dir>/shard-N.args, the xcodebuild arguments for each shard
record <timings> <xcresult>...  rewrites <timings> from the results of a run
failed <xcresult>...            prints the xcodebuild arguments that rerun the tests that failed

The last shard is given what's left by skipping what the others run, so a test that isn't in the
timings yet (a new one) still runs.
"""
import json
import subprocess
import sys
from pathlib import Path

TARGET = "ReadmeTests"


def plan(timings: Path, count: int, out: Path) -> None:
    times = json.loads(timings.read_text()) if timings.exists() else {}
    shards = [[] for _ in range(count)]
    loads = [0.0] * count
    for test, seconds in sorted(times.items(), key=lambda item: (-item[1], item[0])):
        lightest = loads.index(min(loads))
        shards[lightest].append(test)
        loads[lightest] += seconds
    # The heaviest shard goes last, as its tests are named by what the others skip.
    last = loads.index(max(loads))
    shards.append(shards.pop(last))
    for number, tests in enumerate(shards):
        if number < count - 1:
            lines = [f"-only-testing:{TARGET}/{test}" for test in tests]
            # With nothing to run, the shard is left out rather than running everything.
            path = out / f"shard-{number}.args"
            if lines:
                path.write_text("\n".join(lines) + "\n")
        else:
            others = [test for shard in shards[:-1] for test in shard]
            (out / f"shard-{number}.args").write_text(
                "".join(f"-skip-testing:{TARGET}/{test}\n" for test in others))


def results(bundle: str) -> dict:
    """Each test's identifier, with its seconds and whether it passed."""
    output = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
        check=True, capture_output=True, text=True).stdout
    found = {}

    def walk(node: dict) -> None:
        if node.get("nodeType") == "Test Case" and "nodeIdentifier" in node:
            found[node["nodeIdentifier"]] = (node.get("durationInSeconds") or 0.0, node.get("result"))
        for child in node.get("children", []):
            walk(child)

    for node in json.loads(output).get("testNodes", []):
        walk(node)
    return found


def record(timings: Path, bundles: list[str]) -> None:
    times = {}
    ran = 0
    for bundle in bundles:
        for test, (seconds, _) in results(bundle).items():
            ran += 1
            times[test] = round(seconds, 1)
    if len(times) != ran:
        sys.exit(f"error: {ran - len(times)} tests ran in more than one shard")
    old = json.loads(timings.read_text()) if timings.exists() else {}
    # Timings wobble from run to run, so the file is only rewritten when the split would be off:
    # tests came or went, or the run took a different time overall.
    drift = abs(sum(times.values()) - sum(old.values())) > 0.15 * max(1.0, sum(old.values()))
    if set(times) != set(old) or drift:
        timings.write_text(json.dumps(times, indent=0, sort_keys=True) + "\n")
    print(ran)


if __name__ == "__main__":
    if sys.argv[1] == "plan":
        plan(Path(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4]))
    elif sys.argv[1] == "failed":
        for bundle in sys.argv[2:]:
            for test, (_, result) in results(bundle).items():
                if result == "Failed":
                    print(f"-only-testing:{TARGET}/{test}")
    else:
        record(Path(sys.argv[2]), sys.argv[3:])
