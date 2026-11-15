#!/usr/bin/env python3
"""Independent, resumable deployment from this Mac. No model/API required."""
import argparse
import base64
import concurrent.futures
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_LOCK = threading.Lock()
PROMPT_LOCK = threading.Lock()


class DeploymentError(Exception):
    pass


class Skipped(DeploymentError):
    pass


class RetryLater(DeploymentError):
    pass


def valid_address(value):
    # Accept IPv4, bracketed IPv6, and local DNS names; never command options.
    return bool(re.fullmatch(r'(?:[A-Za-z0-9][A-Za-z0-9.-]*|\[[A-Fa-f0-9:%]+\]):[0-9]{1,5}', value)
                and 1 <= int(value.rsplit(':', 1)[1]) <= 65535)


def digest(path):
    with Path(path).open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def quote_ps(value):
    return "'" + str(value).replace("'", "''") + "'"


def retry_action(args, device, message):
    with PROMPT_LOCK:
        if args.non_interactive or not sys.stdin.isatty():
            return 'wait'
        answer = input(f'\n[{device}] {message}\n[r] reintentar, [e] esperar 15 s, [s] saltear: ').strip().lower()
        return {'s': 'skip', 'r': 'retry'}.get(answer, 'wait')


class Target:
    def __init__(self, name, args, head, version, build, logs, cache):
        self.name, self.args, self.head = name, args, head
        self.version, self.build = version, build
        self.logs, self.cache = logs, cache / name
        self.cache.mkdir(parents=True, exist_ok=True)
        self.log = logs / f'{name}.log'
        self.result = {'target': name, 'status': 'running', 'commit': head,
                       'version': version, 'build': build, 'log': str(self.log)}

    def say(self, message):
        with OUTPUT_LOCK:
            print(f'[{self.name}] {message}', flush=True)
            with self.log.open('a') as file:
                file.write(f'{dt.datetime.now().isoformat()} {message}\n')

    def run(self, command, cwd=None, timeout=300, env=None):
        self.say('$ ' + ' '.join(map(str, command[:4])) + (' …' if len(command) > 4 else ''))
        with self.log.open('a') as file:
            file.write('COMMAND ' + json.dumps(list(map(str, command))) + '\n')
        try:
            process = subprocess.Popen(list(map(str, command)), cwd=cwd or ROOT,
                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
            try:
                output, _ = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    output, _ = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    output, _ = process.communicate()
                raise DeploymentError(f'Tiempo agotado: {command[0]}\n{output[-2500:]}')
        except OSError as error:
            raise DeploymentError(str(error)) from error
        with self.log.open('a') as file:
            file.write(output + '\n')
        if process.returncode:
            raise DeploymentError(output[-4500:] or f'Exit {process.returncode}')
        return output

    def json_command(self, command, timeout=90):
        path = self.cache / 'device-result.json'
        path.unlink(missing_ok=True)
        self.run([*command, '--json-output', path], timeout=timeout)
        return json.loads(path.read_text())['result']

    def source(self):
        source = self.cache / 'source'
        if not source.exists():
            self.run(['git', 'clone', '--local', ROOT, source])
            self.run(['git', 'checkout', '--detach', self.head], cwd=source)
        if self.run(['git', 'rev-parse', 'HEAD'], cwd=source).strip() != self.head:
            raise DeploymentError('El checkout de compilación no coincide con el commit.')
        return source

    def flutter(self):
        candidates = [self.args.flutter, os.getenv('FLUTTER_BIN'), shutil.which('flutter'),
                      str(ROOT.parents[1] / 'work/flutter_sdk/bin/flutter')]
        for path in candidates:
            if path and Path(path).is_file():
                return str(Path(path).resolve())
        raise DeploymentError('No se encontró Flutter. Usá --flutter /ruta/bin/flutter.')

    def signing(self):
        identity = self.args.identity or os.getenv('LANLINK_MACOS_SIGNING_IDENTITY')
        listing = self.run(['security', 'find-identity', '-p', 'codesigning', '-v'])
        identities = re.findall(r'([A-F0-9]{40}) "Apple Development:[^\n]+', listing)
        if not identity:
            if len(identities) != 1:
                raise DeploymentError('Indicá --identity: falta una identidad única Apple Development.')
            identity = identities[0]
        if identity not in listing:
            raise DeploymentError('El certificado configurado no está disponible.')
        # Team is explicit or obtained from an already signed installed build.
        team = self.args.team or os.getenv('LANLINK_MACOS_TEAM_ID')
        if not team:
            signed = self.run(['codesign', '-dv', '--verbose=4', self.args.mac_app])
            match = re.search(r'TeamIdentifier=([A-Z0-9]{10})', signed)
            if not match:
                raise DeploymentError('Indicá --team con el equipo Apple.')
            team = match.group(1)
        return identity, team

    def manifest(self, artifact, **extra):
        record = {'commit': self.head, 'version': self.version, 'build': self.build, **extra}
        if Path(artifact).is_file():
            record['sha256'] = digest(artifact)
        (self.cache / 'artifact.json').write_text(json.dumps(record, indent=2))
        self.result['artifact'] = str(artifact)

    def valid_cache(self, artifact):
        record_path = self.cache / 'artifact.json'
        if not artifact.is_file() or not record_path.is_file():
            return False
        try:
            record = json.loads(record_path.read_text())
            return (record.get('commit') == self.head and record.get('version') == self.version
                    and record.get('build') == self.build and record.get('sha256') == digest(artifact))
        except (ValueError, OSError):
            return False

    def ci_artifact(self, workflow, artifact_name, filename):
        artifact = self.cache / filename
        manifest = self.cache / 'artifact.json'
        if artifact.exists() and manifest.exists():
            record = json.loads(manifest.read_text())
            if record.get('commit') == self.head and record.get('sha256') == digest(artifact):
                self.say('Reutilizando artefacto verificado del mismo commit.')
                self.result['artifact'] = str(artifact)
                return artifact
        remote = self.run(['git', 'ls-remote', 'origin', 'refs/heads/' + self.args.ref]).split()
        if not remote or remote[0] != self.head:
            raise DeploymentError('HEAD no coincide con la rama remota. Ejecutá git push antes de compilar en CI.')
        run_id = None
        dispatched = False
        deadline = time.monotonic() + self.args.build_timeout
        while time.monotonic() < deadline:
            runs = json.loads(self.run(['gh', 'run', 'list', '--workflow', workflow, '--limit', '50',
                                       '--json', 'databaseId,headSha,status,conclusion']))
            matches = [run for run in runs if run['headSha'] == self.head]
            success = next((run for run in matches if run['conclusion'] == 'success'), None)
            if success:
                run_id = success['databaseId']
                break
            active = next((run for run in matches if run['status'] != 'completed'), None)
            if active:
                self.say(f'Compilación GitHub {active["databaseId"]}: {active["status"]}')
                time.sleep(15)
                continue
            if matches:
                raise DeploymentError(f'La compilación {matches[0]["databaseId"]} falló. Revisá GitHub Actions; no se instala otra revisión.')
            if not dispatched:
                self.run(['gh', 'workflow', 'run', workflow, '--ref', self.args.ref])
                dispatched = True
            time.sleep(5)
        if not run_id:
            raise DeploymentError('Tiempo agotado esperando la compilación de GitHub.')
        # Downloads go into an empty folder to prevent accidental reuse.
        folder = Path(tempfile.mkdtemp(prefix='artifact-', dir=self.cache))
        try:
            self.run(['gh', 'run', 'download', run_id, '-n', artifact_name, '-D', folder], timeout=90)
        except DeploymentError:
            self.say('La descarga normal falló o demoró demasiado; recuperando por partes con verificación SHA256 de GitHub.')
            self.download_in_parts(run_id, artifact_name, filename, folder)
        shutil.copy2(folder / filename, artifact)
        self.manifest(artifact, run_id=run_id)
        return artifact

    def signed_artifact_url(self, artifact, context):
        # Never forward GitHub credentials to the artifact storage host or logs.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        api = urllib.parse.urlsplit(artifact['archive_download_url'])
        if api.scheme != 'https' or api.hostname != 'api.github.com':
            raise DeploymentError('La descarga alternativa requiere GitHub.com.')
        token = subprocess.run(['gh', 'auth', 'token', '--hostname', 'github.com'],
                               capture_output=True, text=True, timeout=20)
        if token.returncode or not token.stdout.strip():
            raise DeploymentError('No se pudo autorizar la descarga de GitHub.')
        opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=context))
        request = urllib.request.Request(artifact['archive_download_url'] + '?fresh=' + str(time.time_ns()),
                                        headers={'Authorization': 'Bearer ' + token.stdout.strip()})
        try:
            opener.open(request, timeout=30).close()
        except urllib.error.HTTPError as error:
            if error.code == 302:
                url = error.headers.get('Location', '')
                if urllib.parse.urlsplit(url).scheme == 'https':
                    return url
        except Exception:
            pass
        raise DeploymentError('GitHub no entregó una dirección válida para descargar el paquete.')

    def download_in_parts(self, run_id, artifact_name, filename, folder):
        repo = self.run(['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner']).strip()
        metadata = json.loads(self.run(['gh', 'api', f'repos/{repo}/actions/runs/{run_id}/artifacts']))
        matches = [item for item in metadata['artifacts'] if item['name'] == artifact_name and not item['expired']]
        if len(matches) != 1:
            raise DeploymentError('No se encontró un único paquete vigente en GitHub.')
        artifact = matches[0]
        expected = artifact.get('digest', '')
        if not re.fullmatch(r'sha256:[a-f0-9]{64}', expected):
            raise DeploymentError('GitHub no publicó una huella SHA256 para verificar la descarga alternativa.')
        # Python installations on macOS may omit the system certificate bundle.
        context = ssl.create_default_context(cafile='/etc/ssl/cert.pem' if Path('/etc/ssl/cert.pem').is_file() else None)
        url = self.signed_artifact_url(artifact, context)
        total, chunk = artifact['size_in_bytes'], 512 * 1024
        if not 0 < total <= 2 * 1024 ** 3:
            raise DeploymentError('Tamaño del paquete fuera de los límites de descarga.')
        parts = Path(tempfile.mkdtemp(prefix='parts-', dir=folder))
        deadline = time.monotonic() + 480

        def fetch(index):
            first, last = index * chunk, min(total - 1, (index + 1) * chunk - 1)
            for attempt in range(3):
                if time.monotonic() > deadline:
                    raise DeploymentError('Tiempo agotado recuperando el paquete de GitHub.')
                try:
                    request = urllib.request.Request(url, headers={'Range': f'bytes={first}-{last}'})
                    with urllib.request.urlopen(request, context=context, timeout=30) as response:
                        if response.status != 206 or response.headers.get('Content-Range') != f'bytes {first}-{last}/{total}':
                            raise ValueError('Rango incorrecto')
                        data = bytearray()
                        while len(data) < last - first + 1:
                            if time.monotonic() > deadline:
                                raise TimeoutError()
                            block = response.read(min(65536, last - first + 1 - len(data)))
                            if not block:
                                raise ValueError('Rango incompleto')
                            data.extend(block)
                    (parts / str(index)).write_bytes(data)
                    return len(data)
                except Exception:
                    if attempt == 2 or time.monotonic() > deadline:
                        raise DeploymentError(f'No se pudo descargar el bloque {index}; no se instala un paquete incompleto.') from None
                    time.sleep(2)
        count, received, last_percent = (total + chunk - 1) // chunk, 0, -10
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            futures = [pool.submit(fetch, index) for index in range(count)]
            for future in concurrent.futures.as_completed(futures):
                received += future.result()
                percent = received * 100 // total
                if percent >= last_percent + 10 or received == total:
                    self.say(f'Descarga por bloques: {percent}%')
                    last_percent = percent
        archive = parts / 'artifact.zip'
        with archive.open('wb') as output:
            for index in range(count):
                output.write((parts / str(index)).read_bytes())
        if 'sha256:' + digest(archive) != expected:
            raise DeploymentError('La descarga no coincide con la huella SHA256 de GitHub; no se instala.')
        with zipfile.ZipFile(archive) as zipped:
            with zipped.open(filename) as source, (folder / filename).open('wb') as output:
                shutil.copyfileobj(source, output)
        self.say('Paquete recuperado y SHA256 de GitHub verificado.')

    def wait(self, action, instruction):
        deadline = time.monotonic() + self.args.wait_timeout
        while True:
            try:
                return action()
            except Skipped:
                raise
            except DeploymentError as error:
                self.say(f'Esperando intervención: {instruction}\n{error}')
                if time.monotonic() >= deadline:
                    raise Skipped(f'Tiempo de espera agotado: {instruction}') from error
                choice = 'wait' if isinstance(error, RetryLater) else retry_action(self.args, self.name, instruction)
                if choice == 'skip':
                    raise Skipped(instruction) from error
                if choice == 'wait':
                    time.sleep(15)

    def macos(self):
        identity, team = self.signing()
        source = self.source()
        archive = self.cache / 'signed/LanLink-macOS-signed.zip'
        if archive.exists() and (self.args.rebuild or not self.valid_cache(archive)):
            archive.rename(archive.with_name(f'invalid-{int(time.time())}.zip'))
        if not archive.exists():
            env = dict(os.environ, FLUTTER_BIN=self.flutter(),
                       LANLINK_MACOS_SIGNING_IDENTITY=identity, LANLINK_MACOS_TEAM_ID=team,
                       LANLINK_MACOS_OUTPUT_DIR=str(archive.parent))
            self.run(['bash', source / 'scripts/build_macos_signed.sh'], cwd=source,
                     timeout=self.args.build_timeout, env=env)
        self.manifest(archive)
        stage = Path(tempfile.mkdtemp(prefix='lanlink-deploy-macos-'))
        self.run(['ditto', '-x', '-k', archive, stage])
        app = stage / 'lanlink.app'
        self.run(['codesign', '--verify', '--deep', '--strict', app])
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if (info['CFBundleIdentifier'] != 'com.example.lanlink' or info['CFBundleShortVersionString'] != self.version
                or str(info['CFBundleVersion']) != str(self.build)):
            raise DeploymentError('Identificador o versión del Mac incorrectos.')
        signature = self.run(['codesign', '-dv', '--verbose=4', app])
        if f'TeamIdentifier={team}' not in signature:
            raise DeploymentError('La firma del Mac pertenece a otro equipo.')
        if getattr(self.args, 'build_only', False):
            self.result.update(artifact=str(archive), verification='signature, team, bundle ID, version; not installed')
            shutil.rmtree(stage)
            return
        destination = Path(self.args.mac_app).expanduser().resolve()
        pending = destination.with_name(f'.LanLink-update-{int(time.time())}.app')
        self.run(['ditto', app, pending])
        self.run(['codesign', '--verify', '--deep', '--strict', pending])
        # Only stop this exact installed executable, preserving application data.
        probe = subprocess.run(['pgrep', '-f', '^' + re.escape(str(destination / 'Contents/MacOS/lanlink')) + '$'],
                               capture_output=True, text=True)
        for pid in probe.stdout.split():
            self.run(['kill', '-TERM', pid])
        time.sleep(1)
        backup = destination.with_name(f'.LanLink-previous-{int(time.time())}.app')
        existed = destination.exists()
        if existed:
            destination.rename(backup)
        try:
            pending.rename(destination)
            self.run(['open', destination])
            time.sleep(3)
            self.run(['pgrep', '-f', '^' + re.escape(str(destination / 'Contents/MacOS/lanlink')) + '$'])
        except Exception:
            # Roll back the bundle only; user files/keychain are never reset.
            if destination.exists():
                destination.rename(self.cache / f'failed-{int(time.time())}.app')
            if existed:
                backup.rename(destination)
                self.run(['open', destination])
            raise
        self.result['verification'] = 'signature, team, bundle ID, version, running process'

    def android_settings(self):
        path = Path(getattr(self.args, 'config', Path.home() / '.config/lanlink/deploy.json')).expanduser()
        if not path.exists():
            return path, {}
        try:
            data = json.loads(path.read_text())
            if not isinstance(data, dict):
                raise ValueError('El archivo debe contener un objeto JSON.')
            android = data.get('android', {})
            if not isinstance(android, dict) or any(not isinstance(android[key], str) for key in ('serial', 'address') if key in android):
                raise ValueError('La configuración Android debe contener identidad y dirección como texto.')
            return path, data
        except (ValueError, OSError) as error:
            raise DeploymentError(f'No se puede leer la configuración {path}: {error}') from error

    def remember_android(self, address, serial):
        path, settings = self.android_settings()
        android = settings.setdefault('android', {})
        android['serial'] = serial
        if valid_address(address):
            android['address'] = address
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(settings, indent=2))
        temporary.chmod(0o600)
        temporary.replace(path)
        self.say(f'Identidad y dirección Android guardadas en {path}')

    def android_device(self):
        _, settings = self.android_settings()
        saved = settings.get('android', {})
        expected = getattr(self.args, 'android_serial', None) or saved.get('serial')
        self.run(['adb', 'start-server'])

        def verify(address):
            self.run(['adb', 'connect', address], timeout=15)
            if self.run(['adb', '-s', address, 'get-state'], timeout=15).strip() != 'device':
                raise DeploymentError('Android todavía no autorizó este Mac.')
            serial = self.run(['adb', '-s', address, 'shell', 'getprop', 'ro.serialno'], timeout=15).strip()
            if not serial or (expected and serial != expected):
                raise DeploymentError('La identidad Android no coincide con el teléfono configurado.')
            self.remember_android(address, serial)
            return address

        if self.args.android:
            if not valid_address(self.args.android):
                raise DeploymentError('Usá una dirección IP:puerto válida.')
            return verify(self.args.android)
        try:
            services = self.run(['adb', 'mdns', 'services'])
            for line in services.splitlines():
                address = line.split()[-1] if line.split() else ''
                if '_adb-tls-connect._tcp' in line and valid_address(address):
                    try:
                        self.run(['adb', 'connect', address], timeout=10)
                    except DeploymentError:
                        pass
        except DeploymentError:
            self.say('Descubrimiento automático no disponible; se probará la dirección guardada.')
        devices = [line.split()[0] for line in self.run(['adb', 'devices']).splitlines()[1:]
                   if len(line.split()) > 1 and line.split()[1] == 'device']
        unique = {}
        for device in devices:
            try:
                serial = self.run(['adb', '-s', device, 'shell', 'getprop', 'ro.serialno'], timeout=10).strip()
                if serial and (not expected or serial == expected):
                    unique.setdefault(serial, device)
            except DeploymentError:
                pass  # A stale mDNS transport cannot hide a working connection.
        if len(unique) == 1:
            serial, device = next(iter(unique.items()))
            self.remember_android(device, serial)
            return device
        if saved.get('address') and valid_address(saved['address']):
            try:
                return verify(saved['address'])
            except DeploymentError:
                self.say('La dirección guardada ya no responde o no coincide con el teléfono.')
        if self.args.non_interactive or not sys.stdin.isatty():
            raise DeploymentError('No se detectó el Android configurado. Usá --android IP:puerto o ejecutá en Terminal para ingresar y guardar la dirección.')
        with PROMPT_LOCK:
            address = input('\n[android] En Depuración inalámbrica mirá Dirección IP y puerto.\nIngresá IP:puerto, Enter para esperar o s para saltear: ').strip()
        if address.lower() == 's':
            raise Skipped('Android saltado por el usuario.')
        if not address:
            raise RetryLater('Esperando descubrimiento Android.')
        if not valid_address(address):
            raise DeploymentError('Dirección inválida. Ejemplo: 192.168.1.134:40321')
        return verify(address)

    def android(self):
        artifact = self.ci_artifact('android-release.yml', 'LanLink-Android-prueba-firmada', 'app-release.apk')
        if getattr(self.args, 'build_only', False):
            self.result.update(artifact=str(artifact), verification='artifact commit and SHA256; not installed')
            return
        device = self.wait(self.android_device, 'Activá Depuración inalámbrica y autorizá este Mac. Podés saltear Android.')
        expected_serial = self.run(['adb', '-s', device, 'shell', 'getprop', 'ro.serialno']).strip()
        def install():
            current = self.android_device()
            if self.run(['adb', '-s', current, 'shell', 'getprop', 'ro.serialno']).strip() != expected_serial:
                raise DeploymentError('El Android conectado no es el dispositivo elegido inicialmente.')
            self.run(['adb', '-s', current, 'install', '-r', artifact], timeout=600)
            return current
        device = self.wait(install, 'Mantené Android conectado y desbloqueado. Una firma incompatible requiere revisión manual; no se desinstala la app.')
        package = self.run(['adb', '-s', device, 'shell', 'dumpsys', 'package', 'com.example.lanlink'])
        if f'versionName={self.version}' not in package or not re.search(rf'versionCode={self.build}(?:\s|$)', package):
            raise DeploymentError('La versión instalada de Android no coincide.')
        self.run(['adb', '-s', device, 'shell', 'am', 'start', '-n', 'com.example.lanlink/.MainActivity'])
        self.wait(lambda: self.require_output(['adb', '-s', device, 'shell', 'pidof', 'com.example.lanlink']),
                  'Abrí LanLink en Android para verificar su proceso.')
        self.result['verification'] = 'install -r, package version/build, running process'

    def require_output(self, command):
        text = self.run(command, timeout=45)
        if not text.strip():
            raise DeploymentError('No se encontró el proceso esperado.')
        return text

    def windows(self):
        artifact = self.ci_artifact('windows-installer.yml', 'LanLink-Windows-x64-Setup', 'LanLink-Windows-x64-Setup.exe')
        if getattr(self.args, 'build_only', False):
            self.result.update(artifact=str(artifact), verification='artifact commit and SHA256; not installed')
            return
        vm = self.args.vm
        if not vm:
            rows = json.loads(self.run(['prlctl', 'list', '-a', '-j']))
            running = [row for row in rows if row.get('status') == 'running' and 'Windows' in row.get('name', '')]
            if len(running) != 1:
                raise DeploymentError('Iniciá la VM Windows o indicá --vm NOMBRE.')
            vm = running[0]['name']
        # The only shared path assumption is the configured Parallels Home share.
        shared = self.args.windows_share.rstrip('\\') + '\\' + str(artifact.relative_to(Path.home())).replace('/', '\\')
        script = f'''$ErrorActionPreference='Stop';
$p=Join-Path $env:TEMP 'LanLink-Setup.exe';
Copy-Item -LiteralPath {quote_ps(shared)} -Destination $p -Force;
if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne {quote_ps(digest(artifact))}) {{ throw 'Checksum del instalador incorrecto' }};
Get-Process lanlink -ErrorAction SilentlyContinue | Stop-Process;
$r=Start-Process -FilePath $p -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru;
if ($r.ExitCode -ne 0) {{ throw ('Instalador: '+$r.ExitCode) }};
$app=Join-Path $env:LOCALAPPDATA 'Programs\\LanLink\\lanlink.exe';
if ((Get-Item $app).VersionInfo.FileVersion -ne {quote_ps(self.version+'+'+str(self.build))}) {{ throw 'Version incorrecta' }};
Start-Process -FilePath $app; Start-Sleep -Seconds 5;
if (-not (Get-Process lanlink -ErrorAction SilentlyContinue)) {{ throw 'La app no está ejecutándose' }};
try {{ Invoke-WebRequest 'http://127.0.0.1:47829/' -UseBasicParsing -TimeoutSec 10 | Out-Null }}
catch {{ if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 405) {{ throw }} }};
Write-Output 'LANLINK_VERIFIED';'''
        encoded = base64.b64encode(script.encode('utf-16-le')).decode()
        output = self.wait(lambda: self.run(['prlctl', 'exec', vm, '--current-user', 'powershell.exe',
            '-NoProfile', '-EncodedCommand', encoded], timeout=600), 'Desbloqueá Windows y verificá que Parallels comparta la carpeta Home.')
        if 'LANLINK_VERIFIED' not in output:
            raise DeploymentError('Windows no confirmó las verificaciones.')
        self.result['verification'] = 'installer checksum, exit code, version/build, process, HTTP service'

    def ios_device(self):
        if self.args.ios:
            return self.args.ios
        result = self.json_command(['xcrun', 'devicectl', 'list', 'devices'])
        devices = [device for device in result['devices']
                   if device.get('hardwareProperties', {}).get('reality') == 'physical']
        if len(devices) != 1:
            raise DeploymentError('Conectá un iPhone único o indicá --ios UDID.')
        return devices[0]['hardwareProperties']['udid']

    def ios(self):
        build_only = getattr(self.args, 'build_only', False)
        device = self.args.ios if build_only else self.wait(self.ios_device, 'Conectá el iPhone por USB o Wi-Fi y mantenelo desbloqueado.')
        _, team = self.signing()
        source = self.source()
        archive = self.cache / 'LanLink-iOS.zip'
        if archive.exists() and (self.args.rebuild or not self.valid_cache(archive)):
            archive.rename(archive.with_name(f'invalid-{int(time.time())}.zip'))
        if not archive.exists():
            derived = Path(tempfile.mkdtemp(prefix='lanlink-ios-build-'))
            self.run([self.flutter(), 'build', 'ios', '--release', '--config-only'], cwd=source, timeout=600)
            self.run(['xcodebuild', '-workspace', 'ios/Runner.xcworkspace', '-scheme', 'Runner',
                '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
                '-derivedDataPath', derived, f'DEVELOPMENT_TEAM={team}', 'CODE_SIGN_STYLE=Automatic',
                '-allowProvisioningUpdates', 'build', '-quiet'], cwd=source, timeout=self.args.build_timeout)
            built = derived / 'Build/Products/Release-iphoneos/Runner.app'
            self.run(['xattr', '-cr', built])
            self.run(['codesign', '--verify', '--deep', '--strict', built])
            self.run(['ditto', '-c', '-k', '--keepParent', built, archive])
        stage = Path(tempfile.mkdtemp(prefix='lanlink-ios-install-'))
        self.run(['ditto', '-x', '-k', archive, stage])
        app = stage / 'Runner.app'
        self.run(['codesign', '--verify', '--deep', '--strict', app])
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if (info['CFBundleIdentifier'] != 'com.gteijeiro.lanlink' or info['CFBundleShortVersionString'] != self.version
                or str(info['CFBundleVersion']) != str(self.build)):
            raise DeploymentError('La compilación iOS no tiene la versión esperada.')
        profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', app / 'embedded.mobileprovision']))
        if team not in profile.get('TeamIdentifier', []):
            raise DeploymentError('El perfil iOS pertenece a otro equipo Apple.')
        expiry = profile['ExpirationDate']
        if expiry <= dt.datetime.now(dt.timezone.utc).replace(tzinfo=None):
            raise DeploymentError('El perfil iOS venció. Eliminá solo la caché iOS de esta revisión y recompilá con un perfil renovado.')
        if device and device not in profile.get('ProvisionedDevices', []):
            raise DeploymentError('Este iPhone no está incluido en el perfil de firma.')
        self.result['profile_expires_utc'] = expiry.isoformat() + 'Z'
        self.manifest(archive, profile_expires_utc=expiry.isoformat() + 'Z')
        if build_only:
            self.result.update(artifact=str(archive), verification='signature, profile expiry/team, bundle version; not installed')
            shutil.rmtree(stage)
            return
        self.wait(lambda: self.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, app], timeout=180),
                  'Desbloqueá el iPhone y mantené la pantalla encendida; se reintentará la instalación.')
        self.wait(lambda: self.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device,
            'com.gteijeiro.lanlink'], timeout=90),
            'Abrí LanLink. Si iOS pide confianza, verificala en Ajustes > General > VPN y gestión de dispositivos; luego reintentá.')
        installed = self.json_command(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', device])
        apps = installed.get('apps', [])
        found = next((row for row in apps if row.get('bundleIdentifier') == 'com.gteijeiro.lanlink'), None)
        if not found or found.get('version') != self.version or str(found.get('bundleVersion')) != str(self.build):
            raise DeploymentError('No se pudo confirmar la versión de iPhone en el inventario instalado.')
        self.result['verification'] = 'signature, profile expiry/device, version, installation, launch'

    def execute(self):
        self.say(f'Inicio: {self.version}+{self.build}, commit {self.head}')
        try:
            getattr(self, self.name)()
            self.result['status'] = 'prepared' if getattr(self.args, 'build_only', False) else 'verified'
            self.say('PREPARADO SIN INSTALAR' if getattr(self.args, 'build_only', False) else 'VERIFICADO')
        except Skipped as error:
            self.result.update(status='skipped', error=str(error))
            self.say('SALTADO: ' + str(error))
        except Exception as error:
            self.result.update(status='failed', error=str(error))
            self.say('FALLÓ: ' + str(error))
        finally:
            (self.logs / f'{self.name}.json').write_text(json.dumps(self.result, indent=2))
        return self.result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--devices', default='macos,windows,android,ios')
    parser.add_argument('--non-interactive', action='store_true')
    parser.add_argument('--wait-timeout', type=int, default=900)
    parser.add_argument('--build-timeout', type=int, default=2400)
    parser.add_argument('--flutter')
    parser.add_argument('--identity')
    parser.add_argument('--team')
    parser.add_argument('--config', default=str(Path.home() / '.config/lanlink/deploy.json'), help='Configuración privada guardada fuera del repositorio')
    parser.add_argument('--android-serial', help='Identidad esperada; permite seleccionar otro teléfono explícitamente')
    parser.add_argument('--android', help='IP:puerto de depuración ya vinculada')
    parser.add_argument('--ios', help='UDID del iPhone')
    parser.add_argument('--vm', help='Nombre de la VM Parallels')
    parser.add_argument('--windows-share', default=r'\\Mac\Home')
    parser.add_argument('--mac-app', default=str(Path.home() / 'Applications/LanLink.app'))
    parser.add_argument('--ref', default='main', help='Ref de GitHub que contiene HEAD')
    parser.add_argument('--rebuild', action='store_true', help='Recompilar los paquetes locales macOS/iOS aunque estén en caché')
    parser.add_argument('--build-only', action='store_true', help='Compilar y verificar paquetes sin conectar ni instalar en los dispositivos')
    parser.add_argument('--plan', action='store_true', help='Mostrar alcance sin compilar ni instalar')
    args = parser.parse_args()
    devices = list(dict.fromkeys(args.devices.split(',')))
    if any(device not in ('macos', 'windows', 'android', 'ios') for device in devices):
        parser.error('Dispositivos válidos: macos,windows,android,ios')
    version, build = re.search(r'^version:\s*([^+\s]+)\+(\d+)', (ROOT / 'pubspec.yaml').read_text(), re.M).groups()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if args.plan:
        print(json.dumps({'commit': head, 'version': version, 'build': int(build), 'devices': devices}, indent=2))
        return 0
    if sys.platform != 'darwin':
        parser.error('Este orquestador se ejecuta desde el Mac con Xcode y Parallels.')
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip():
        parser.error('Guardá los cambios en un commit antes de desplegar; los artefactos deben corresponder exactamente a HEAD.')
    lock_path = ROOT / 'build/deploy/deploy.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    deployment_lock = lock_path.open('a')
    try:
        fcntl.flock(deployment_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error('Ya hay otro despliegue en ejecución. Revisá sus logs antes de iniciar otro.')
    stamp = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    logs = ROOT / 'build/deploy/logs' / stamp
    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    cache = ROOT / 'build/deploy/cache' / head
    print(f'Logs: {logs}', flush=True)
    targets = [Target(device, args, head, version, int(build), logs, cache) for device in devices]
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(targets)) as pool:
        results = list(pool.map(lambda target: target.execute(), targets))
    (logs / 'summary.json').write_text(json.dumps(results, indent=2))
    print('\n' + '\n'.join(f'{row["target"]}: {row["status"]} — {row["log"]}' for row in results))
    return 1 if any(row['status'] == 'failed' for row in results) else 2 if any(row['status'] == 'skipped' for row in results) else 0


if __name__ == '__main__':
    sys.exit(main())
