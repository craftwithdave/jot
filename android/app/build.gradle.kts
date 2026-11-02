plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.jot"
    compileSdk = 35
    buildToolsVersion = "35.0.0"
    defaultConfig {
        applicationId = "app.jot"
        minSdk = 26
        targetSdk = 35
        versionCode = file("../version.txt").readText().trim().toInt()
        versionName = "1.$versionCode"
        ndk { abiFilters += "arm64-v8a" }   // keeps the APK small (add more ABIs for older phones)
        // The ONLY server this app ever talks to: JOT_ORIGIN (build.sh reads it from origin.txt), e.g. https://notes.example.com
        val origin = System.getenv("JOT_ORIGIN")?.takeIf { it.isNotBlank() } ?: error("JOT_ORIGIN is not set (the notes server address)")
        buildConfigField("String", "ORIGIN", "\"$origin\"")
    }
    signingConfigs {
        create("release") {
            storeFile = file("/keys/keystore.jks")
            storePassword = System.getenv("KS_PASS")
            keyAlias = "jot"
            keyPassword = System.getenv("KS_PASS")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        dex.useLegacyPackaging = false   // store code uncompressed so update patches only carry what changed (see mkpatch.py)
    }
    lint { checkReleaseBuilds = false }
    dependenciesInfo { includeInApk = false; includeInBundle = false }   // no Google-signed dependency metadata blob
}

dependencies {
    val bom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(bom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
