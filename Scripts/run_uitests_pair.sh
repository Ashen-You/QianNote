#!/bin/bash
# 两台 iPad 模拟器分片跑 UI 回归（两路并行 + 单台补跑）。
#
# 为什么不用 Xcode 的并行测试：它会为每个 worker 现场 clone 模拟器，
# 本机 CoreSimulator 在 clone 阶段会长时间卡住（日志反复出现
# Unable to discover any Simulator runtimes）。
# 为什么最多两台：三台同时跑会压垮模拟器的无障碍/测试服务，
# 出现 kAXErrorServerNotFound 和 testmanagerd "server died" 假失败。
#
# 模拟器保持开机，不再整机重启/erase；每批只卸载 App 与测试 Runner，
# 由 xcodebuild 自动重装，省掉平板重新进入可交互状态的时间。
#
# 前提：先执行
#   xcodebuild build-for-testing -project QianNote.xcodeproj -scheme QianNote \
#     -destination 'generic/platform=iOS Simulator' -derivedDataPath build/uitest/dd \
#     CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-disable-sandbox'
#
# 用法：
#   bash Scripts/run_uitests_pair.sh          # 两波全部批次
#   WAVE=1 bash Scripts/run_uitests_pair.sh   # 只跑第一波（canvas/chaos1 + chaos2）
#   WAVE=2 bash Scripts/run_uitests_pair.sh   # 只跑第二波（editor-a/editor-b + library）
set -uo pipefail

OUT="build/uitest"
DD="$OUT/dd"
BUNDLE="com.example.qiannote"
SLOW_WARN="${SLOW_WARN:-180}"

DEV_A="${DEV_A:-F06257AF-C69E-4EC1-9AA2-38B0DC08CF37}"
DEV_B="${DEV_B:-9F10B562-1179-4FB5-B458-443D8D154155}"

CASES_canvas="QianNoteUITests/CanvasInteractionTests"
CASES_chaos1="QianNoteUITests/ChaosRound1Tests"
CASES_chaos2="QianNoteUITests/ChaosRound2Tests"
CASES_editor_a="QianNoteUITests/EditorFeatureTests/test01_undoRedo_restoresInk
QianNoteUITests/EditorFeatureTests/test02_clearPage_wipesAllInk
QianNoteUITests/EditorFeatureTests/test03_insertPages_growsCount_andKeepsInk
QianNoteUITests/EditorFeatureTests/test04_renameNote_fromTitleButton
QianNoteUITests/EditorFeatureTests/test05_fullScreen_enterAndExit"
CASES_editor_b="QianNoteUITests/EditorFeatureTests/test06_toolbarCollapse_andRestore
QianNoteUITests/EditorFeatureTests/test07_laserTool_leavesNoPersistentInk
QianNoteUITests/EditorFeatureTests/test08_continuousScroll_stillDraws
QianNoteUITests/EditorFeatureTests/test09_pinchZoom_stillDraws
QianNoteUITests/EditorFeatureTests/test10_rapidToolSwitching_staysResponsive
QianNoteUITests/EditorFeatureTests/test11_lastPage_disablesNextButton"
CASES_library="QianNoteUITests/LibraryFeatureTests"

FILE_canvas="QianNoteUITests/CanvasInteractionTests.swift"
FILE_chaos1="QianNoteUITests/ChaosRound1Tests.swift"
FILE_chaos2="QianNoteUITests/ChaosRound2Tests.swift"
FILE_editor_a="QianNoteUITests/EditorFeatureTests.swift"
FILE_editor_b="QianNoteUITests/EditorFeatureTests.swift"
FILE_library="QianNoteUITests/LibraryFeatureTests.swift"

PASS_TOTAL=0
FAIL_TOTAL=0
UNTESTED=0
FAILED_CASES=""
ROWS=""

