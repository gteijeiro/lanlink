package com.example.lanlink.airdropprobe;

/** Wire evidence only. BLE presence and Wi-Fi Aware are not AirDrop data links. */
public final class AirDropEvidence {
    private AirDropEvidence() {}
    /** TLV headers only: values can contain contact hashes and are never returned. */
    public static String recordShape(byte[] data) {
        if (data == null || data.length == 0) return "empty";
        StringBuilder result = new StringBuilder();
        for (int i = 0; i < data.length;) {
            if (result.length() > 0) result.append(',');
            if (i + 2 > data.length) { result.append("truncated-header"); break; }
            int type = data[i++] & 255, length = data[i++] & 255;
            result.append(String.format(java.util.Locale.ROOT, "%02x:%d", type, length));
            if (i + length > data.length) { result.append("(truncated)"); break; }
            i += length;
        }
        return result.toString();
    }
    public static boolean containsAirDropRecord(byte[] manufacturerData) {
        if (manufacturerData == null) return false;
        for (int i = 0; i + 2 <= manufacturerData.length;) {
            int type = manufacturerData[i++] & 255;
            int length = manufacturerData[i++] & 255;
            if (i + length > manufacturerData.length) return false;
            if (type == 0x05 && length == 0x12) return true;
            i += length;
        }
        return false;
    }
    public static String assess(boolean activeAwDlInterface, boolean rawSocketAllowed) {
        if (activeAwDlInterface) return "LINK_CANDIDATE_ONLY_TRANSFER_NOT_VERIFIED";
        if (rawSocketAllowed) return "RAW_RADIO_EXPERIMENT_REQUIRED_TRANSFER_NOT_VERIFIED";
        return "NO_ROOTLESS_AWDL_LINK_EXPOSED";
    }
}
