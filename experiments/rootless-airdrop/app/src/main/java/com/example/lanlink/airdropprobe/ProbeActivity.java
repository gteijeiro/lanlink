package com.example.lanlink.airdropprobe;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.*;
import android.content.Context;
import android.content.pm.PackageManager;
import android.net.nsd.*;
import android.net.wifi.aware.WifiAwareManager;
import android.os.*;
import android.system.ErrnoException;
import android.system.Os;
import android.view.WindowManager;
import android.widget.*;
import org.json.*;
import java.io.*;
import java.net.*;
import java.util.*;

/** Runs in an ordinary application UID, without su, shell grants or system helpers. */
public final class ProbeActivity extends Activity {
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Object lock = new Object();
    private JSONObject report;
    private TextView output;
    private BluetoothLeScanner scanner;
    private NsdManager nsd;
    private NsdManager.DiscoveryListener discovery;
    private boolean scanning;
    private int appleFrames, airDropFrames, serviceCount;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout body = new LinearLayout(this); body.setOrientation(LinearLayout.VERTICAL); body.setPadding(28, 36, 28, 28);
        TextView title = new TextView(this); title.setText("LanLink · prueba AirDrop sin root"); title.setTextSize(22); body.addView(title);
        TextView note = new TextView(this); note.setText("Prototipo de descubrimiento y acceso al transporte. No anuncia un receptor falso ni declara una transferencia exitosa. No cambia la configuración Wi-Fi."); body.addView(note);
        Button run = new Button(this); run.setText("Comprobar y buscar durante 15 segundos"); run.setOnClickListener(v -> startScan()); body.addView(run);
        output = new TextView(this); output.setTextSize(12); output.setTextIsSelectable(true);
        ScrollView scroll = new ScrollView(this); scroll.addView(output); body.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        setContentView(body);
        new Thread(() -> {
            inspectAccess();
            ui.post(() -> { render(); if (getIntent().getBooleanExtra("scan", false)) startScan(); });
        }, "rootless-access-probe").start();
    }

    private void inspectAccess() {
        synchronized (lock) {
            report = new JSONObject();
            try {
                report.put("model", Build.MODEL); report.put("api", Build.VERSION.SDK_INT);
                report.put("testedAtEpochMs", System.currentTimeMillis());
                report.put("scope", "PUBLIC_API_AND_RAW_SOCKET_ACCESS_PREFLIGHT_ONLY");
                report.put("appUid", android.os.Process.myUid());
                report.put("normalAppUid", android.os.Process.myUid() >= 10000);
                PackageManager pm = getPackageManager();
                JSONObject packages = new JSONObject();
                for (String name : new String[]{"com.google.android.mosey", "com.samsung.android.app.sharelive"}) {
                    try {
                        android.content.pm.PackageInfo info = pm.getPackageInfo(name, 0);
                        packages.put(name, info.versionName);
                    } catch (PackageManager.NameNotFoundException absent) { packages.put(name, "NOT_INSTALLED"); }
                }
                report.put("systemBackends", packages);
                report.put("wifiDirectFeature", pm.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT));
                report.put("wifiAwareFeature", pm.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE));
                WifiAwareManager aware = (WifiAwareManager)getSystemService(Context.WIFI_AWARE_SERVICE);
                report.put("wifiAwareServiceAvailable", aware != null && aware.isAvailable());
                JSONArray interfaces = new JSONArray(); boolean activeAwDl = false;
                Enumeration<NetworkInterface> all = NetworkInterface.getNetworkInterfaces();
                while (all != null && all.hasMoreElements()) {
                    NetworkInterface net = all.nextElement(); String name = net.getName();
                    if (!name.matches("(?i).*(awdl|mosey|wonder|aware|nan|wlan|p2p).*")) continue;
                    boolean ipv6 = Collections.list(net.getInetAddresses()).stream().anyMatch(a -> a instanceof Inet6Address && a.isLinkLocalAddress());
                    JSONObject item = new JSONObject(); item.put("name", name); item.put("up", net.isUp()); item.put("linkLocalIpv6", ipv6); interfaces.put(item);
                    // An interface merely named wifi-aware is not evidence of AWDL.
                    if (name.matches("(?i).*(awdl|mosey).*")) activeAwDl |= net.isUp() && ipv6;
                }
                report.put("interfaces", interfaces); report.put("activeAwDlCandidate", activeAwDl);
                boolean rawAllowed = false;
                try {
                    // AF_PACKET=17, SOCK_RAW=3, htons(ETH_P_ALL)=0x0300.
                    // Open then close only: no frames are received or injected.
                    FileDescriptor fd = Os.socket(17, 3, 0x0300);
                    try { rawAllowed = true; } finally { Os.close(fd); }
                    report.put("rawSocket", "ALLOWED");
                } catch (ErrnoException error) {
                    report.put("rawSocket", "DENIED"); report.put("rawSocketErrno", error.errno);
                    report.put("rawSocketError", Os.strerror(error.errno));
                }
                report.put("assessment", AirDropEvidence.assess(activeAwDl, rawAllowed));
                report.put("airDropTransfer", "NOT_RUN_NO_VERIFIED_COMPATIBLE_LINK");
                String[] privileged = {"android.permission.NETWORK_SETTINGS", "android.permission.NETWORK_STACK", "android.permission.MANAGE_WIFI_INTERFACES", "com.samsung.android.sharelive.permission.REQUEST_CANCEL_AWDL"};
                JSONObject grants = new JSONObject();
                for (String permission : privileged) grants.put(permission, checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED);
                report.put("systemPermissions", grants);
            } catch (Exception error) { put("inspectionError", error.getClass().getSimpleName()+": "+error.getMessage()); }
            persist();
        }
    }

    private void startScan() {
        if (report == null || scanning) return;
        String[] permissions = Build.VERSION.SDK_INT >= 31 ? new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT} : new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
        for (String permission : permissions) if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(permissions, 51); return;
        }
        scanning = true; appleFrames = airDropFrames = serviceCount = 0;
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        put("scanState", "SCANNING");
        try {
            BluetoothManager manager = getSystemService(BluetoothManager.class);
            BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
            if (adapter == null || !adapter.isEnabled()) throw new IllegalStateException("Bluetooth apagado o no disponible");
            scanner = adapter.getBluetoothLeScanner();
            scanner.startScan(Collections.singletonList(new ScanFilter.Builder().setManufacturerData(0x004c, new byte[0]).build()), new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), bleCallback);
        } catch (Exception error) { put("bleError", error.getClass().getSimpleName()+": "+error.getMessage()); }
        try {
            nsd = getSystemService(NsdManager.class);
            discovery = new NsdManager.DiscoveryListener() {
                public void onDiscoveryStarted(String type) { put("mdnsStarted", true); }
                public void onStartDiscoveryFailed(String type, int code) { put("mdnsStartError", code); }
                public void onStopDiscoveryFailed(String type, int code) { put("mdnsStopError", code); }
                public void onDiscoveryStopped(String type) {}
                public void onServiceFound(NsdServiceInfo service) { synchronized(lock) { serviceCount++; } }
                public void onServiceLost(NsdServiceInfo service) {}
            };
            nsd.discoverServices("_airdrop._tcp.", NsdManager.PROTOCOL_DNS_SD, discovery);
        } catch (Exception error) { put("mdnsError", error.getClass().getSimpleName()+": "+error.getMessage()); }
        render(); ui.postDelayed(this::finishScan, 15000);
    }

    private final ScanCallback bleCallback = new ScanCallback() {
        @Override public void onScanResult(int type, ScanResult result) {
            ScanRecord record = result.getScanRecord(); if (record == null) return;
            byte[] bytes = record.getManufacturerSpecificData(0x004c); if (bytes == null) return;
            synchronized (lock) { appleFrames++; if (AirDropEvidence.containsAirDropRecord(bytes)) airDropFrames++; }
        }
        @Override public void onScanFailed(int code) { put("bleScanError", code); }
    };

    private void finishScan() {
        if (!scanning) return; scanning = false;
        try { if (scanner != null) scanner.stopScan(bleCallback); } catch (Exception ignored) {}
        try { if (nsd != null && discovery != null) nsd.stopServiceDiscovery(discovery); } catch (Exception ignored) {}
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        synchronized (lock) {
            put("appleAdvertisementCount", appleFrames); put("airDropAdvertisementCount", airDropFrames);
            put("airDropMdnsServiceCount", serviceCount); put("scanState", "FINISHED"); persist();
        }
        render();
    }
    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code == 51 && Arrays.stream(results).allMatch(value -> value == PackageManager.PERMISSION_GRANTED)) startScan();
    }
    private void put(String key, Object value) { synchronized (lock) { if (report != null) try { report.put(key, value); } catch (JSONException ignored) {} } }
    private void persist() {
        try (FileOutputStream file = openFileOutput("report.json", MODE_PRIVATE)) { file.write(report.toString(2).getBytes(java.nio.charset.StandardCharsets.UTF_8)); }
        catch (Exception ignored) {}
    }
    private void render() { synchronized (lock) { try { output.setText(report.toString(2)); } catch (JSONException ignored) {} } }
    @Override protected void onDestroy() { ui.removeCallbacksAndMessages(null); finishScan(); super.onDestroy(); }
}
