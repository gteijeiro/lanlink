#!/usr/bin/env python3
"""Install an already-built Linux bundle and native desktop file actions."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle', type=Path, default=Path('build/linux/x64/release/bundle'))
args = parser.parse_args()
source = args.bundle.resolve()
if not (source / 'lanlink').is_file():
    parser.error('Primero compilá con flutter build linux --release o indicá --bundle.')
root = Path.home() / '.local'
target = root / 'opt/lanlink'
target.mkdir(parents=True, exist_ok=True)
shutil.copytree(source, target, dirs_exist_ok=True)
executable = target / 'lanlink'
executable.chmod(executable.stat().st_mode | 0o100)
# Desktop Entry quoting is not shell interpolation: pass user-selected files as %F.
quoted = '"' + str(executable).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"'
entry = f'''[Desktop Entry]
Type=Application
Name=LanLink
Comment=Compartir archivos con equipos cercanos
Exec={quoted} %F
Icon=network-transmit-receive
Terminal=false
Categories=Network;FileTransfer;
MimeType=application/octet-stream;image/jpeg;image/png;image/heic;video/mp4;video/quicktime;application/pdf;
'''
for relative in ['share/applications/com.example.lanlink.desktop', 'share/Thunar/sendto/lanlink.desktop']:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(entry)
service = root / 'share/kio/servicemenus/lanlink.desktop'
service.parent.mkdir(parents=True, exist_ok=True)
service.write_text(f'''[Desktop Entry]
Type=Service
MimeType=application/octet-stream;
Actions=share;
X-KDE-Priority=TopLevel
[Desktop Action share]
Name=Compartir con LanLink
Icon=network-transmit-receive
Exec={quoted} %F
''')
# Nautilus Scripts has a supported per-user folder; no Python extension required.
nautilus = root / 'share/nautilus/scripts/Compartir con LanLink'
nautilus.parent.mkdir(parents=True, exist_ok=True)
nautilus.write_text('#!/usr/bin/env python3\nimport os,subprocess\npaths=os.environ.get("NAUTILUS_SCRIPT_SELECTED_FILE_PATHS", "").splitlines()\nif paths: subprocess.Popen([' + repr(str(executable)) + ', *paths],start_new_session=True)\n')
nautilus.chmod(0o755)
if shutil.which('update-desktop-database'):
    subprocess.run(['update-desktop-database', str(root / 'share/applications')], check=False)
print('LanLink instalado. Usá Abrir con / Enviar a / Scripts según tu escritorio.')
