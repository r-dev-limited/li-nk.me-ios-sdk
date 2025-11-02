import SwiftUI
import LinkMeKit
import AppTrackingTransparency

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var attStatusText: String = "Unknown"
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Settings")
                    .font(.largeTitle)
                    .bold()
                
                LinkInfoCard(payload: appState.lastPayload)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("LinkMe Configuration")
                        .font(.headline)
                    
                    HStack {
                        Text("Base URL:")
                        Spacer()
                        Text("https://0jk2u2h9.li-nk.me")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("App ID:")
                        Spacer()
                        Text("0jk2u2h9")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("ATT Status:")
                        Spacer()
                        Text(attStatusText)
                            .foregroundColor(.secondary)
                    }
                    
                    if #available(iOS 14, *) {
                        Button("Request ATT Permission") {
                            ATTrackingManager.requestTrackingAuthorization { status in
                                DispatchQueue.main.async {
                                    let granted = (status == .authorized)
                                    LinkMe.shared.setAdvertisingConsent(granted)
                                    appState.attStatus = status
                                    updateATTStatus(status)
                                }
                            }
                        }
                        .modifier(ButtonStyleModifier())
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Testing")
                        .font(.headline)
                    
                    Button("Track: 'settings_viewed'") {
                        LinkMe.shared.track(event: "settings_viewed")
                    }
                    .modifier(ButtonStyleModifier())
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                
                if #available(iOS 16, *) {
                    NavigationLink(value: "index") {
                        Text("Go to Home")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    NavigationLink(destination: HomeView()) {
                        Text("Go to Home")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                
                if #available(iOS 16, *) {
                    NavigationLink(value: "profile") {
                        Text("Go to Profile")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    NavigationLink(destination: ProfileView()) {
                        Text("Go to Profile")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: 1))
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Settings")
        .onAppear {
            updateATTStatus(appState.attStatus)
        }
    }
    
    @available(iOS 14, *)
    private func updateATTStatus(_ status: ATTrackingManager.AuthorizationStatus) {
        switch status {
        case .authorized:
            attStatusText = "Authorized"
        case .denied:
            attStatusText = "Denied"
        case .restricted:
            attStatusText = "Restricted"
        case .notDetermined:
            attStatusText = "Not Determined"
        @unknown default:
            attStatusText = "Unknown"
        }
    }
}

