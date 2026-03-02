allprojects {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}

val yandexMapkitVersion = "4.19.0-full"

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
    configurations.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "com.yandex.android" &&
                requested.name == "maps.mobile"
            ) {
                useVersion(yandexMapkitVersion)
                because("maps.mobile 4.22.0-full requires Java 21 bytecode; the project ships on Java 17")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
