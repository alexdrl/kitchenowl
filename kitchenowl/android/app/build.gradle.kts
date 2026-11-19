import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.tombursch.kitchenowl"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.tombursch.kitchenowl"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        resourceConfigurations += listOf(
            "en", "ar", "be", "bg", "br", "ca", "ca_valencia", "cs", "da", "de",
            "de_CH", "efi", "el", "es", "et", "eu", "fa", "fi", "fr", "he", "hi",
            "hr", "hu", "id", "it", "ja", "kab", "kk", "ko", "lt", "lv", "nb",
            "nl", "pa", "pl", "pt", "pt_BR", "ro", "ru", "sk", "sl", "sr", "sv",
            "ta", "te", "tr", "uk", "vi", "zh", "zh_HANT"
        )
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            val storeFileProp = keystoreProperties["storeFile"] as String?
            storeFile = if (storeFileProp != null) file(storeFileProp) else null
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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

dependencies {
    // Wear OS bridge (WearBridge.kt, ../wear): the Wearable Data Layer, and WorkManager to run
    // the headless engine that applies the watch's actions while the app is closed.
    implementation("com.google.android.gms:play-services-wearable:19.0.0")
    implementation("androidx.work:work-runtime:2.12.0")
    implementation("androidx.concurrent:concurrent-futures:1.3.0")
}
