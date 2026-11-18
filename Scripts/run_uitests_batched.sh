#!/bin/bash
# UI 测试分批跑：每批之前重启模拟器，全程输出可观察的状态与进度。
#
# 为什么必须分批：一次性串行跑 27 个用例要一个多小时，跑到后半段
# 模拟器会劣化（日志里反复 kAXErrorServerNotFound，单个用例能跑 10 分钟），
# 于是出现「同一用例上一轮过、这一轮挂」的假失败。
# 分批 + 批间重启，让每一批都在干净环境下跑，结果才可信。
#
# 日志约定（看这一层就够了，不必翻原始日志）：
#   →  阶段/环境变化（重启模拟器、构建、测试进程启动）
#   ▸  单个用例开始，前面带 [n/总数]
#   ✓  用例通过（附耗时）      ✗  用例失败（附耗时）
#   ⚠  可疑信号（单例耗时异常，结果不可信）
#   !  断言或编译错误原文
#   原始输出全量落盘在 build/uitest/batch-<tag>.log
#
# 用法：
#   ./scripts/run_uitests_batched.sh              # 跑全部 6 批
#   ./scripts/run_uitests_batched.sh chaos2       # 只跑指定批次
#   HEARTBEAT=0 ./scripts/run_uitests_batched.sh  # 关掉「仍在执行」心跳
#   SLOW_WARN=120 ./scripts/run_uitests_batched.sh
set -uo pipefail

DEV="${SIM_ID:-EDFD5776-CDD3-4203-B630-3E2B6AFB749C}"
BUNDLE="com.example.qiannote"
OUT="build/uitest"
SLOW_WARN="${SLOW_WARN:-180}"
HEARTBEAT="${HEARTBEAT:-90}"
ERASE="${ERASE:-1}"          # 首轮之前抹掉设备，清掉上一轮留下的僵死服务
AX_WARN="${AX_WARN:-20}"     # 单批里无障碍服务异常超过这个数，结果判为不可信
WORKERS="${WORKERS:-1}"      # 并行 worker 数（>1 时 Xcode 自动克隆模拟器）
SUMMARY="$OUT/summary.txt"

mkdir -p "$OUT"

# ---------------------------------------------------------------- 小工具

fmt_dur() {
  local s="$1"
  if [ "$s" -ge 60 ]; then
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

hr() { printf '%s\n' "--------------------------------------------------------------"; }
bar() { printf '%s\n' "=============================================================="; }

# 用例清单（class 级传整个类，个别传具体方法）
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

# 批次对应的源文件，用于提前算出预期用例数
FILE_canvas="QianNoteUITests/CanvasInteractionTests.swift"
FILE_chaos1="QianNoteUITests/ChaosRound1Tests.swift"
FILE_chaos2="QianNoteUITests/ChaosRound2Tests.swift"
FILE_editor_a="QianNoteUITests/EditorFeatureTests.swift"
FILE_editor_b="QianNoteUITests/EditorFeatureTests.swift"
FILE_library="QianNoteUITests/LibraryFeatureTests.swift"

ALL_BATCHES="canvas chaos1 chaos2 editor-a editor-b library"
BATCHES="${*:-$ALL_BATCHES}"
# 允许用下划线写批次名
BATCHES=$(printf '%s' "$BATCHES" | tr '_' '-')

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
    # class 级：直接数源文件里的 test 方法
    local c
    c=$(grep -cE '^\s+func test' "$vn" 2>/dev/null)
    [ -n "${c:-}" ] && [ "$c" -gt 0 ] && n=$c
  fi
  printf '%s' "$n"
}

# ---------------------------------------------------------------- 单批执行

PASS_TOTAL=0
FAIL_TOTAL=0
BATCH_N=0
BATCH_TOTAL=$(printf '%s\n' $BATCHES | grep -c .)
FAILED_CASES=""
BATCH_ROWS=""
RUN_START=$SECONDS

# ---------------------------------------------------------------- 开场信息

