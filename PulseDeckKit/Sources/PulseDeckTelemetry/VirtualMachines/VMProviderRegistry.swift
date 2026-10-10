#if os(macOS)

/// Every VM provider PulseDeck knows, in the order they are listed in the UI. Each adapter is a
/// thin struct (`<Name>VMAdapter`) next to this file; the logic lives in `PulseDeckCore`.
public enum VMProviderRegistry {
    public static let all: [any VMProviderAdapter] = [
        // Container-oriented Lima family and shared VMs.
        ColimaVMAdapter(),
        LimaVMAdapter(),
        FinchVMAdapter(),
        RancherDesktopVMAdapter(),
        OrbStackVMAdapter(),
        DockerDesktopVMAdapter(),
        // General-purpose hypervisors.
        TartVMAdapter(),
        UTMVMAdapter(),
        ParallelsVMAdapter(),
        VMwareFusionVMAdapter(),
        VirtualBoxVMAdapter(),
        AnkaVMAdapter(),
        // Developer VM managers.
        MultipassVMAdapter(),
        PodmanVMAdapter(),
        MinikubeVMAdapter(),
        VagrantVMAdapter(),
        QEMUVMAdapter(),
    ]
}
#endif
