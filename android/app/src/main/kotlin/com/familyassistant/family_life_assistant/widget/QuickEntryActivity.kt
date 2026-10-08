package com.familyassistant.family_life_assistant.widget

import android.app.Activity
import android.app.DatePickerDialog
import android.content.Context
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.familyassistant.family_life_assistant.R
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * 桌面组件点开后的**就地录入浮层**。
 *
 * ## 为什么是原生 Activity 而不是 Flutter 页面
 *
 * 用户明确要「直接在桌面弹小窗输入（最快）」。走 Flutter 就得等引擎冷启动
 * （实测量级是几百毫秒到一秒多），而用户点桌面组件的全部理由就是快。
 * 原生浮层从点击到可输入通常在 100ms 内，观感是「键盘弹出来就好了」。
 *
 * 代价是**表单要写两遍**（Flutter 一份、原生一份），所以这里的字段与
 * `lib/pages/expense_form.dart` / `lib/pages/med_form.dart` 严格对应，
 * 且**字段名直接用 App 的字段名**（见 [WidgetBridge] 的 KEY_* 常量），
 * 同步时不需要任何翻译表 —— 翻译表一改字段就会漂移，而漂移的表现是
 * 「记了但字段是空的」，属于静默丢数据。
 *
 * ## 它不直接写数据库
 *
 * 只把记录追加到 [WidgetBridge.QUEUE_FILE]，由 App 下次启动/回到前台时入库。
 * 为什么不直接写 sqflite：数据库结构属于 Flutter 侧（迁移、schemaVersion 都在那边），
 * 原生直接 INSERT 等于绕过所有迁移逻辑；一旦哪次升级加了列，原生那条 INSERT
 * 就会开始失败，而失败发生在**用户看不见的后台**。走队列则：数据先落盘不会丢，
 * 入库统一由 Dart 那套（有测试覆盖的）逻辑做。
 *
 * ## 视觉
 * `windowIsTranslucent` + 半透明黑遮罩 + 底部白卡片，效果等同 App 内的
 * `showModalBottomSheet`。点遮罩关闭；系统返回键也关闭（不会误保存）。
 */
class QuickEntryActivity : Activity() {

    private lateinit var kind: WidgetKind
    private var isIncome = false

    /** 选中的分类。默认与 App 内一致：'餐饮'。 */
    private var category = DEFAULT_CATEGORY

    /** 选中的单位。 */
    private var unit = "盒"

    private var pickedDate: Date = Date()

    private lateinit var categoryChips: LinearLayout
    private val categoryViews = mutableListOf<TextView>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        kind = WidgetKind.fromId(intent.getStringExtra(WidgetRenderer.EXTRA_WIDGET_KIND))
            ?: WidgetKind.EXPENSE

        // 浮层：背景透出桌面。必须放在 setContentView 之前。
        window.setBackgroundDrawableResource(android.R.color.transparent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+ 会强制给 Activity 加不透明底色，必须显式关掉，
            // 否则「透明浮层」会变成一块黑底，完全盖住桌面。
            window.setDimAmount(0f)
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.setDimAmount(0.45f)
        // 软键盘弹出时调整而不是遮住输入框
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)

        setContentView(if (kind.isExpense) R.layout.quick_expense else R.layout.quick_med)

