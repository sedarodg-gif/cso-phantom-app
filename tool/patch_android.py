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
