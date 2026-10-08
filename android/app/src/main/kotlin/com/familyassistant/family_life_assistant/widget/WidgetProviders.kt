package com.familyassistant.family_life_assistant.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews
import com.familyassistant.family_life_assistant.MainActivity
import com.familyassistant.family_life_assistant.R
import org.json.JSONObject

/**
 * 桌面组件的四种形态。
 *
 * 用**一个枚举**承载四种组件的全部差异（标题、按钮文案、打开哪个表单、是否走 AI），
 * 而不是写四个几乎相同的 Provider 类。四个类会让「加一种组件要改四处、
 * 改一处样式要改四个文件」，那种重复必然会漏改。
 *
 * 新增第五种组件时只改这里 + 一份 `*_info.xml`，Provider 不用动。
 */
enum class WidgetKind(
    /** 写进 intent 的标识，**与 Dart 侧常量必须一致**。 */
    val id: String,
    val titleRes: Int,
    val actionRes: Int,
    /** 打开的浮层是记账还是记药。 */
    val isExpense: Boolean,
    /** true = AI 版：不弹原生表单，而是把用户丢进 App 的 AI 输入框。 */
    val isAi: Boolean,
) {
    EXPENSE(
        id = "expense",
        titleRes = R.string.widget_expense_title,
        actionRes = R.string.widget_action_expense,
        isExpense = true,
        isAi = false,
    ),
    EXPENSE_AI(
        id = "expense_ai",
        titleRes = R.string.widget_expense_ai_title,
        actionRes = R.string.widget_action_ai,
        isExpense = true,
        isAi = true,
    ),
    MED(
        id = "med",
        titleRes = R.string.widget_med_title,
        actionRes = R.string.widget_action_med,
        isExpense = false,
        isAi = false,
    ),
    MED_AI(
        id = "med_ai",
        titleRes = R.string.widget_med_ai_title,
        actionRes = R.string.widget_action_ai,
        isExpense = false,
        isAi = true,
    ),
    ;

    companion object {
        fun fromId(value: String?): WidgetKind? =
            entries.firstOrNull { it.id == value }
    }
}

/**
 * 组件刷新逻辑（四个 Provider 共用）。
 *
 * 抽成 object 而不是基类：`AppWidgetProvider` 是 BroadcastReceiver，
 * 系统按 manifest 里的类名反射实例化，继承层级越浅越好排查。
 */
object WidgetRenderer {

    /**
     * 重画所有该组件的实例。
     *
     * **这个方法绝不能抛异常**：`onUpdate` 里抛出去会被系统当成组件实现有 bug，
     * 把组件标成错误状态并反复重试，用户看到的是一个永远转圈的卡片。
     * 所以整体包了 try/catch，最差也只是显示占位文案。
     */
    fun updateAll(context: Context, manager: AppWidgetManager, kind: WidgetKind) {
        val ids = try {
            manager.getAppWidgetIds(
                android.content.ComponentName(context, providerClass(kind)),
            )
        } catch (_: Exception) {
            return
        }
        for (id in ids) {
            try {
                manager.updateAppWidget(id, buildViews(context, kind))
            } catch (_: Exception) {
                // 单个实例画失败不影响其它实例
            }
        }
    }

    /** 该组件对应的 Provider 类。 */
    fun providerClass(kind: WidgetKind): Class<*> = when (kind) {
        WidgetKind.EXPENSE -> ExpenseWidgetProvider::class.java
        WidgetKind.EXPENSE_AI -> ExpenseAiWidgetProvider::class.java
        WidgetKind.MED -> MedWidgetProvider::class.java
        WidgetKind.MED_AI -> MedAiWidgetProvider::class.java
    }

