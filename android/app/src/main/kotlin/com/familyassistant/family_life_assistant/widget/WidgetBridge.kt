package com.familyassistant.family_life_assistant.widget

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * 桌面组件与 Flutter 之间的数据桥。
 *
 * ## 为什么是「一个文件」而不是 SharedPreferences 或插件
 *
 * 桌面组件跑在**原生进程**里，数据却存在 **Flutter 的 sqflite** 里。中间必须有
 * 一层交接，否则用户点了组件、写完表单，记录却进不了账本。
 *
 * 三种做法的取舍：
 *  · **新加插件**（如 `home_widget`）—— 要改 pubspec、走插件注册，多一个外部依赖；
 *  · **SharedPreferences** —— 需要 `shared_preferences` 插件，同样多一个依赖；
 *  · **一个文件**（本方案）—— 零新依赖。因为 Android 上
 *    `context.filesDir` 就是 Flutter `getApplicationDocumentsDirectory()` 指向的目录，
 *    两边本来就能读写同一份文件（`path_provider` 是既有依赖）。
 *
 * 选第三种：不引入任何新依赖，就少一类「插件版本不兼容 / 注册失败」的故障，
 * 而且这个文件的读写逻辑在两端都**可以单独测试**。
 *
 * ## 为什么用 JSON Lines（每行一条 JSON）
 *
 * 关键要求是「**只追加**」：用户可能连着从桌面记三笔，而 App 全程没被打开。
 *  · 每次追加一行，不需要读出整个文件再重写 —— 追加之间不会互相覆盖；
 *  · 即使某次写入被系统中断，最坏只损坏**最后一行**，前面几行照样能用；
 *  · 解析时逐行容错，坏行跳过而不是整份丢弃。
 *
 * 写完之后 App 读取时会把已入库的行删掉（按 [QueueRecord.id] 去重），
 * 所以「入库成功」与「删行」之间即使断电，也不会产生重复账目。
 */
object WidgetBridge {

    /**
     * 待入库队列的文件名。
     *
     * **必须与 Dart 侧 `lib/data/widget_bridge.dart` 里的常量逐字一致** ——
     * 两边写错一个字符就会变成「组件记完了、App 永远读不到」，
     * 而且没有任何报错。测试 `test/widget_bridge_test.dart` 会断言这个名字。
     */
    const val QUEUE_FILE = "widget_pending.jsonl"

    /** 桌面组件展示用的汇总文件名（由 Flutter 写入、原生读取）。 */
    const val SUMMARY_FILE = "widget_summary.json"

    const val KIND_EXPENSE = "expense"
    const val KIND_MED = "med"

    // 表单字段名与 App 内完全一致，同步时可以直接映射，不需要翻译表。
    // 故意不做「组件用简称、App 用全称」的映射：那种映射表一改字段就会漂移，
    // 而漂移的表现是「记了但字段是空的」——静默丢数据，最难查。
    const val KEY_ID = "id"
    const val KEY_KIND = "kind"
    const val KEY_TITLE = "title"
    const val KEY_AMOUNT = "amount"
    const val KEY_CATEGORY = "category"
    const val KEY_NOTE = "note"
    const val KEY_ENTRY_TYPE = "entryType"
    const val KEY_SPENT_AT = "spentAt"
    const val KEY_NAME = "name"
    const val KEY_STOCK = "stock"
    const val KEY_UNIT = "unit"
    const val KEY_EXPIRY = "expiry"
    const val KEY_STORAGE = "storage"
    const val KEY_SPEC = "spec"
    const val KEY_CREATED_AT = "createdAt"

    private fun queueFile(context: Context) = File(context.filesDir, QUEUE_FILE)

    fun summaryFile(context: Context) = File(context.filesDir, SUMMARY_FILE)

    /**
     * 追加一条待入库记录，返回它的 id。
     *
     * 用 `synchronized` 串行化：用户可能在极短时间内连点两次组件，
     * 两个 Activity 实例各写一行。不串行的话两行可能交错成一行坏数据。
     */
    fun append(context: Context, record: JSONObject): String {
        val id = record.optString(KEY_ID).ifEmpty {
            UUID.randomUUID().toString().also { record.put(KEY_ID, it) }
        }
        if (!record.has(KEY_CREATED_AT)) {
            record.put(KEY_CREATED_AT, nowIso())
        }
        val line = record.toString() + "\n"
        synchronized(this) {
            queueFile(context).appendText(line, Charsets.UTF_8)
        }
        return id
    }

    /**
     * 读回待入库记录（只读，不删除）。
     *
     * 坏行直接跳过：宁可少一条，也不能因为一行破损就让整个队列读不出来。
     * 这里**不做删除**——删除只由 Flutter 在「确实写进数据库之后」执行，
     * 因为只有它知道入库成功没有。
     */
    fun read(context: Context): List<JSONObject> {
        val file = queueFile(context)
        if (!file.exists()) return emptyList()
        val out = mutableListOf<JSONObject>()
        file.forEachLine(Charsets.UTF_8) { line ->
            val trimmed = line.trim()
            if (trimmed.isEmpty()) return@forEachLine
            try {
                out.add(JSONObject(trimmed))
            } catch (_: Exception) {
                // 损坏的行（多半是写入被中断的那一行）跳过
            }
        }
        return out
    }

    /** 当前排队条数，桌面组件用来显示角标。 */
    fun pendingCount(context: Context): Int = read(context).size

    /**
     * 写入桌面组件要展示的汇总数据。
     *
     * 由 Flutter 调用（App 每次数据变化后），原生组件只读。
     * 用「先写临时文件再改名」保证原子性：直接覆盖时若被中断，
     * 组件会读到半截 JSON 而显示不出数字。
     */
    fun writeSummary(context: Context, json: JSONObject) {
        val target = summaryFile(context)
        val tmp = File(context.filesDir, "$SUMMARY_FILE.tmp")
        tmp.writeText(json.toString(), Charsets.UTF_8)
        if (!tmp.renameTo(target)) {
            // rename 失败（极少数文件系统）时退回直接写，至少保证有内容
            target.writeText(json.toString(), Charsets.UTF_8)
            tmp.delete()
        }
    }

    /**
     * 读取汇总数据；缺失或损坏时返回空 JSON（组件会显示占位文案）。
     *
     * 绝不抛异常：桌面组件的 `onUpdate` 抛异常会导致系统认为组件坏了，
     * 把整个组件标成「正在加载」并反复重试。组件宁可显示「—」。
     */
    fun readSummary(context: Context): JSONObject {
        val file = summaryFile(context)
        if (!file.exists()) return JSONObject()
        return try {
            JSONObject(file.readText(Charsets.UTF_8))
        } catch (_: Exception) {
            JSONObject()
        }
    }

    private fun nowIso(): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date())

    /** `yyyy-MM-dd`，与 App 里 `Store.expense` 存 `spentAt` 的格式一致。 */
    fun isoDate(date: Date): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(date)
}
