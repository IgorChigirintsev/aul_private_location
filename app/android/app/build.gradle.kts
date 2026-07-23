import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase (FCM background push). The config is PER-OPERATOR — Aul is
// self-hostable, so google-services.json is gitignored and each operator drops
// in their own Firebase project's file. Apply the plugin only when that file is
// actually present: a contributor cloning without a Firebase project still gets
// a building APK, just with push inert. Nothing is lost by that — Firebase
// initialization fails softly (see features/push/push_messaging.dart), token
// registration is skipped, and a server with fcm_enabled=false could not have
// delivered anything anyway.
val googleServicesJson = file("google-services.json")
if (googleServicesJson.exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.lifecycle(
        "Aul: android/app/google-services.json absent — building without FCM push. " +
            "Drop in your Firebase project's file to enable it.",
    )
}

// Optional release signing: create android/key.properties from key.properties.example
// (see docs/RELEASE.md). Falls back to debug signing when absent.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "app.aul.aul"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (uses java.time on older APIs).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.aul.aul"
        // minSdk 26 (spec §9): foreground service types, adaptive icons, java.time.
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Flutter shrinks release builds with R8. Anything resolved by name
            // at runtime must be kept explicitly — see proguard-rules.pro, which
            // exists because WorkManager's Room database was being renamed and
            // crashed the app on launch.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Debug keys so `flutter run --release` / CI dry-runs still work.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
