plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.familyassistant.family_life_assistant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.familyassistant.family_life_assistant"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // ⚠️ 当前用 debug 密钥签 release 包 —— 这是**有意的临时状态，不是遗漏**。
            //
            // 为什么先这样：换正式签名需要产品负责人提供 keystore 文件与口令，
            // 开发方不能代生成并保管签名密钥（那把密钥丢失后，后续所有版本都无法
            // 覆盖升级，等于永久锁死更新通道）。
            //
            // 为什么必须**尽快决定**：Android 要求覆盖安装时签名一致。一旦有第二个
            // 人装了现在这个 debug 签名的包，将来换正式签名时他必须先卸载 —— 而卸载
            // 会清空本机账本、药箱、对话与密码记录。所以「先发出去、以后再换签名」
            // 这条路走不通。
            //
            // 只给自己用、只在一台设备上装：可以先不动。
            // 一旦要给第二个人装：先配好正式签名再分发。
            //
            // 配置方式：在 android/key.properties 放 storeFile / storePassword /
            // keyAlias / keyPassword（该文件不应纳入版本库），然后在这里读它并
            // 换成 signingConfigs.create("release")。
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
