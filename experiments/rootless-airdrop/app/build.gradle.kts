plugins { id("com.android.application") }
android {
    namespace = "com.example.lanlink.airdropprobe"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.example.lanlink.airdropprobe"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1-experimental"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
