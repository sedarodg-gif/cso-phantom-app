import glob
import os
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
if 'POST_NOTIFICATIONS' not in s:
    s = s.replace('<application',
                  '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n    <application', 1)
if 'ConnectTileService' not in s:
    tile = ('<service android:name=".ConnectTileService" android:label="CSO Phantom" '
            'android:icon="@android:drawable/ic_lock_lock" android:exported="true" '
            'android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">'
            '<intent-filter><action android:name="android.service.quicksettings.action.QS_TILE"/></intent-filter>'
            '</service>')
    s = s.replace('</application>', '    ' + tile + '\n    </application>', 1)
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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingText: String? = null
    private var pendingAction: String? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        readAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        readAction(intent)
    }

    private fun readAction(i: Intent?) {
        val a = i?.action
        if (a == "cso.STOP") pendingAction = "stop"
        if (a == "cso.TOGGLE") pendingAction = "toggle"
    }

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
                    "notify" -> {
                        try {
                            val title = call.argument<String>("title") ?: "CSO Phantom"
                            val text = call.argument<String>("text") ?: ""
                            val since = call.argument<Number>("since")?.toLong() ?: System.currentTimeMillis()
                            val nm = getSystemService(android.content.Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
                            if (android.os.Build.VERSION.SDK_INT >= 26) {
                                nm.createNotificationChannel(
                                    android.app.NotificationChannel("cso_live", "CSO Phantom", android.app.NotificationManager.IMPORTANCE_LOW)
                                )
                            }
                            var fl = android.app.PendingIntent.FLAG_UPDATE_CURRENT
                            if (android.os.Build.VERSION.SDK_INT >= 23) fl = fl or android.app.PendingIntent.FLAG_IMMUTABLE
                            val open = Intent(this, MainActivity::class.java)
                            open.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                            val stop = Intent(this, MainActivity::class.java)
                            stop.action = "cso.STOP"
                            stop.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                            val pi = android.app.PendingIntent.getActivity(this, 1, open, fl)
                            val spi = android.app.PendingIntent.getActivity(this, 2, stop, fl)
                            val b = if (android.os.Build.VERSION.SDK_INT >= 26) android.app.Notification.Builder(this, "cso_live") else android.app.Notification.Builder(this)
                            val ic = if (applicationInfo.icon != 0) applicationInfo.icon else android.R.drawable.stat_sys_download
                            b.setContentTitle(title)
                            b.setContentText(text)
                            b.setSmallIcon(ic)
                            b.setOngoing(true)
                            b.setOnlyAlertOnce(true)
                            b.setShowWhen(true)
                            b.setWhen(since)
                            b.setUsesChronometer(true)
                            b.setContentIntent(pi)
                            b.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Déconnecter", spi)
                            nm.notify(4242, b.build())
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "cancelNotif" -> {
                        try {
                            val nm = getSystemService(android.content.Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
                            nm.cancel(4242)
                        } catch (e: Exception) {
                        }
                        result.success(true)
                    }
                    "askNotif" -> {
                        try {
                            if (android.os.Build.VERSION.SDK_INT >= 33 &&
                                checkSelfPermission("android.permission.POST_NOTIFICATIONS") != android.content.pm.PackageManager.PERMISSION_GRANTED
                            ) {
                                requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 7003)
                            }
                        } catch (e: Exception) {
                        }
                        result.success(true)
                    }
                    "takeAction" -> {
                        val a = pendingAction
                        pendingAction = null
                        result.success(a)
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
        tile_kt = '''package %s

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class ConnectTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val t = qsTile
        if (t != null) {
            t.state = Tile.STATE_INACTIVE
            t.label = "CSO Phantom"
            t.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val i = Intent(this, MainActivity::class.java)
        i.action = "cso.TOGGLE"
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (Build.VERSION.SDK_INT >= 34) {
            val pi = PendingIntent.getActivity(this, 3, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            startActivityAndCollapse(pi)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(i)
        }
    }
}
''' % pkg
        open(os.path.join(os.path.dirname(act), 'ConnectTileService.kt'), 'w', encoding='utf-8').write(tile_kt)
        print('Tuile OK')
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
