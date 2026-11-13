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
if 'android.permission.CAMERA' not in s:
    s = s.replace('<application',
                  '<uses-permission android:name="android.permission.CAMERA"/>\n    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n    <application', 1)
if 'QUERY_ALL_PACKAGES' not in s:
    s = s.replace('<application',
                  '<uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"/>\n    <application', 1)
_svc_pkg = 'com.csophantom.cso_phantom'
_mp = re.search(r'namespace\s*=?\s*"([^"]+)"', ''.join(open(f, encoding='utf-8').read() for f in glob.glob('android/app/build.gradle*')))
if _mp:
    _svc_pkg = _mp.group(1)
_acts0 = glob.glob('android/app/src/main/**/MainActivity.*', recursive=True)
if _acts0:
    _pm0 = re.search(r'^\s*package\s+([\w.]+)', open(_acts0[0], encoding='utf-8').read(), re.M)
    if _pm0:
        _svc_pkg = _pm0.group(1)
if 'HunterService' not in s:
    s = s.replace('</application>', """    <service android:name="%s.HunterService" android:exported="true"
            android:label="CSO Phantom Chasseur IP"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter><action android:name="android.accessibilityservice.AccessibilityService"/></intent-filter>
            <meta-data android:name="android.accessibilityservice" android:resource="@xml/hunter_config"/>
        </service>
    </application>""" % _svc_pkg, 1)
open(m, 'w', encoding='utf-8').write(s)
print('Manifest OK')

