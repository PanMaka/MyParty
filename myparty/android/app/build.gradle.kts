plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Phase 7c. FCM needs the google-services plugin to turn google-services.json
// into the resources firebase_core reads at startup — and that plugin FAILS THE
// BUILD when the file is absent, with an error about a missing google-services
// configuration rather than anything a newcomer would connect to push.
//
// So it is applied conditionally. Without a Firebase project the app compiles
// and runs exactly as before, with PushService reporting push unavailable;
// dropping in the file from `flutterfire configure` switches it on with no code
// change and no edit to this file.
//
// This is not a hack around a missing setup step so much as the honest
// expression of a real dependency: push is optional at build time, because it is
// optional at RUN time too — an Android handset with no Play Services can never
// obtain a token, and the app has to work there regardless.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.lifecycle(
        "google-services.json not found — building without FCM. " +
        "Run `flutterfire configure` to enable push notifications."
    )
}

android {
    namespace = "com.example.myparty"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.myparty"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
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
