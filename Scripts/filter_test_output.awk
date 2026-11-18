# 把 xcodebuild 的原始输出压成「可观察的进度流」。
#
# 只打印三类事件：构建阶段信号、单个用例的开始/结果、错误详情。
# 其余编译命令行、链接参数、系统日志一律丢弃（完整内容仍在 batch-<tag>.log 里）。
#
# 用法：awk -v total=N -v slow=S -f filter_test_output.awk
#   total  本批预期用例数，用于显示 [3/5]
#   slow   单例耗时告警阈值（秒），超过则提示可能模拟器劣化

BEGIN {
    idx = 0
    build_shown = 0
    suite_shown = 0
    if (total == "") total = "?"
    if (slow == "") slow = 180
}

# ---------- 构建阶段 ----------

/^Testing started/ {
    printf "  → 测试进程已启动，开始注入触摸\n"
    fflush()
    next
}

/^(Build|CompileSwift|SwiftCompile|SwiftDriver|Ld|Link|ProcessInfoPlistFile|CpResource)/ {
    if (!build_shown) {
        printf "  → 构建中…（首次较慢，之后走增量）\n"
        fflush()
        build_shown = 1
    }
    next
}

# ---------- 用例开始 / 结果 ----------

/Test Case '-\[/ {
    line = $0

    # 从 Test Case '-[QianNoteUITests.Class method]' 里取出 Class.method
    name = line
    sub(/^.*\[QianNoteUITests\./, "", name)
    sub(/\]'.*$/, "", name)
    gsub(/ /, ".", name)

    if (line ~ /' started\./) {
        idx++
        if (total + 0 == 0) {
            printf "  ▸ %s\n", name          # 并行跑：多个 worker 交错，编号没意义
        } else {
            printf "  [%d/%s] ▸ %s\n", idx, total, name
        }
        fflush()
        next
    }

    if (line ~ /' passed \(/ || line ~ /' failed \(/) {
        d = line
        sub(/^.*\(/, "", d)
        sub(/ seconds\).*$/, "", d)

        if (line ~ /' passed \(/) {
            printf "        ✓ 通过 %ss\n", d
        } else {
            printf "        ✗ 失败 %ss\n", d
        }

        # 单例跑这么久基本只有一种解释：模拟器状态劣化，触摸注入开始超时
        if (d + 0 >= slow + 0) {
            printf "        ⚠ 单例耗时 %ss ≥ %ss，疑似模拟器劣化（该结果不可信）\n", d, slow
        }
        fflush()
        next
    }
}

# ---------- 错误详情 ----------

/: error:/ {
    e = $0
    sub(/^.*\/QianNoteUITests\//, "", e)
    sub(/^.*\/QianNote\//, "", e)
    sub(/^.*\/scripts\//, "", e)
    printf "        ! %s\n", substr(e, 1, 260)
    fflush()
    next
}

/error: (linker command failed|No such file|Unable to find|The operation|Failed to)/ {
    printf "        ! %s\n", substr($0, 1, 260)
    fflush()
    next
}

# ---------- 批次收尾 ----------

/\*\* TEST FAILED \*\*/ {
    printf "  → xcodebuild 报告 TEST FAILED\n"
    fflush()
    next
}

/\*\* TEST SUCCEEDED \*\*/ {
    printf "  → xcodebuild 报告 TEST SUCCEEDED\n"
    fflush()
    next
}