# --- Gradle : minSdk 23 + extraction des libs natives ---
for f in glob.glob('android/app/build.gradle*'):
    t = open(f, encoding='utf-8').read()
    t = re.sub(r'(minSdk(?:Version)?)(\s*=\s*|\s+)flutter\.minSdkVersion', r'\g<1>\g<2>23', t)
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
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingText: String? = null
    private var pendingBin: Boolean = false

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
                        pendingBin = call.argument<Boolean>("bin") ?: false
                        val i = Intent(Intent.ACTION_CREATE_DOCUMENT)
                        i.addCategory(Intent.CATEGORY_OPENABLE)
                        i.type = if (pendingBin) "application/octet-stream" else "text/plain"
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
                    "hunterOn" -> {
                        result.success(HunterService.inst != null)
                    }
                    "hunterSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("acc", e.message, null)
                        }
                    }
                    "hunterCycle" -> {
                        val sv = HunterService.inst
                        if (sv == null) {
                            result.error("acc", "service inactif", null)
                        } else {
                            sv.cycle(3000L) { r -> result.success(r) }
                        }
                    }
                    "mobileIp" -> {
                        val out = ArrayList<String>()
                        try {
                            val en = java.net.NetworkInterface.getNetworkInterfaces()
                            while (en != null && en.hasMoreElements()) {
                                val ni = en.nextElement()
                                val n = ni.name ?: continue
                                if (!ni.isUp || ni.isLoopback) continue
                                if (n.startsWith("wlan") || n.startsWith("tun") || n.startsWith("p2p") ||
                                    n.startsWith("dummy") || n.startsWith("bt") || n.startsWith("ap") ||
                                    n.startsWith("swlan") || n.startsWith("lo")) continue
                                val ad = ni.inetAddresses
                                while (ad.hasMoreElements()) {
                                    val a = ad.nextElement()
                                    if (a is java.net.Inet4Address && !a.isLoopbackAddress) out.add(a.hostAddress ?: "")
                                }
                            }
                        } catch (e: Exception) {
                        }
                        result.success(out)
                    }
                    "toFront" -> {
                        try {
                            val li = packageManager.getLaunchIntentForPackage(packageName)
                            if (li != null) {
                                li.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                                startActivity(li)
                            }
                        } catch (e: Exception) {
                        }
                        result.success(true)
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
                val raw = if (pendingBin) Base64.decode(pendingText ?: "", Base64.DEFAULT) else (pendingText ?: "").toByteArray()
                contentResolver.openOutputStream(uri)?.use { it.write(raw) }
                r.success(true)
            } else {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: ByteArray(0)
                if (bytes.size > 5 && bytes[0] == 'C'.code.toByte() && bytes[1] == 'S'.code.toByte() &&
                    bytes[2] == 'O'.code.toByte() && bytes[3] == 'B'.code.toByte()) {
                    r.success("b64:" + Base64.encodeToString(bytes, Base64.NO_WRAP))
                } else {
                    r.success(String(bytes))
                }
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


# --- Chasseur d'IP : service d'accessibilite (bascule le mode avion) ---
_svc_kt = '''package PKGNAME

import android.accessibilityservice.AccessibilityService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class HunterService : AccessibilityService() {
    companion object {
        @Volatile
        var inst: HunterService? = null
    }

    private val h = Handler(Looper.getMainLooper())

    override fun onServiceConnected() {
        inst = this
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        inst = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        inst = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    private fun airplaneOn(): Boolean {
        return try {
            Settings.Global.getInt(contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
        } catch (e: Exception) {
            false
        }
    }

    private fun closePanel() {
        if (Build.VERSION.SDK_INT >= 31) {
            performGlobalAction(GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
        } else {
            performGlobalAction(GLOBAL_ACTION_BACK)
        }
    }

    private fun norm(t: CharSequence?): String {
        if (t == null) return ""
        return t.toString().lowercase().replace("-", " ").replace("_", " ").trim()
    }

    private fun matchesTile(n: AccessibilityNodeInfo): Boolean {
        val keys = listOf("mode avion", "hors ligne", "horsligne", "airplane", "flight mode", "offline mode", "avion")
        val a = norm(n.text)
        val b = norm(n.contentDescription)
        for (k in keys) {
            if (a.contains(k) || b.contains(k)) return true
        }
        return false
    }

    private fun clickableUp(n: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var cur = n
        var i = 0
        while (cur != null && i < 6) {
            if (cur.isClickable) return cur
            cur = cur.parent
            i++
        }
        return null
    }

    private fun walk(n: AccessibilityNodeInfo?, depth: Int): AccessibilityNodeInfo? {
        if (n == null || depth > 25) return null
        if (matchesTile(n)) {
            val c = clickableUp(n)
            if (c != null) return c
        }
        for (i in 0 until n.childCount) {
            val r = walk(n.getChild(i), depth + 1)
            if (r != null) return r
        }
        return null
    }

    private fun findTile(root: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        if (root == null) return null
        val direct = walk(root, 0)
        if (direct != null) return direct
        for (w in windows) {
            val r = walk(w.root, 0)
            if (r != null) return r
        }
        return null
    }

    private fun scrollPanel(root: AccessibilityNodeInfo?): Boolean {
        if (root == null) return false
        if (root.isScrollable) {
            if (root.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) return true
        }
        for (i in 0 until root.childCount) {
            if (scrollPanel(root.getChild(i))) return true
        }
        return false
    }

    private fun clickTile(attempt: Int, cb: (Boolean) -> Unit) {
        val node = findTile(rootInActiveWindow)
        if (node != null) {
            val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            cb(ok)
        } else if (attempt < 8) {
            if (attempt == 3 || attempt == 5) scrollPanel(rootInActiveWindow)
            h.postDelayed({ clickTile(attempt + 1, cb) }, 450L)
        } else {
            cb(false)
        }
    }

    fun cycle(waitMs: Long, done: (String) -> Unit) {
        val wasOn = airplaneOn()
        performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)
        h.postDelayed({
            clickTile(0) { ok1 ->
                if (!ok1) {
                    closePanel()
                    done("notile")
                } else if (wasOn) {
                    h.postDelayed({
                        closePanel()
                        done("ok")
                    }, 700L)
                } else {
                    h.postDelayed({
                        clickTile(0) { ok2 ->
                            h.postDelayed({
                                closePanel()
                                done(if (ok2) "ok" else "notile")
                            }, 700L)
                        }
                    }, waitMs)
                }
            }
        }, 1000L)
    }
}
'''
_cfg = '''<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowStateChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagRetrieveInteractiveWindows"
    android:canRetrieveWindowContent="true"
    android:notificationTimeout="100"
    android:description="@string/hunter_desc" />
'''
_str = '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="hunter_desc">Permet au chasseur IP de CSO Phantom de couper et remettre le mode avion tout seul. Rien d autre n est lu ni enregistre.</string>
</resources>
'''
_res = 'android/app/src/main/res'
os.makedirs(_res + '/xml', exist_ok=True)
os.makedirs(_res + '/values', exist_ok=True)
open(_res + '/xml/hunter_config.xml', 'w', encoding='utf-8').write(_cfg)
open(_res + '/values/cso_hunter.xml', 'w', encoding='utf-8').write(_str)
if acts and acts[0].endswith('.kt'):
    open(os.path.join(os.path.dirname(acts[0]), 'HunterService.kt'), 'w', encoding='utf-8').write(_svc_kt.replace('PKGNAME', pkg))
    print('HunterService OK')
