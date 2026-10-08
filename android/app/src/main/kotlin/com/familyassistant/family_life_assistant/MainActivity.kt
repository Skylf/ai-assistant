package com.familyassistant.family_life_assistant

import android.content.Intent
import com.familyassistant.family_life_assistant.widget.WidgetKind
import com.familyassistant.family_life_assistant.widget.WidgetRenderer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * App 主入口。
 *
 * 0.5.2 起它多了一件差事：**接住「AI 记账 / AI 记药」桌面组件传来的意图**。
 *
 * ## 为什么 AI 版组件要落到这里
 *
 * 普通版组件点开的是 [com.familyassistant.family_life_assistant.widget.QuickEntryActivity]
 * ——一个原生浮层，在桌面上就地填完，不等 App 冷启动。
 *
 * 但**桌面组件里放不了输入框**：RemoteViews 不支持 `EditText`（系统限制，
 * 不是我们没写）。所以「说一句话让 AI 帮你记」在桌面上没法完成，只能落到 App 里。
 * 这一点 0.4A 就定过调子：**不要让 App 用正则去解析人话，交给模型**；
 * 那套（`ActionPlan` + 服务端结构化动作）已经在聊天里跑通，组件只是把用户送到入口。
 *
 * ## 两条路径都必须覆盖
 *
 * · **冷启动**：App 没在跑 → 点组件 → `onCreate`，意图在 `intent` 里；
 * · **热启动**：App 在后台 → 点组件 → **`onNewIntent`**，`intent` 不会自己更新。
 *
 * 只处理其中一条是最常见的错：开发机上每次都是冷启动、一切正常，
 * 用户用了一整天、App 还在后台，点组件就什么也不发生。两条都接。
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null

    /** 待 Flutter 取走的组件请求。取走即清空，避免重复弹窗。 */
    private var pendingKind: String? = null
    private var pendingIsAi: Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 冷启动：意图在我们注册通道**之前**就送到了，先记下来。
        captureWidgetIntent(intent)

        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // Flutter 启动完成后来取「是哪个组件把我叫起来的」。
                    // 取走就清空：这个请求只该触发一次弹窗，否则用户每次
                    // 从后台切回来都会被再弹一次输入框。
                    "takeLaunchWidget" -> {
                        val kind = pendingKind
                        pendingKind = null
                        val isAi = pendingIsAi
                        pendingIsAi = false
                        if (kind == null) {
                            result.success(null)
                        } else {
                            result.success(mapOf("kind" to kind, "ai" to isAi))
                        }
                    }
                    // 设置页「添加到桌面」：请系统把组件钉上去。
                    // 返回 true = 系统已接受（会弹确认框）；false = 这台设备/
                    // 这个桌面不支持，界面应退回「手动添加」的说明。
                    "requestPinWidget" -> {
                        val kindId = call.argument<String>("kind")
                        val kind = WidgetKind.fromId(kindId)
                        if (kind == null) {
                            result.success(false)
                        } else {
                            // ⚠️ 这里必须是 `this@MainActivity`，不能写 `this`：
                            // 我们正处在 `channel.apply { ... }` 的接收者作用域里，
                            // 裸 `this` 指的是那个 MethodChannel（不是 Activity），
                            // 于是报「actual type is MethodChannel, but Context was expected」。
                            result.success(WidgetRenderer.requestPin(this@MainActivity, kind))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * 热启动：App 已在后台，系统复用实例并回调这里。
     *
     * 只有在 `singleTop` 启动模式下才会走到（见 AndroidManifest 里 MainActivity
     * 的 `launchMode`）；若改成 `standard`，系统会新建实例，这条永远不触发。
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 必须把新意图设为当前意图，否则后续 getIntent() 拿到的还是旧的那个。
        setIntent(intent)
        captureWidgetIntent(intent)
        // 通知 Flutter：它可能正开着，让它立刻处理这次点击。
        channel?.invokeMethod("widgetLaunch", null)
    }

    private fun captureWidgetIntent(intent: Intent?) {
        val kind = intent?.getStringExtra(WidgetRenderer.EXTRA_WIDGET_KIND) ?: return
        // 只认我们自己发出的意图；别的来源即使带了同名字段也不理会。
        if (!WidgetRenderer.isKnownKind(kind)) return
        pendingKind = kind
        pendingIsAi = intent.getBooleanExtra(WidgetRenderer.EXTRA_WIDGET_AI, false)
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }

    companion object {
        /**
         * 与 Dart 侧 `lib/data/widget_launch.dart` 的通道名**必须一致**。
         * 改名要两边一起改，否则表现是「点 AI 组件只是打开 App、不弹输入框」。
         */
        const val CHANNEL = "family_life_assistant/widget_launch"
    }
}