{
  bar
  printf ' QianNote UI 回归 · 分批执行\n'
  printf ' 开始时间   %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf ' 设备       %s\n' "$(xcrun simctl list devices | grep -F "$DEV" | head -1 | sed -E 's/^[[:space:]]+//; s/ \([0-9A-F-]{36}\)//' )"
  printf ' Xcode      %s\n' "$(xcodebuild -version 2>/dev/null | head -1)"
  printf ' 批次       %s 批（%s）\n' "$BATCH_TOTAL" "$(printf '%s' "$BATCHES" | tr '\n' ' ')"
  printf ' 单例告警   %ss（超过即提示模拟器劣化）\n' "$SLOW_WARN"
  printf ' 环境抹除   %s\n' "$([ "$ERASE" = "1" ] && echo '首批前 erase，清掉僵死服务' || echo '关闭（ERASE=0）')"
  printf ' 并行度     %s\n' "$([ "$WORKERS" -gt 1 ] && echo "$WORKERS 个 worker（克隆模拟器）" || echo '串行（WORKERS=1）')"
  printf ' 健康阈值   单批 kAXErrorServerNotFound ≥ %s 次即判为本批不可信\n' "$AX_WARN"
  printf ' 原始日志   %s/batch-<tag>.log\n' "$OUT"
  printf ' 汇总文件   %s\n' "$SUMMARY"
  bar
}

for tag in $BATCHES; do
  list_var="CASES_${tag//-/_}"
  list="${!list_var:-}"
  if [ -z "$list" ]; then
    printf '!! 未知批次 "%s"，可选：%s\n' "$tag" "$ALL_BATCHES"
    continue
  fi

  BATCH_N=$((BATCH_N + 1))
  expect=$(expected_cases "$tag")
  log="$OUT/batch-$tag.log"
  bstart=$SECONDS

  hr
  printf ' [%d/%d] %s · 预期 %s 个用例 · 开始 %s\n' \
    "$BATCH_N" "$BATCH_TOTAL" "$tag" "$expect" "$(date '+%H:%M:%S')"
  hr

  # --- 环境准备（每一步都报，卡住时一眼看出卡在哪） ---
  env_start=$SECONDS
  printf '  → 重启模拟器…\n'
  xcrun simctl shutdown "$DEV" >/dev/null 2>&1
  sleep 3
  if [ "$ERASE" = "1" ] && [ "$BATCH_N" = "1" ]; then
    printf '  → 抹掉设备数据（清掉上一轮残留的僵死服务）…\n'
    xcrun simctl erase "$DEV" >/dev/null 2>&1
  fi
  xcrun simctl boot "$DEV" >/dev/null 2>&1
  # 等真正 boot 完成，而不是 blind sleep：
  # 提前 uninstall 会在设备还在启动时动手，测试起来触摸注入就时好时坏
  if ! xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1; then
    printf '  ⚠ bootstatus 未正常返回，继续尝试\n'
  fi
  xcrun simctl uninstall "$DEV" "$BUNDLE" >/dev/null 2>&1
  printf '  → 模拟器就绪并清空 App 数据（%s）\n' "$(fmt_dur $((SECONDS - env_start)))"

  # --- 组装 only-testing 参数 ---
  args=()
  while IFS= read -r t; do
    [ -n "$t" ] && args+=("-only-testing:$t")
  done <<< "$list"

  # 并行：Xcode 会为每个 worker 克隆一台模拟器自己装包跑，
  # 单例 ~1 分钟的超重 UI 用例只有并行才跑得动
  par=()
  if [ "$WORKERS" -gt 1 ]; then
    par+=("-parallel-testing-enabled" "YES" "-parallel-testing-worker-count" "$WORKERS")
    printf '  → 并行执行：%s 个 worker（Xcode 自动克隆模拟器）\n' "$WORKERS"
  fi

  printf '  → 启动 xcodebuild（原始输出 → %s）\n' "$log"

  # --- 心跳：长用例期间也不至于一片静默 ---
  hb_pid=""
  if [ "$HEARTBEAT" -gt 0 ]; then
    (
      while :; do
        sleep "$HEARTBEAT"
        printf '        … 仍在执行（本批已 %s）\n' "$(fmt_dur $((SECONDS - bstart)))"
      done
    ) &
    hb_pid=$!
  fi

  # --- 真正的执行：tee 落盘 + awk 压成进度流 ---
  xcodebuild test \
    -project QianNote.xcodeproj -scheme QianNote \
    -destination "platform=iOS Simulator,id=$DEV" \
    "${args[@]}" \
    "${par[@]}" \
    -derivedDataPath "$OUT/dd" \
    CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-disable-sandbox' \
    2>&1 | tee "$log" | awk -v total="$([ "$WORKERS" -gt 1 ] && echo 0 || echo "$expect")" \
    -v slow="$SLOW_WARN" -f Scripts/filter_test_output.awk
  code=${PIPESTATUS[0]}

  if [ -n "$hb_pid" ]; then kill "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null; fi

  # --- 解析结果（以落盘日志为准，不信流式输出的计数） ---
  p=0; f=0
  [ -f "$log" ] && p=$(grep -cE "Test Case.*' passed" "$log")
  [ -f "$log" ] && f=$(grep -cE "Test Case.*' failed" "$log")
  p=${p:-0}; f=${f:-0}
  elapsed=$((SECONDS - bstart))

  # 一个用例都没跑起来 = 编译或启动就失败了，这和「用例失败」是两回事
  if [ $((p + f)) -eq 0 ]; then
    printf '  → 本批没有执行任何用例（exit=%s，编译或启动失败）\n' "$code"
    printf '  → 前几条错误：\n'
    grep -E "error:" "$log" 2>/dev/null | sed -E 's#.*/(QianNote|QianNoteUITests)/##' \
      | cut -c1-220 | head -6 | sed 's/^/        ! /'
  else
    printf '  ── 结果：%d 通过 / %d 失败 · 用时 %s（exit=%s）\n' \
      "$p" "$f" "$(fmt_dur "$elapsed")" "$code"
  fi

  # 环境健康度：无障碍服务异常刷屏时，触摸注入会整体失效，
  # 这批的失败不能算到 App 头上
  ax=0
  [ -f "$log" ] && ax=$(grep -c "kAXErrorServerNotFound" "$log")
  ax=${ax:-0}
  suspect=""
  if [ "$ax" -ge "$AX_WARN" ]; then
    printf '  ⚠ 本批出现 %s 次 kAXErrorServerNotFound（无障碍服务异常）\n' "$ax"
    printf '    这类失败大概率是模拟器劣化，不能算 App 的问题；建议 ERASE=1 重跑本批\n'
    suspect="（环境可疑）"
  fi

  # 失败用例清单（这是下一步要逐个看的）
  if [ "$f" -gt 0 ] || [ "$p" -eq 0 ]; then
    names=$(grep -E "Test Case.*' failed" "$log" 2>/dev/null \
      | sed -E "s/.*\[QianNoteUITests\.([A-Za-z]+) ([a-zA-Z0-9_]+)\]'.*/\1.\2/")
    if [ -n "$names" ]; then
      printf '  → 失败用例：\n'
      printf '%s\n' "$names" | sed 's/^/        - /'
      FAILED_CASES="$FAILED_CASES$names
