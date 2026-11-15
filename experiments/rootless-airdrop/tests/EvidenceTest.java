import com.example.lanlink.airdropprobe.AirDropEvidence;
public final class EvidenceTest {
    public static void main(String[] args) {
        if (AirDropEvidence.containsAirDropRecord(null)) throw new AssertionError("null");
        if (AirDropEvidence.containsAirDropRecord(new byte[]{5,18,0})) throw new AssertionError("truncated");
        byte[] valid = new byte[20]; valid[0]=5; valid[1]=18;
        if (!AirDropEvidence.containsAirDropRecord(valid)) throw new AssertionError("valid");
        byte[] unknown = new byte[23]; unknown[0]=16; unknown[1]=1; System.arraycopy(valid,0,unknown,3,20);
        if (!AirDropEvidence.containsAirDropRecord(unknown)) throw new AssertionError("multiple records");
        if (!AirDropEvidence.assess(false,false).equals("NO_ROOTLESS_AWDL_LINK_EXPOSED")) throw new AssertionError("blocked");
        if (AirDropEvidence.assess(true,false).contains("SUCCESS")) throw new AssertionError("interface is not a transfer");
        if (AirDropEvidence.assess(false,true).contains("SUCCESS")) throw new AssertionError("raw socket is not a transfer");
        System.out.println("7 rootless evidence tests passed");
    }
}