        applyInsets()
        bindChrome()
        if (kind.isExpense) bindExpense() else bindMed()
    }

    /**
     * 让卡片避开状态栏与导航栏。
     *
     * 浮层是全屏透明的，卡片贴在屏幕底部；不处理 insets 的话，在有手势条的
     * 机器上「保存」按钮会被系统手势区压住，点不到 —— 这是那种「在开发机上
     * 看着没事、换台手机就废掉」的问题。
     */
    private fun applyInsets() {
        val card = findViewById<View>(R.id.quick_card) ?: return
        val basePadding = card.paddingBottom
        card.setOnApplyWindowInsetsListener { view, insets ->
            @Suppress("DEPRECATION")
            val bottom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                insets.getInsets(android.view.WindowInsets.Type.systemBars()).bottom
            } else {
                insets.systemWindowInsetBottom
            }
            view.setPadding(
                view.paddingLeft,
                view.paddingTop,
                view.paddingRight,
                basePadding + bottom,
            )
            insets
        }
        card.requestApplyInsets()
    }

    /** 遮罩点击、取消、标题等与记账/记药共用的部分。 */
    private fun bindChrome() {
        findViewById<View>(R.id.quick_backdrop)?.setOnClickListener { finish() }
        findViewById<View>(R.id.quick_cancel)?.setOnClickListener { finish() }
        findViewById<TextView>(R.id.quick_title)?.setText(
            if (kind.isExpense) R.string.quick_expense_title else R.string.quick_med_title,
        )
        findViewById<TextView>(R.id.quick_hint)?.setText(
            if (kind.isExpense) R.string.quick_expense_hint else R.string.quick_med_hint,
        )
    }

    // ------------------------------------------------------------------ 记账

    private fun bindExpense() {
        val typeExpense = findViewById<TextView>(R.id.quick_type_expense)
        val typeIncome = findViewById<TextView>(R.id.quick_type_income)
        fun renderType() {
            styleToggle(typeExpense, selected = !isIncome)
            styleToggle(typeIncome, selected = isIncome)
        }
        typeExpense.setOnClickListener { isIncome = false; renderType() }
        typeIncome.setOnClickListener { isIncome = true; renderType() }
        renderType()

        val amount = findViewById<EditText>(R.id.quick_amount)
        amount.requestFocus()

        // 金额立刻可输入：键盘自动弹出是「快」的关键一步。
        // 放在 post 里是因为窗口还没完全 attach 时 showSoftInput 会静默失败。
        amount.post {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE)
                as? android.view.inputmethod.InputMethodManager
            imm?.showSoftInput(amount, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
        }

        categoryChips = findViewById(R.id.quick_categories)
        buildCategoryChips()

        val date = findViewById<TextView>(R.id.quick_date)
        renderDate(date)
        date.setOnClickListener { pickDate(date) }

        findViewById<View>(R.id.quick_save).setOnClickListener {
            saveExpense(amount)
        }
    }

    /** 渲染分类胶囊。分类清单与 App 的 `Categories.all` **逐项一致**。 */
    private fun buildCategoryChips() {
        categoryViews.clear()
        categoryChips.removeAllViews()
        var row: LinearLayout? = null
        CATEGORIES.forEachIndexed { index, name ->
            if (index % CHIPS_PER_ROW == 0) {
                row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    layoutParams = LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                    ).apply { topMargin = if (index == 0) 0 else dp(8) }
                }
                categoryChips.addView(row)
            }
            val chip = TextView(this).apply {
                text = name
                textSize = 14f
                gravity = Gravity.CENTER
                setPadding(dp(14), dp(8), dp(14), dp(8))
                setOnClickListener {
                    category = name
                    renderCategoryChips()
                }
            }
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { marginEnd = dp(8) }
            row?.addView(chip, lp)
            categoryViews.add(chip)
        }
        renderCategoryChips()
    }

    private fun renderCategoryChips() {
        CATEGORIES.forEachIndexed { index, name ->
            val view = categoryViews.getOrNull(index) ?: return@forEachIndexed
            val selected = name == category
            view.setBackgroundResource(
                if (selected) R.drawable.quick_chip_selected else R.drawable.quick_chip_normal,
            )
            view.setTextColor(
                if (selected) Color.parseColor("#1B7F79") else Color.parseColor("#52606D"),
            )
        }
    }

    private fun renderDate(view: TextView) {
        val fmt = SimpleDateFormat("yyyy 年 M 月 d 日", Locale.CHINA)
        val today = isSameDay(pickedDate, Date())
        view.text = fmt.format(pickedDate) + if (today) "（今天）" else ""
    }

    private fun pickDate(target: TextView) {
        val cal = Calendar.getInstance().apply { time = pickedDate }
        DatePickerDialog(
            this,
            { _, year, month, day ->
                val next = Calendar.getInstance().apply {
                    time = pickedDate
                    set(Calendar.YEAR, year)
                    set(Calendar.MONTH, month)
                    set(Calendar.DAY_OF_MONTH, day)
                }
                pickedDate = next.time
                renderDate(target)
            },
            cal.get(Calendar.YEAR),
            cal.get(Calendar.MONTH),
            cal.get(Calendar.DAY_OF_MONTH),
        ).show()
    }

    private fun saveExpense(amountField: EditText) {
        val raw = amountField.text?.toString()?.trim().orEmpty()
        val value = parseAmount(raw)
        if (value == null) {
            toast(getString(R.string.quick_err_amount))
            return
        }
        if (value == 0.0) {
            toast(getString(R.string.quick_err_amount_zero))
            return
        }
        val title = findViewById<EditText>(R.id.quick_name)
            .text?.toString()?.trim().orEmpty()
        val note = findViewById<EditText>(R.id.quick_note)
            .text?.toString()?.trim().orEmpty()

        val record = JSONObject().apply {
            put(WidgetBridge.KEY_KIND, WidgetBridge.KIND_EXPENSE)
            // 名称留空时用分类兜底 —— 与 App 内 `_submit` 完全一致，
            // 否则账本里会出现一堆没有名字的记录。
            put(WidgetBridge.KEY_TITLE, title.ifEmpty { category })
            put(WidgetBridge.KEY_AMOUNT, value)
            put(WidgetBridge.KEY_CATEGORY, category)
            put(WidgetBridge.KEY_NOTE, note)
            put(
                WidgetBridge.KEY_ENTRY_TYPE,
                if (isIncome) "income" else "expense",
            )
            put(WidgetBridge.KEY_SPENT_AT, WidgetBridge.isoDate(pickedDate))
        }
        WidgetBridge.append(this, record)
        finishWithToast(getString(R.string.quick_saved_expense))
    }

    // ------------------------------------------------------------------ 记药

    private fun bindMed() {
        val name = findViewById<EditText>(R.id.quick_name)
        name.requestFocus()
        name.post {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE)
                as? android.view.inputmethod.InputMethodManager
            imm?.showSoftInput(name, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
        }

        val stock = findViewById<EditText>(R.id.quick_stock)
        stock.setText("1")
        // 光标放到末尾，且默认值全选 —— 用户直接输入就是替换掉「1」，
        // 不用先删。这是「多按几次退格」和「直接打字」的区别。
        stock.setSelection(stock.text.length)

        buildUnitChips()

        val expiry = findViewById<EditText>(R.id.quick_expiry)
        // 日期键盘（带数字与分隔符），便于快速输入「2027-06-30」。
        // 用 TYPE_DATETIME_VARIATION_DATE 而不是 VARIADIC —— 后者不存在，
        // 我第一版就写错了这个常量名，Kotlin 编译直接报 Unresolved reference。
        expiry.inputType = InputType.TYPE_CLASS_DATETIME or
            InputType.TYPE_DATETIME_VARIATION_DATE

        findViewById<View>(R.id.quick_save).setOnClickListener {
            saveMed(name, stock, expiry)
        }
    }

    private fun buildUnitChips() {
        val container = findViewById<LinearLayout>(R.id.quick_units)
        val views = mutableListOf<TextView>()
        fun render() {
            UNITS.forEachIndexed { index, label ->
                val view = views.getOrNull(index) ?: return@forEachIndexed
                val selected = label == unit
                view.setBackgroundResource(
                    if (selected) R.drawable.quick_chip_selected
                    else R.drawable.quick_chip_normal,
                )
                view.setTextColor(
                    if (selected) Color.parseColor("#1B7F79") else Color.parseColor("#52606D"),
                )
            }
        }
        UNITS.forEach { label ->
            val chip = TextView(this).apply {
                text = label
                textSize = 14f
                gravity = Gravity.CENTER
                setPadding(dp(12), dp(8), dp(12), dp(8))
                setOnClickListener { unit = label; render() }
            }
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { marginEnd = dp(6) }
            container.addView(chip, lp)
            views.add(chip)
        }
        render()
    }

    private fun saveMed(name: EditText, stock: EditText, expiry: EditText) {
        val medName = name.text?.toString()?.trim().orEmpty()
        if (medName.isEmpty()) {
            toast(getString(R.string.quick_err_name))
            return
        }
        val count = stock.text?.toString()?.trim()?.toIntOrNull()
        if (count == null || count < 0) {
            toast(getString(R.string.quick_err_stock))
            return
        }

        val spec = findViewById<EditText>(R.id.quick_spec)
            .text?.toString()?.trim().orEmpty()
        val storage = findViewById<EditText>(R.id.quick_storage)
            .text?.toString()?.trim().orEmpty()

        val record = JSONObject().apply {
            put(WidgetBridge.KEY_KIND, WidgetBridge.KIND_MED)
            put(WidgetBridge.KEY_NAME, medName)
            put(WidgetBridge.KEY_SPEC, spec)
            put(WidgetBridge.KEY_STOCK, count)
            put(WidgetBridge.KEY_EXPIRY, expiry.text?.toString()?.trim().orEmpty())
            put(WidgetBridge.KEY_STORAGE, storage)
            // ⚠️ `unit`（盒/瓶/板…）**故意不写进记录**：App 的药品表没有单位列，
            // 硬塞进某个字段会污染数据语义。它只是一个输入辅助，帮用户想清楚
            // 「数量」填的是几盒还是几片。将来若给 meds 加 unit 列，
            // 这里和 lib/data/store.dart 的 `med()` 要一起改。
        }
        WidgetBridge.append(this, record)
        finishWithToast(getString(R.string.quick_saved_med))
    }

    // ------------------------------------------------------------------ 工具

    /**
     * 金额解析。与 Dart 侧 `parseAmount` 保持同样的宽容度：
     * 允许「12」「12.5」「12.50」，也允许前后空格；不允许负数与非法字符。
     *
     * 为什么不用 `toDoubleOrNull()` 直接搞定：`toDoubleOrNull` 认 `1e3`、认 `Infinity`
     * 这类用户根本不想输入的写法，写进账本会变成一条金额诡异的记录。
     */
    private fun parseAmount(raw: String): Double? {
        val cleaned = raw.replace("，", ".").replace(",", ".").trim()
        if (cleaned.isEmpty()) return null
        if (!Regex("^\\d+(\\.\\d{1,2})?$").matches(cleaned)) return null
        return cleaned.toDoubleOrNull()?.takeIf { it >= 0 && it < 1e9 }
    }

    private fun isSameDay(a: Date, b: Date): Boolean {
        val ca = Calendar.getInstance().apply { time = a }
        val cb = Calendar.getInstance().apply { time = b }
        return ca.get(Calendar.YEAR) == cb.get(Calendar.YEAR) &&
            ca.get(Calendar.DAY_OF_YEAR) == cb.get(Calendar.DAY_OF_YEAR)
    }

    private fun styleToggle(view: TextView, selected: Boolean) {
        view.setBackgroundResource(
            if (selected) R.drawable.quick_chip_selected else R.drawable.quick_chip_normal,
        )
        view.setTextColor(
            if (selected) Color.parseColor("#1B7F79") else Color.parseColor("#52606D"),
        )
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    /**
     * 提示 + 关闭。
     *
     * 用 `Toast` 而不是 `AlertDialog`：用户的目标是「记完就走」，
     * 再弹一个需要点确认的对话框等于多一次点击，与「快捷」相悖。
     * 提示本身就是「记成了」的确认，不需要用户操作。
     */
    private fun finishWithToast(message: String) {
        toast(message)
        finish()
    }

    companion object {
        /**
         * 分类清单，**与 App 的 `Categories.all` 逐项一致**。
         *
         * 为什么在这里抄一份而不是从 Dart 读：原生浮层必须在 App 引擎启动前
         * 就能画出来（这正是它快的原因），读 Dart 资源就得先起引擎。
         * 所以只能抄 —— 但抄的东西必须**被测试盯着**：
         * `test/widget_bridge_test.dart` 会解析这个文件并断言清单与
         * `Categories.all` 完全相同，两边不一致就红。
         */
        val CATEGORIES = listOf(
            "餐饮", "购物", "交通", "医疗", "娱乐", "日常",
            "教育", "住房", "通讯", "人情", "收入", "其他",
        )

        /** 单位选项。App 的药品表没有单位列，这里只是输入辅助。 */
        val UNITS = listOf("盒", "瓶", "板", "袋", "支", "片")

        const val DEFAULT_CATEGORY = "餐饮"
        const val CHIPS_PER_ROW = 4
    }
}
