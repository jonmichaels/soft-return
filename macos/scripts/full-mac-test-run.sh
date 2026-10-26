#!/bin/bash
# The full Mac test run, armed, UI authorization first.
#
#   macos/scripts/full-mac-test-run.sh <result-dir>
#
# Jon, 2026-10-26: "There needs to be a pre-authorization. 'It's time to do the full test run. Authorize UI now.'
# The very first thing triggers that authorization. I do it. And THEN all the testing happens." macOS asks for
# authentication the first time a run drives the UI (Automation Mode); in one run of the whole Corpus plan that prompt
# came whenever the UI-test runner happened to start, and unanswered it failed the 8 UI tests ("Authentication
# canceled"). So the run is two parts:
#
#   1. the UI tests (SoftReturnUITests, from the Corpus plan), started at once: the prompt appears now, while Jon is told
#      to expect it;
#   2. the CorpusUnits plan: the Corpus plan without the UI target, so no UI-test runner starts and nothing can prompt.
#      (Skipping the UI tests within the Corpus plan is not enough: the runner still launches.)
#
# Both go through test-isolation-gate.sh, armed with the TEST_RUNNER_ copies (docs/RELEASE-CHECKLIST.md, step 5c). The
# result bundles are <result-dir>/ui.xcresult and <result-dir>/corpus.xcresult. Exits non-zero if either part failed;
# the second part runs whatever the first did, so one run reports everything.
#
# Run it bare from the repo root, outside the sandbox. `automationmodetool` with no argument prints whether this Mac
# still needs authentication; `sudo automationmodetool enable-automationmode-without-authentication` removes the prompt
# for good (Jon's decision, not this script's).
set -uo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:?usage: macos/scripts/full-mac-test-run.sh <result-dir>}"
mkdir -p "$out"

: "${CTRLKD_SAWYER_ARCHIVE:?export CTRLKD_SAWYER_ARCHIVE (docs/RELEASE-CHECKLIST.md, step 4b)}"
: "${CTRLKD_PRIVATE_CORPUS:?export CTRLKD_PRIVATE_CORPUS}"
: "${CTRLKD_SRC:?export CTRLKD_SRC}"
export TEST_RUNNER_CTRLKD_SAWYER_ARCHIVE="$CTRLKD_SAWYER_ARCHIVE"
export TEST_RUNNER_CTRLKD_PRIVATE_CORPUS="$CTRLKD_PRIVATE_CORPUS"
export TEST_RUNNER_CTRLKD_SRC="$CTRLKD_SRC"
unset SR_DOC

common=(xcodebuild test -quiet -workspace "$repo/macos/SoftReturn.xcworkspace" -scheme SoftReturn
        -destination "platform=macOS,arch=$(uname -m)")

echo "It's time to do the full test run. Authorize UI now."
automationmodetool 2>&1 | sed 's/^/  automation mode: /'
"$repo/macos/scripts/test-isolation-gate.sh" "${common[@]}" -testPlan Corpus -only-testing:SoftReturnUITests \
    -resultBundlePath "$out/ui.xcresult"
ui=$?
echo "UI tests: exit $ui. The rest of the Corpus plan runs now and drives no UI."

"$repo/macos/scripts/test-isolation-gate.sh" "${common[@]}" -testPlan CorpusUnits \
    -resultBundlePath "$out/corpus.xcresult"
corpus=$?
echo "Corpus plan without the UI tests: exit $corpus."

[ "$ui" -eq 0 ] && [ "$corpus" -eq 0 ]
