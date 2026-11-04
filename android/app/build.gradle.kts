plugins {
    id("com.android.application")
}

base.archivesName.set("DubbingPrompter")

android {
    namespace = "ru.dubbing.prompter"
    compileSdk = 36

    defaultConfig {
        applicationId = "ru.dubbing.prompter"
        minSdk = 26
        targetSdk = 36
        versionCode = 5
        versionName = "1.4.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
