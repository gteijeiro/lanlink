package com.example.lanlink.airdropprobe;

/** Wire evidence only. BLE presence and Wi-Fi Aware are not AirDrop data links. */
public final class AirDropEvidence {
    private AirDropEvidence() {}
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
