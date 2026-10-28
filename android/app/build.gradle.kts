plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.davidchatting.pointsnorth"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.davidchatting.pointsnorth"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")      // WebSocket to the relay
    implementation("com.google.zxing:core:3.5.3")             // drawing QR codes
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0") // scanning them
}