fmt_dur() {
  local s="$1"
  if [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

expected_cases() {
  local tag="$1" vf vn
  vf="FILE_${tag//-/_}"
  vn="${!vf:-}"
  local list_var="CASES_${tag//-/_}"
  local list="${!list_var:-}"
  local n
  n=$(printf '%s\n' "$list" | grep -c . 2>/dev/null)
  n=${n:-0}
  if [ "$n" -eq 1 ] && [ -f "$vn" ]; then
    local c
    c=$(grep -cE '^\s+func test' "$vn" 2>/dev/null)
    [ -n "${c:-}" ] && [ "$c" -gt 0 ] && n=$c
  fi
  printf '%s' "$n"
}

run_batch() {
  local tag="$1" dev="$2"
  local log="$OUT/par-$tag.log"
  local list_var="CASES_${tag//-/_}"
  local list="${!list_var}"
  local expect
  expect=$(expected_cases "$tag")
  local args=()
  while IFS= read -r t; do
    [ -n "$t" ] && args+=("-only-testing:$t")
  done <<< "$list"

  xcrun simctl uninstall "$dev" "$BUNDLE" >/dev/null 2>&1
  rm -rf "$OUT/result-$tag.xcresult"
  printf '  → [%s] 开始在 %s（预期 %s 例）· %s\n' \
    "$tag" "${dev:0:8}" "$expect" "$(date '+%H:%M:%S')"
  : > "$log"
  (
    xcodebuild test-without-building \
      -project QianNote.xcodeproj -scheme QianNote \
      -destination "platform=iOS Simulator,id=$dev" \
      "${args[@]}" \
      -parallel-testing-enabled NO \
      -derivedDataPath "$DD" \
      -resultBundlePath "$OUT/result-$tag.xcresult" \
      CODE_SIGNING_ALLOWED=NO \
      2>&1 | tee "$log" \
      | awk -v total="$expect" -v slow="$SLOW_WARN" -f Scripts/filter_test_output.awk \
      | awk -v tag="$tag" '{ printf "[%s] %s\n", tag, $0; fflush() }'
    echo "[$tag] 进程结束 exit=${PIPESTATUS[0]} · $(date '+%H:%M:%S')"
  ) &
}

report_batch() {
  local tag="$1" dev="$2" elapsed="$3"
  local log="$OUT/par-$tag.log"
  local p=0 f=0
  [ -f "$log" ] && p=$(grep -cE "Test Case.*' passed" "$log")
  [ -f "$log" ] && f=$(grep -cE "Test Case.*' failed" "$log")
  p=${p:-0}; f=${f:-0}

  if [ $((p + f)) -eq 0 ]; then
    UNTESTED=$((UNTESTED + 1))
    printf '  ✗ [%s] 没有执行任何用例 · %s（启动失败）\n' "$tag" "$(fmt_dur "$elapsed")"
    grep -E "error:" "$log" 2>/dev/null | sed -E 's#.*/(QianNote|QianNoteUITests)/##' \
      | cut -c1-220 | head -4 | sed "s/^/        ! [$tag] /"
  else
    printf '  %s [%s] %s 通过 / %s 失败 · %s\n' \
      "$([ "$f" -eq 0 ] && echo ✓ || echo ✗)" "$tag" "$p" "$f" "$(fmt_dur "$elapsed")"
  fi

  local ax=0
  [ -f "$log" ] && ax=$(grep -c "kAXErrorServerNotFound" "$log")
  ax=${ax:-0}
  local suspect=""
  if [ "$ax" -ge 20 ]; then
    printf '  ⚠ [%s] kAXErrorServerNotFound × %s，本批结果不可信\n' "$tag" "$ax"
    suspect="（环境可疑）"
  fi

  if [ "$f" -gt 0 ] || [ "$p" -eq 0 ]; then
    local names
    names=$(grep -E "Test Case.*' failed" "$log" 2>/dev/null \
      | sed -E "s/.*\[QianNoteUITests\.([A-Za-z]+) ([a-zA-Z0-9_]+)\]'.*/\1.\2/")
    if [ -n "$names" ]; then
      printf '%s\n' "$names" | sed "s/^/        - /"
      FAILED_CASES="$FAILED_CASES$names
"
    fi
  fi

  PASS_TOTAL=$((PASS_TOTAL + p))
  FAIL_TOTAL=$((FAIL_TOTAL + f))
  ROWS="$ROWS$(printf '%-10s %s  %3s 例  %3s 通过  %3s 失败  %s %s' "$tag" "${dev:0:8}" $((p + f)) "$p" "$f" "$(fmt_dur "$elapsed")" "$suspect")
"
}

run_wave() {
  local name="$1"; shift
  local spec tag dev start
  local pids=()
  local tags=()
  local devs=()
  local starts=()
  local first=1
  printf '\n==============================================================\n'
  printf ' %s · %s\n' "$name" "$(date '+%H:%M:%S')"
  printf '==============================================================\n'
  for spec in "$@"; do
    if [ "$first" = "1" ]; then
      first=0
    else
      sleep "${STAGGER:-10}"
    fi
    tag="${spec%%:*}"
    dev="${spec#*:}"
    tags+=("$tag"); devs+=("$dev"); starts+=("$SECONDS")
    run_batch "$tag" "$dev"
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  local i
  for i in "${!tags[@]}"; do
    report_batch "${tags[$i]}" "${devs[$i]}" $((SECONDS - starts[$i]))
  done
}

printf '==============================================================\n'
printf ' QianNote UI 回归 · 两台 iPad 分片（无 Xcode clone）\n'
printf ' 开始 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf ' 设备 A %s\n' "$DEV_A"
printf ' 设备 B %s\n' "$DEV_B"
printf '==============================================================\n'

if [ ! -d "$DD/Build/Products" ]; then
  printf '!! 缺少 build-for-testing 产物，先按脚本头部命令编译\n'
  exit 1
fi

RUN_START=$SECONDS

case "${WAVE:-both}" in
  1)
    run_wave "第一波（2 路）" \
      "canvas:$DEV_A" \
      "chaos1:$DEV_B"
    run_wave "第一波补跑" \
      "chaos2:$DEV_A" ;;
  2)
    run_wave "第二波（2 路）" \
      "editor-a:$DEV_A" \
      "editor-b:$DEV_B"
    run_wave "第二波补跑" \
      "library:$DEV_A" ;;
  both)
    run_wave "第一波（2 路）" \
      "canvas:$DEV_A" \
      "chaos1:$DEV_B"
    run_wave "第一波补跑" \
      "chaos2:$DEV_A"
    run_wave "第二波（2 路）" \
      "editor-a:$DEV_A" \
      "editor-b:$DEV_B"
    run_wave "第二波补跑" \
      "library:$DEV_A" ;;
  *) printf '!! 未知 WAVE=%s\n' "$WAVE"; exit 1 ;;
