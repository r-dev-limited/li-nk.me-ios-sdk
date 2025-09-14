import SwiftUI
import LinkMeKit
import AppTrackingTransparency

struct ContentView: View {
    @State private var lastPayload: String = "(none)"
    @State private var status: String = "Not initialized"
    @State private var subscribed: Bool = false
    @State private var attStatus: String = "unknown"
    @State private var baseUrlUsed: String = ""
    @State private var unsub: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Text("LinkMeKit Example")
                .font(.title2)
            Text("Status: \(status)")
                .font(.footnote)
            Text("ATT: \(attStatus)")
                .font(.footnote)
            Text("Base URL: \(baseUrlUsed.isEmpty ? "(none)" : baseUrlUsed)")
                .font(.footnote)
            Text("Last payload: \(lastPayload)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if #available(iOS 15.0, *) {
                Button(subscribed ? "Reinitialize" : "Initialize & Request Tracking") {
                    initializeFlow()
                }
                .buttonStyle(.borderedProminent)
            } else {
                // Fallback on earlier versions
            }
        }
        .onAppear {
            // Allow registering listener before SDK configure; queue will flush later
            if unsub == nil {
                unsub = LinkMe.shared.addListener { payload in
                    DispatchQueue.main.async {
                        lastPayload = "linkId=\(payload.linkId ?? "nil") utm=\(payload.utm ?? [:])"
                        status = "Received payload"
                    }
                    print("[LinkMe Example] listener payload=\(payload)")
                }
            }
        }
        .onOpenURL { url in
            print("[LinkMe Example] onOpenURL url=\(url.absoluteString)")
            _ = LinkMe.shared.handle(url: url)
        }
        .padding()
    }

    private func initializeFlow() {
        status = "Requesting ATT..."
        if #available(iOS 14, *) {
            ATTrackingManager.requestTrackingAuthorization { authStatus in
                let granted = (authStatus == .authorized)
                DispatchQueue.main.async {
                    switch authStatus {
                    case .authorized: attStatus = "authorized"
                    case .denied: attStatus = "denied"
                    case .restricted: attStatus = "restricted"
                    case .notDetermined: attStatus = "notDetermined"
                    @unknown default: attStatus = "unknown"
                    }
                }
                continueInit(advertisingGranted: granted)
            }
        } else {
            attStatus = "unavailable"
            continueInit(advertisingGranted: false)
        }
    }

    private func continueInit(advertisingGranted: Bool) {
        // Respect consent for advertising id
        LinkMe.shared.setAdvertisingConsent(advertisingGranted)
        // Resolve base URL via env var or Info.plist
        let env = ProcessInfo.processInfo.environment["LINKME_BASE_URL"]
        let info = (Bundle.main.object(forInfoDictionaryKey: "LinkMeBaseURL") as? String)
        let base = (env?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? env : info) ?? "http://localhost:8080"
        baseUrlUsed = base
        guard let url = URL(string: base) else {
            status = "Invalid base URL"
            return
        }
        print("[LinkMe Example] Configuring LinkMe baseUrl=\(url.absoluteString) consent.ad=\(advertisingGranted)")
        LinkMe.shared.configure(config: .init(
            baseUrl: url,
            appId: "demo",
            appKey: "LKDEMO-0001-TESTKEY-LOCAL",
            enablePasteboard: false
        ))
        subscribed = true
        status = "Configured"
        // Observe initial payload (if any) and attempt deferred claim
        LinkMe.shared.getInitialLink { payload in
            print("[LinkMe Example] getInitialLink payload=\(String(describing: payload))")
            if let p = payload {
                DispatchQueue.main.async {
                    lastPayload = "linkId=\(p.linkId ?? "nil") utm=\(p.utm ?? [:])"
                }
            }
        }
        LinkMe.shared.claimDeferredIfAvailable { payload in
            print("[LinkMe Example] claimDeferredIfAvailable payload=\(String(describing: payload))")
        }
    }
}

#Preview {
    ContentView()
}