"
    fi
  fi

  PASS_TOTAL=$((PASS_TOTAL + p))
  FAIL_TOTAL=$((FAIL_TOTAL + f))
  BATCH_ROWS="$BATCH_ROWS$(printf '%-10s %3s 例  %3s 通过  %3s 失败  %s %s' "$tag" $((p + f)) "$p" "$f" "$(fmt_dur "$elapsed")" "$suspect")
"
done

# ---------------------------------------------------------------- 汇总

total_elapsed=$((SECONDS - RUN_START))
{
  bar
  printf ' 汇总 · %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  bar
  printf '%s\n' "$BATCH_ROWS" | sed '/^$/d'
  hr
  printf ' 合计  %3s 例  %3s 通过  %3s 失败 · 总用时 %s\n' \
    $((PASS_TOTAL + FAIL_TOTAL)) "$PASS_TOTAL" "$FAIL_TOTAL" "$(fmt_dur "$total_elapsed")"

  if [ "$FAIL_TOTAL" -eq 0 ] && [ "$PASS_TOTAL" -gt 0 ]; then
    printf ' 结论  全部通过，可以进入下一轮新增用例\n'
  elif [ "$FAIL_TOTAL" -gt 0 ]; then
    printf ' 结论  有 %s 个用例失败，逐条看 build/uitest/batch-*.log\n' "$FAIL_TOTAL"
  else
    printf ' 结论  没有用例被执行，先看编译错误\n'
  fi

  if [ -n "$(printf '%s' "$FAILED_CASES" | tr -d '[:space:]')" ]; then
    printf ' 失败清单\n'
    printf '%s\n' "$FAILED_CASES" | sed '/^$/d' | sort -u | sed 's/^/   - /'
  fi
  bar
} | tee "$SUMMARY"

exit $([ "$FAIL_TOTAL" -eq 0 ] && [ "$PASS_TOTAL" -gt 0 ] && echo 0 || echo 1)
