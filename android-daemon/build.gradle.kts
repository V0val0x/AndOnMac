import java.io.File
import java.util.zip.ZipFile

plugins {
    kotlin("jvm") version "2.0.21"
}

group = "com.shadowgraph"
version = "1.0.0"

repositories {
    mavenCentral()
}

fun resolveAndroidSdkRoot(): File {
    val candidates = listOfNotNull(
        System.getenv("ANDROID_HOME"),
        System.getenv("ANDROID_SDK_ROOT"),
        File(System.getProperty("user.home"), "Library/Android/sdk").absolutePath
    )
    return candidates
        .map { File(it) }
        .firstOrNull { it.isDirectory }
        ?: throw GradleException(
            "Android SDK not found. Set ANDROID_HOME or install SDK at ~/Library/Android/sdk"
        )
}

fun resolveAndroidJar(sdkRoot: File): File {
    val platformsDir = File(sdkRoot, "platforms")
    val platformDirs = platformsDir.listFiles { f -> f.isDirectory && f.name.startsWith("android-") }
        ?.sortedByDescending { it.name.removePrefix("android-").toIntOrNull() ?: 0 }
        ?: emptyList()
    return platformDirs
        .map { File(it, "android.jar") }
        .firstOrNull { it.isFile }
        ?: throw GradleException("No android.jar found under ${platformsDir.absolutePath}")
}

fun resolveD8Executable(sdkRoot: File): File {
    val buildToolsDir = File(sdkRoot, "build-tools")
    val versions = buildToolsDir.listFiles { f -> f.isDirectory }
        ?.sortedWith(compareByDescending<File> {
            it.name.split(".").getOrNull(0)?.toIntOrNull() ?: 0
        }.thenByDescending {
            it.name.split(".").getOrNull(1)?.toIntOrNull() ?: 0
        }.thenByDescending {
            it.name.split(".").getOrNull(2)?.toIntOrNull() ?: 0
        })
        ?: emptyList()

    val isWindows = System.getProperty("os.name").lowercase().contains("win")
    val d8Name = if (isWindows) "d8.bat" else "d8"
    return versions
        .map { File(it, d8Name) }
        .firstOrNull { it.isFile }
        ?: throw GradleException("No d8 tool found under ${buildToolsDir.absolutePath}")
}

val androidSdkRoot = resolveAndroidSdkRoot()
val androidCompileJar = resolveAndroidJar(androidSdkRoot)
val d8Binary = resolveD8Executable(androidSdkRoot)

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

kotlin {
    jvmToolchain(17)
}

sourceSets {
    create("frameworkStubs") {
        java.srcDir("src/stubs/java")
    }
}

dependencies {
    "frameworkStubsCompileOnly"(files(androidCompileJar))

    compileOnly(files(androidCompileJar))
    compileOnly(sourceSets["frameworkStubs"].output)

    implementation(kotlin("stdlib"))

    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "skipped", "failed")
        showStandardStreams = false
    }
}

val fatJarFile = layout.buildDirectory.file("libs/android-daemon-fat.jar")
val distDexJarFile = layout.buildDirectory.file("dist/android-daemon.jar")

val fatJar = tasks.register<Jar>("fatJar") {
    group = "build"
    description = "Packages compiled classes and Kotlin stdlib into a single fat JAR (excluding Android framework stubs)."
    dependsOn(tasks.named("classes"))

    archiveFileName.set("android-daemon-fat.jar")
    destinationDirectory.set(layout.buildDirectory.dir("libs"))
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE

    manifest {
        attributes["Main-Class"] = "com.shadowgraph.daemon.DaemonMain"
    }

    from(sourceSets.main.get().output)
    from(
        configurations.runtimeClasspath.get().map { file ->
            if (file.isDirectory) file else zipTree(file)
        }
    )

    exclude(
        "META-INF/*.SF",
        "META-INF/*.DSA",
        "META-INF/*.RSA",
        "META-INF/versions/**",
        "META-INF/maven/**",
        "**/*.kotlin_metadata",
        "**/*.kotlin_builtins",
        "DebugProbesKt.bin"
    )
}

val dexJar = tasks.register<Exec>("dexJar") {
    group = "build"
    description = "Lowers android-daemon-fat.jar via Android SDK d8 into a single-DEX distribution JAR."
    dependsOn(fatJar)

    inputs.file(fatJarFile)
    outputs.file(distDexJarFile)

    doFirst {
        distDexJarFile.get().asFile.parentFile.mkdirs()
    }

    commandLine(
        d8Binary.absolutePath,
        "--release",
        "--min-api", "29",
        "--lib", androidCompileJar.absolutePath,
        "--output", distDexJarFile.get().asFile.absolutePath,
        fatJarFile.get().asFile.absolutePath
    )
}

val verifyDexArtifact = tasks.register("verifyDexArtifact") {
    group = "verification"
    description = "Verifies build/dist/android-daemon.jar contains classes.dex, zero .class files, and is under 2MB."
    dependsOn(dexJar)

    doLast {
        val outJar = distDexJarFile.get().asFile
        if (!outJar.isFile) {
            throw GradleException("Missing DEX artifact: ${outJar.absolutePath}")
        }
        val sizeBytes = outJar.length()
        val maxBytes = 2L * 1024L * 1024L
        if (sizeBytes > maxBytes) {
            throw GradleException("DEX artifact exceeds 2MB ceiling: $sizeBytes bytes > $maxBytes bytes")
        }

        var hasClassesDex = false
        val unexpectedEntries = mutableListOf<String>()
        ZipFile(outJar).use { zip ->
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                val name = entry.name
                if (name == "classes.dex") {
                    hasClassesDex = true
                } else if (name.endsWith(".class") || name.startsWith("android/") || name.startsWith("classes") && name.endsWith(".dex")) {
                    unexpectedEntries.add(name)
                }
            }
        }

        if (!hasClassesDex) {
            throw GradleException("classes.dex missing from ${outJar.absolutePath}")
        }
        if (unexpectedEntries.isNotEmpty()) {
            throw GradleException("Unexpected entries in DEX artifact (multi-dex or leaked classes): $unexpectedEntries")
        }

        val sizeKb = String.format("%.1f", sizeBytes / 1024.0)
        logger.lifecycle("Verified ${outJar.name}: classes.dex present, single-DEX, size=${sizeKb} KB ($sizeBytes bytes)")
    }
}

tasks.named("build") {
    dependsOn(verifyDexArtifact)
}
