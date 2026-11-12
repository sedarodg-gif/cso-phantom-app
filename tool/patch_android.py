import glob
import re

# --- AndroidManifest : libs natives, internet, nom de l'appli ---
m = 'android/app/src/main/AndroidManifest.xml'
s = open(m, encoding='utf-8').read()
if 'extractNativeLibs' not in s:
    s = s.replace('<application', '<application android:extractNativeLibs="true"', 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="CSO Phantom"', s, count=1)
if 'android.permission.INTERNET' not in s:
    s = s.replace('<application',
                  '<uses-permission android:name="android.permission.INTERNET"/>\n    <application', 1)
if 'QUERY_ALL_PACKAGES' not in s:
    s = s.replace('<application',
                  '<uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"/>\n    <application', 1)
# --- AdMob : identifiant de l'application, lu dans lib/ads_config.dart ---
try:
    cfg = open('lib/ads_config.dart', encoding='utf-8').read()
    mm = re.search(r"kAdmobAppId\s*=\s*'([^']+)'", cfg)
    app_id = mm.group(1) if mm else 'ca-app-pub-3940256099942544~3347511713'
except OSError:
    app_id = 'ca-app-pub-3940256099942544~3347511713'
if 'com.google.android.gms.ads.APPLICATION_ID' not in s:
    s = re.sub(r'(<application[^>]*>)',
               lambda x: x.group(1) + '\n        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="' + app_id + '"/>',
               s, count=1)
open(m, 'w', encoding='utf-8').write(s)
print('Manifest OK')

# --- Gradle : minSdk 24 + extraction des libs natives ---
for f in glob.glob('android/app/build.gradle*'):
    t = open(f, encoding='utf-8').read()
    t = re.sub(r'(minSdk(?:Version)?)(\s*=\s*|\s+)flutter\.minSdkVersion', r'\g<1>\g<2>24', t)
    if 'useLegacyPackaging' not in t:
        t = re.sub(r'android\s*\{',
                   'android {\n    packaging { jniLibs { useLegacyPackaging = true } }', t, count=1)
    open(f, 'w', encoding='utf-8').write(t)
    print('Gradle OK :', f)

# --- MainActivity : canal de partage natif "cso/share" ---
pkg = 'com.csophantom.cso_phantom'
try:
    mt = open(m, encoding='utf-8').read()
    mm = re.search(r'package="([^"]+)"', mt)
    if mm:
        pkg = mm.group(1)
except Exception:
    pass
acts = glob.glob('android/app/src/main/**/MainActivity.*', recursive=True)
if acts:
    act = acts[0]
    existing = open(act, encoding='utf-8').read()
    pm = re.search(r'^\s*package\s+([\w.]+)', existing, re.M)
    if pm:
        pkg = pm.group(1)
    kt = '''package %s

import android.app.Activity
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cso/share")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "share" -> {
                        val text = call.argument<String>("text") ?: ""
                        val i = Intent(Intent.ACTION_SEND)
                        i.type = "text/plain"
                        i.putExtra(Intent.EXTRA_TEXT, text)
                        startActivity(Intent.createChooser(i, "Partager CSO PHANTOM"))
                        result.success(true)
                    }
                    "saveFile" -> {
                        pending = result
                        pendingText = call.argument<String>("text") ?: ""
                        val i = Intent(Intent.ACTION_CREATE_DOCUMENT)
                        i.addCategory(Intent.CATEGORY_OPENABLE)
                        i.type = "text/plain"
                        i.putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "cso-phantom.txt")
                        startActivityForResult(i, 7001)
                    }
                    "openFile" -> {
                        pending = result
                        val i = Intent(Intent.ACTION_OPEN_DOCUMENT)
                        i.addCategory(Intent.CATEGORY_OPENABLE)
                        i.type = "*/*"
                        startActivityForResult(i, 7002)
                    }
                    "apps" -> {
                        try {
                            val pm = packageManager
                            val main = Intent(Intent.ACTION_MAIN, null)
                            main.addCategory(Intent.CATEGORY_LAUNCHER)
                            val seen = HashSet<String>()
                            val out = ArrayList<Map<String, String>>()
                            for (ri in pm.queryIntentActivities(main, 0)) {
                                val pkg = ri.activityInfo.packageName
                                if (pkg == packageName || !seen.add(pkg)) continue
                                out.add(mapOf("name" to ri.loadLabel(pm).toString(), "pkg" to pkg))
                            }
                            result.success(out)
                        } catch (e: Exception) {
                            result.error("apps", e.message, null)
                        }
                    }
                    "openVpnSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("vpn", e.message, null)
                        }
                    }
                    "deviceId" -> {
                        result.success(Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: "")
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7001 && requestCode != 7002) return
        val r = pending
        pending = null
        val uri = data?.data
        if (r == null) return
        if (resultCode != Activity.RESULT_OK || uri == null) {
            if (requestCode == 7001) r.success(false) else r.success(null)
            pendingText = null
            return
        }
        try {
            if (requestCode == 7001) {
                contentResolver.openOutputStream(uri)?.use { it.write((pendingText ?: "").toByteArray()) }
                r.success(true)
            } else {
                val txt = contentResolver.openInputStream(uri)?.use { String(it.readBytes()) } ?: ""
                r.success(txt)
            }
        } catch (e: Exception) {
            r.error("io", e.message, null)
        }
        pendingText = null
    }
}
''' % pkg
    if act.endswith('.kt'):
        open(act, 'w', encoding='utf-8').write(kt)
        print('MainActivity OK :', act)
    else:
        print('MainActivity non-Kotlin, partage via presse-papiers')
else:
    print('MainActivity introuvable, partage via presse-papiers')

# --- Icône de l'application ---
import os, shutil
for d in glob.glob('tool/icons/mipmap-*'):
    dest = os.path.join('android/app/src/main/res', os.path.basename(d))
    os.makedirs(dest, exist_ok=True)
    shutil.copy(os.path.join(d, 'ic_launcher.png'), os.path.join(dest, 'ic_launcher.png'))
    print('Icône :', dest)

# --- Écran de démarrage natif (Android < 12) ---
res = 'android/app/src/main/res'
os.makedirs(res + '/drawable', exist_ok=True)
shutil.copy('tool/splash/splash_img.jpg', res + '/drawable/splash_img.jpg')
xml = '''<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@android:color/black" />
    <item>
        <bitmap android:src="@drawable/splash_img" android:gravity="fill" />
    </item>
</layer-list>
'''
for f in glob.glob(res + '/drawable*/launch_background.xml'):
    open(f, 'w', encoding='utf-8').write(xml)
    print('Splash :', f)