esac

{
  printf '\n==============================================================\n'
  printf ' 汇总 · %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '==============================================================\n'
  printf '%s\n' "$ROWS" | sed '/^$/d'
  printf '%s\n' '--------------------------------------------------------------'
  printf ' 合计  %3d 例  %3d 通过  %3d 失败 · 总用时 %s\n' \
    $((PASS_TOTAL + FAIL_TOTAL)) "$PASS_TOTAL" "$FAIL_TOTAL" "$(fmt_dur $((SECONDS - RUN_START)))"
  if [ "$UNTESTED" -gt 0 ]; then
    printf ' 结论  有 %d 批没有执行任何用例（启动失败），结果不完整\n' "$UNTESTED"
  elif [ "$FAIL_TOTAL" -eq 0 ] && [ "$PASS_TOTAL" -gt 0 ]; then
    printf ' 结论  全部通过\n'
  elif [ "$FAIL_TOTAL" -gt 0 ]; then
    printf ' 结论  有 %d 个用例失败，逐条看 build/uitest/par-*.log\n' "$FAIL_TOTAL"
  else
    printf ' 结论  没有用例被执行\n'
  fi
  if [ -n "$(printf '%s' "$FAILED_CASES" | tr -d '[:space:]')" ]; then
    printf ' 失败清单\n'
    printf '%s\n' "$FAILED_CASES" | sed '/^$/d' | sort -u | sed 's/^/   - /'
  fi
  printf '==============================================================\n'
} | tee "$OUT/par-summary.txt"

exit $([ "$FAIL_TOTAL" -eq 0 ] && [ "$PASS_TOTAL" -gt 0 ] && [ "$UNTESTED" -eq 0 ] && echo 0 || echo 1)
