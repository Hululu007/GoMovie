# TVBox spider jar 由 DexClassLoader 在运行时加载，它们继承、调用的
# com.github.catvod.crawler.Spider 必须在 APK 里保留原名原签名，否则 R8
# 会把 stub 改名/抽掉，运行时抛：
#   Spider 执行失败: Class not found using the boot class loader
-keep class com.github.catvod.** { *; }
-keep interface com.github.catvod.** { *; }
-keepclassmembers class com.github.catvod.** { *; }
-dontwarn com.github.catvod.**

# 桥自身通过 MethodChannel 反射调用，保留入口
-keep class com.gomovie.SpiderBridge { *; }
-keep class com.gomovie.MainActivity { *; }
