#!/usr/bin/env python3
import json
import subprocess
import sys

bundle = sys.argv[1] if len(sys.argv) > 1 else "job412-checkpoint1.xcresult"
out = subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
    capture_output=True, text=True, check=True,
)
data = json.loads(out.stdout)

fails = []
known = []
passed = 0


def walk(node):
    global passed
    if node.get("nodeType") == "Test Case":
        result = node.get("result")
        if result == "Passed":
            passed += 1
        elif result == "Expected Failure":
            known.append(node["name"])
        elif result == "Failed":
            fails.append(node["name"])
    for c in node.get("children", []):
        walk(c)


for n in data["testNodes"]:
    walk(n)

print(f"passed={passed} failed={len(fails)} known={len(known)}")
print("--- FAILED ---")
for f in sorted(fails):
    print(f)