    private fun buildViews(context: Context, kind: WidgetKind): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_quick_entry)
        views.setTextViewText(R.id.widget_title, context.getString(kind.titleRes))
        views.setTextViewText(R.id.widget_action, context.getString(kind.actionRes))
        views.setTextViewText(R.id.widget_summary, summaryText(context, kind))

        // 整张卡片和底部按钮都可点：卡片面积大，用户多半会点正文而不是那个窄按钮。
        val intent = clickIntent(context, kind)
        views.setOnClickPendingIntent(R.id.widget_root, intent)
        views.setOnClickPendingIntent(R.id.widget_action, intent)
        return views
    }

    /**
     * 点击后要做的事。
     *
     * 两条分支（这是四个组件的核心差异）：
     *  · 普通版 → 打开 [QuickEntryActivity]：一个透明浮层，带字段与 App 内一致的表单，
     *    在桌面上就地记完，**不用等 App 冷启动**；
     *  · AI 版 → 打开 [MainActivity] 并带 `widget_ai_mode`：
     *    桌面组件里**没法放输入框**（RemoteViews 不支持 EditText），
     *    所以 AI 版只能落到 App 内的 AI 输入框。
     */
    private fun clickIntent(context: Context, kind: WidgetKind): PendingIntent {
        val intent = if (kind.isAi) {
            Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                putExtra(EXTRA_WIDGET_KIND, kind.id)
                putExtra(EXTRA_WIDGET_AI, true)
                // 从组件进来必须是「新任务」，否则会复用到后台已有的实例、
                // 结果只是把 App 切到前台，AI 输入框根本不弹。
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
        } else {
            Intent(context, QuickEntryActivity::class.java).apply {
                putExtra(EXTRA_WIDGET_KIND, kind.id)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
        }
        // requestCode 用 kind 区分：四个组件若共用同一个 requestCode，
        // PendingIntent 会被系统按「相同 intent」复用，导致点「记药」弹出记账表单。
        // 这类 bug 只在同时放了多个组件时才出现，极难联想到原因。
        val requestCode = kind.ordinal + 1
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** 汇总区文案。数据由 Flutter 写入，缺失时给占位提示而不是空白。 */
    private fun summaryText(context: Context, kind: WidgetKind): String {
        val summary: JSONObject = WidgetBridge.readSummary(context)
        val placeholder = context.getString(R.string.widget_summary_placeholder)
        if (summary.length() == 0) return placeholder

        return try {
            if (kind.isExpense) {
                val today = summary.optString("todayExpense", "")
                val count = summary.optInt("todayCount", 0)
                if (today.isEmpty()) placeholder
                else context.getString(R.string.widget_expense_summary_fmt, today, count)
            } else {
                val total = summary.optInt("medTotal", 0)
                val attention = summary.optInt("medAttention", 0)
                if (total == 0 && attention == 0) placeholder
                else context.getString(R.string.widget_med_summary_fmt, total, attention)
            }
        } catch (_: Exception) {
            placeholder
        }
    }

    const val EXTRA_WIDGET_KIND = "widget_kind"
    const val EXTRA_WIDGET_AI = "widget_ai"

    /** 这个 kind 是不是我们自己发出的。用于过滤 Intent 里的陌生值。 */
    fun isKnownKind(value: String?): Boolean = WidgetKind.fromId(value) != null

    /**
     * 请求把某个组件钉到桌面（Android 8.0+）。
     *
     * 系统会弹一个确认框，用户点确定就放上去了 —— 比让用户自己去「长按桌面 →
     * 小组件 → 翻列表找我们」快得多，而后者正是大多数用户放弃的地方。
     *
     * 返回 false 表示**这台设备/这个桌面不支持**，调用方应当退回文字说明，
     * 而不是假装成功。两种不支持的情况：
     *  · 系统低于 Android 8.0（`requestPinAppWidget` 是 API 26 才有的）；
     *  · 桌面（Launcher）没实现这个能力 —— `isRequestPinAppWidgetSupported()`
     *    会返回 false，华为/小米的某些桌面就是这样。
     *
     * ⚠️ 我**没有**在真机上验过所有厂商的桌面，所以这个方法必须容错：
     * 任何异常都吞掉并返回 false，让界面显示操作说明。桌面适配这种情况，
     * 宁可退化成「教用户手动加」也不能崩。
     */
    fun requestPin(context: Context, kind: WidgetKind): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val manager = AppWidgetManager.getInstance(context)
            if (!manager.isRequestPinAppWidgetSupported) return false
            val provider = android.content.ComponentName(context, providerClass(kind))
            manager.requestPinAppWidget(provider, null, null)
        } catch (_: Exception) {
            false
        }
    }
}

/**
 * 「记账」组件。
 *
 * 四个 Provider 都只做一件事：把 `onUpdate` 转给 [WidgetRenderer]。
 * 真正逻辑在那边，这里没有分支 —— 分支一多，四个类就会开始互相漂移。
 */
class ExpenseWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) = WidgetRenderer.updateAll(context, manager, WidgetKind.EXPENSE)
}

/** 「AI 记账」组件。 */
class ExpenseAiWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) = WidgetRenderer.updateAll(context, manager, WidgetKind.EXPENSE_AI)
}

/** 「记药」组件。 */
class MedWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) = WidgetRenderer.updateAll(context, manager, WidgetKind.MED)
}

/** 「AI 记药」组件。 */
class MedAiWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) = WidgetRenderer.updateAll(context, manager, WidgetKind.MED_AI)
}
