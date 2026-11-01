#!/bin/zsh
# End-to-end tests for Clinqy in Chrome, against local pages only (tests/site).
# Needs: Clinqy.app running (./build.sh run) and the extension installed in the browser under test.
# Usage: tests/run.sh [name-filter]          CLINQY_BROWSER=Arc tests/run.sh  (default: Google Chrome)
set -u
cd "$(dirname "$0")"
LOG=~/Library/Logs/Clinqy/agent.log
BASE=http://127.0.0.1:8765
FILTER=${1:-}
BROWSER=${CLINQY_BROWSER:-Google Chrome}
PASS=0; FAIL=0

pgrep -x Clinqy >/dev/null || { echo "Clinqy isn't running (./build.sh run)"; exit 1; }
python3 -m http.server 8765 --bind 127.0.0.1 --directory site >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; osascript -e "tell application \"$BROWSER\" to close (every window whose URL of active tab starts with \"$BASE\")" >/dev/null 2>&1
      [[ $BROWSER == Arc ]] && osascript -e "tell application \"Arc\" to tell front window to close (every tab whose URL starts with \"$BASE\")" >/dev/null 2>&1' EXIT
chrome() { osascript -e "tell application \"$BROWSER\" to $1" 2>/dev/null; }
frontmost() { osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'; }
# Open a test page. Arc ignores setting a tab's URL by script, so it gets a new tab each time.
goto() {
  if [[ $BROWSER == Arc ]]; then chrome "tell front window to make new tab with properties {URL:\"$1\"}" >/dev/null
  else chrome "set URL of active tab of front window to \"$1\""; fi
}
# Bring the browser forward and wait until it really is (macOS ignores AppleScript "activate" from background scripts).
front_chrome() {
  for i in 1 2 3 4 5 6; do
    open -a "$BROWSER"; sleep 0.5
    [[ $(frontmost) == "$BROWSER" ]] && return 0
  done
  return 1
}
# Open the test window straight on a local page: Chrome's New Tab page (AI Mode, Gemini) can hang with "Page
# Unresponsive" before the first test gets to navigate away from it.
sleep 0.5
if [[ $BROWSER == Arc ]]; then chrome "make new window" >/dev/null
else open -na "$BROWSER" --args --new-window "$BASE/help.html"; sleep 1.5; fi
front_chrome || { echo "Couldn't bring $BROWSER to the front"; exit 1; }
sleep 1
touch $LOG


# case <name> <page> <task> <check: title:<text> | answer:<text> | notitle:<text>> [auto-answer] [extra url params]
case_() {
  local name=$1 page=$2 task=$3 check=$4 reply=${5:-} extra=${6:-}
  [[ -n $FILTER && $name != *$FILTER* ]] && return
  goto "$BASE/$page"
  front_chrome
  sleep 2
  local front=$(frontmost)
  local url=$(chrome "get URL of active tab of front window")
  if [[ $front != "$BROWSER" || $url != $BASE/* ]]; then echo "SKIP  $name (test page not in front: $front $url)"; return; fi
  local start=$(wc -l < $LOG) t0=$(date +%s)
  open -g "clinqy://run?task=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$task")&test=1$extra&token=$(cat ~/.config/clinqy/cli-token)"
  local answered=0 unconfirmed=0
  for i in $(seq 1 90); do
    sleep 1
    local out=$(tail -n +$((start+1)) $LOG)
    if [[ -n $reply && $answered == 0 && $out == *"Ask:"* || -n $reply && $answered == 0 && $out == *"About to click"* \
          || -n $reply && $answered == 0 && $out == *"review “"*": waiting"* ]]; then
      sleep 1; open -g "clinqy://answer?text=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$reply")&token=$(cat ~/.config/clinqy/cli-token)"; answered=1
    fi
    # A model that cannot confirm an outcome itself may ask the user; an unattended test answers "no" so it fails honestly
    # instead of blocking every test queued behind it.
    if [[ $unconfirmed == 0 && $out == *"Clinqy couldn't confirm this itself"* ]]; then
      sleep 1; open -g "clinqy://answer?text=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "No, it did not happen")&token=$(cat ~/.config/clinqy/cli-token)"; unconfirmed=1
    fi
    echo $out | grep -qE "\] (✓|✗)" && break
  done
  sleep 1
  local out=$(tail -n +$((start+1)) $LOG)
  local answer=$(echo $out | grep -E "\] (✓|✗)" | tail -1)
  local title=$(chrome "get title of active tab of front window")
  local ok=0
  case $check in
    title:*)   [[ $title == *${check#title:}* ]] && ok=1 ;;
    notitle:*) [[ $title != *${check#notitle:}* ]] && ok=1 ;;
    answer:*)  [[ $answer == *${check#answer:}* ]] && ok=1 ;;
  esac
  local secs=$(( $(date +%s) - t0 )) turns=$(echo $out | grep -c ' turn ')
  if (( ok )); then PASS=$((PASS+1)); printf "PASS  %-16s %3ss %2s turns\n" $name $secs $turns
  else FAIL=$((FAIL+1)); printf "FAIL  %-16s %3ss %2s turns  title=%s\n      %s\n" $name $secs $turns "$title" "${answer:0:160}"; fi
}

case_ checkboxes   form.html   "tick Keynote and Design panel"                   "title:Keynote,Design panel"
case_ radio        form.html   "choose Great for how was it"                      "title:Great"
case_ text         form.html   "type Amrit Nigam as the name, don't submit"       "title:name=Amrit Nigam"
case_ dropdown     form.html   "set the city to Pune"                             "title:city=Pune"
case_ pay-declined pay.html    "click the pay button"                             "title:pay:unpaid"   "No"
case_ pay-asked    pay.html    "buy this mouse"                                   "title:pay:PAID"     "Yes, go ahead"
case_ read-pdf     resume.pdf  "what's the mobile number on this resume?"         "answer:98450 12345"
case_ multiline-chat editor.html "in the Message box, write a 4-stop train schedule, one stop per line, but don't send it" "title:msgMultiline=true|sent=0"
case_ wait-text    wait.html   "click Generate report and tell me the confirmation code"      "answer:ZX-4417"
# LinkedIn-style modal: scrolling body, Next below the fold, a backdrop that closes it, a note that shifts the fields.
case_ easy-apply   easyapply.html "apply with Easy Apply: phone 9876543210, city Mumbai, 1 year of Python, current CTC 0" "title:applied:yes|phone=9876543210|city=Mumbai|years=1|ctc=0|backdrop=0" "Yes, go ahead"
# Eight steps of pure navigation, one Next per turn: the fast helper should take some turns, with diffs not full lists.
case_ nav-steps    steps.html  "click Next one step at a time (one click per turn, checking the page each time) until the last step, then tell me the secret word" "answer:PINEAPPLE"
# Standard application questions: the job profile fills them without asking; then the review card gates Submit.
case_ profile-fill apply.html  "fill this job application with my details, but don't submit it" "title:apply:filled=5|submitted=0"
case_ review-card  apply.html  "fill this job application with my details and submit it" "title:apply:filled=5|submitted=1" "submit" "&review=1"
# A question the profile can't answer: asked once, and the answer is kept in the profile (restored afterwards).
PROFILE=~/Library/Application\ Support/Clinqy/profile.json
cp "$PROFILE" /tmp/clinqy-profile-backup.json 2>/dev/null
case_ profile-ask  "apply.html?notice=1" "fill this job application with my details, but don't submit it" "title:apply:filled=6|submitted=0" "Rahul Mehta" "&save=1"
if [[ -z $FILTER || profile-ask == *$FILTER* ]]; then
  if grep -q "Rahul Mehta" "$PROFILE" 2>/dev/null; then PASS=$((PASS+1)); echo "PASS  profile-saved    answer kept in the profile"
  else FAIL=$((FAIL+1)); echo "FAIL  profile-saved    “Rahul Mehta” not saved to profile.json"; fi
fi
[[ -f /tmp/clinqy-profile-backup.json ]] && cp /tmp/clinqy-profile-backup.json "$PROFILE"
case_ tabs         tabs.html   "open the Help page from here in a new tab, tell me its heading, then close that tab" "answer:7731"
case_ code-editor  monaco.html "replace the code in this editor with a Python solution to Two Sum using a dictionary" "title:indented=true|oneLine=false"
# Clicks that need more than a click at the centre: a dropdown that loads its options as it scrolls (and names the
# country differently), an upload button that makes its file field on the spot, a button with a badge over its middle
# that only takes real clicks, and a button the page keeps re-rendering.
case_ lazy-dropdown  clicks.html "choose USA as the country" "title:country=United States"
case_ dynamic-upload clicks.html "attach the file $PWD/site/resume.pdf with the Attach resume button" "title:file=resume.pdf"
case_ covered-button clicks.html "click Mark as read once" "title:badge=1"
case_ rerendered     clicks.html "click the Save draft button once" "title:saved=1"

# Undo: after a run types into a field, clinqy://undo puts back what was there before.
undo_case() {
  [[ -n $FILTER && undo != *$FILTER* ]] && return
  case_ undo-setup form.html "type Priya Shah as the name, don't submit" "title:name=Priya Shah"
  open -g "clinqy://undo?token=$(cat ~/.config/clinqy/cli-token)"; sleep 2
  local title=$(chrome "get title of active tab of front window")
  if [[ $title != *"name=Priya Shah"* ]] && tail -5 $LOG | grep -q "↩ undo text"; then PASS=$((PASS+1)); echo "PASS  undo             name restored (title=$title)"
  else FAIL=$((FAIL+1)); echo "FAIL  undo             title=$title · $(tail -3 $LOG | grep undo)"; fi
}
undo_case

# Dry run: points at each step without doing it, so the form stays untouched.
case_ dry-run      form.html   "tick Keynote and Design panel" "notitle:Keynote" "" "&dry=1"

# Stop: cancelling mid-run ends it promptly and leaves no button held down.
stop_case() {
  [[ -n $FILTER && stop != *$FILTER* ]] && return
  goto "$BASE/steps.html"; front_chrome; sleep 2
  local start=$(wc -l < $LOG) t0=$(date +%s)
  open -g "clinqy://run?task=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "click Next one step at a time, one click per turn, until the last step")&test=1&token=$(cat ~/.config/clinqy/cli-token)"
  sleep 5
  open -g "clinqy://cancel?token=$(cat ~/.config/clinqy/cli-token)"
  local ended=0
  for i in $(seq 1 10); do sleep 1; tail -n +$((start+1)) $LOG | grep -qE "\] (✓|✗)" && { ended=1; break; }; done
  local title=$(chrome "get title of active tab of front window")
  if (( ended )) && [[ $title != *"8 of 8"* ]]; then PASS=$((PASS+1)); echo "PASS  stop             stopped in $(( $(date +%s) - t0 ))s at “$title”"
  else FAIL=$((FAIL+1)); echo "FAIL  stop             ended=$ended title=$title"; fi
}
stop_case

# Watch & learn: act like the user (real input via the debug binary), learn a skill, then run it with new values.
watch_learn() {
  [[ -n $FILTER && watch-learn != *$FILTER* ]] && return
  local B=../.build/debug/Clinqy
  [[ -x $B ]] || { echo "SKIP  watch-learn (swift build first)"; return; }
  local SK=~/Library/Application\ Support/Clinqy/skills.json
  local before=$(python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Clinqy/skills.json');print(len(json.load(open(p))) if os.path.exists(p) else 0)")
  goto "$BASE/form.html"; front_chrome; sleep 2
  # Never type into whatever else is in front (an editor, a terminal).
  [[ $(frontmost) == "$BROWSER" ]] || { echo "SKIP  watch-learn ($BROWSER not in front: $(frontmost))"; return; }
  open -g "clinqy://watch?token=$(cat ~/.config/clinqy/cli-token)"; sleep 1.5
  $B --click-label "Your name" >/dev/null && sleep 0.4 && $B --type "Amrit Nigam"; sleep 0.4
  $B --click-label "Keynote" >/dev/null; sleep 0.4; $B --click-label "Great" >/dev/null; sleep 0.6
  open -g "clinqy://stop-watching?token=$(cat ~/.config/clinqy/cli-token)"
  local name=""
  for i in $(seq 1 30); do sleep 1
    name=$(python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Clinqy/skills.json');d=json.load(open(p)) if os.path.exists(p) else [];print(d[0]['name'] if len(d)>$before else '')")
    [[ -n $name ]] && break
  done
  if [[ -z $name ]]; then FAIL=$((FAIL+1)); echo "FAIL  watch-learn      no skill learned"; return; fi
  case_ skill-run form.html "Use the skill “$name”." "title:name=Priya" "name Priya, session Swift workshop, rating Okay"
  # Leave the user's skills as they were.
  python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Clinqy/skills.json');d=json.load(open(p));json.dump([s for s in d if s['name']!='$name'],open(p,'w'))"
  PASS=$((PASS+1)); echo "PASS  watch-learn      learned “$name”"
}
watch_learn

# The clinqy command: learn a QA test, then it must replay with no model.
qa_cli() {
  [[ -n $FILTER && qa-cli != *$FILTER* ]] && return
  goto "$BASE/form.html"; front_chrome; sleep 2   # a fresh form, not one an earlier case filled
  local out
  out=$(../bin/clinqy qa qa/feedback-form.md --relearn 2>&1 | head -1)
  if [[ $out != PASS* ]]; then FAIL=$((FAIL+1)); echo "FAIL  qa-learn         $out"; return; fi
  PASS=$((PASS+1)); echo "PASS  qa-learn         ${out#PASS  }"
  out=$(../bin/clinqy qa qa/feedback-form.md 2>&1 | head -1)
  if [[ $out == PASS*"(replay"* ]]; then PASS=$((PASS+1)); echo "PASS  qa-replay        ${out#PASS  }"
  else FAIL=$((FAIL+1)); echo "FAIL  qa-replay        $out"; fi
}
qa_cli

echo "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
