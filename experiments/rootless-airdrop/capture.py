#!/usr/bin/env python3
"""Bounded BLE header capture from our diagnostic APK, never from other apps."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time

PACKAGE = "com.example.lanlink.airdropprobe"
REPO = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description="Captura limitada de anuncios Apple desde LanLink AirDrop Lab.")
    parser.add_argument("--serial", required=True, help="Identificador de adb devices; no se incluye en el informe.")
    parser.add_argument("--phase", choices=("baseline", "airdrop_sender"), required=True)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if not 10 <= args.seconds <= 120:
        parser.error("--seconds debe estar entre 10 y 120")

    def adb(*parts, timeout=15):
        result = subprocess.run(["adb", "-s", args.serial, *parts], capture_output=True,
                                text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "ADB falló")
        return result.stdout

    try:
        if adb("get-state").strip() != "device":
            raise RuntimeError("El teléfono debe estar conectado y autorizado.")
        package = adb("shell", "dumpsys", "package", PACKAGE)
        if "versionName=0.2-experimental" not in package:
            raise RuntimeError("Instalá LanLink AirDrop Lab 0.2 antes de iniciar la captura.")
        adb("shell", "am", "force-stop", PACKAGE)
        started_ms = int(time.time() * 1000)
        launch = adb("shell", "am", "start", "-W", "-n", PACKAGE + "/.ProbeActivity",
                     "--ez", "scan", "true", "--ei", "seconds", str(args.seconds),
                     "--es", "phase", args.phase)
        if "Error:" in launch or "Status: ok" not in launch:
            raise RuntimeError("No se pudo abrir la app de diagnóstico: " + launch.strip())
        print(f"Escuchando {args.seconds} segundos ({args.phase})…", flush=True)
        deadline = time.monotonic() + args.seconds + 20
        report = None
        while time.monotonic() < deadline:
            try:
                candidate = json.loads(adb("exec-out", "run-as", PACKAGE, "cat", "files/report.json", timeout=5))
                if candidate.get("testedAtEpochMs", 0) >= started_ms - 1000 and candidate.get("capturePhase") == args.phase:
                    report = candidate
                    if report.get("scanState") == "FINISHED":
                        break
            except (RuntimeError, json.JSONDecodeError, subprocess.TimeoutExpired):
                pass
            time.sleep(1)
        if report is None:
            raise RuntimeError("No llegó un informe nuevo; comprobá que el teléfono permita abrir la app.")

        output = args.out or REPO / "build/airdrop-rootless/sessions" / (
            datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + args.phase + ".json")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        summary = {key: report.get(key) for key in (
            "probeVersion", "capturePhase", "scanState", "appleAdvertisementCount",
            "airDropAdvertisementCount", "airDropMdnsServiceCount", "observedPeerCount",
            "bleShapeCounts", "rawSocket", "rawSocketError", "airDropTransfer")}
        print(json.dumps(summary, indent=2))
        print("Informe local:", output)
        if report.get("scanState") != "FINISHED":
            raise RuntimeError("Captura incompleta: informe parcial guardado. Revisá permisos Bluetooth y mantené la app abierta.")
        for error in ("bleError", "bleScanError", "mdnsError", "mdnsStartError", "observationError"):
            if error in report:
                raise RuntimeError(f"La captura terminó con {error}: {report[error]}. Revisá el informe.")
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"No se pudo completar la captura: {error}\n")


if __name__ == "__main__":
    main()
