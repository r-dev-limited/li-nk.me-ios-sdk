import SwiftUI
import LinkMeKit

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Profile")
                    .font(.largeTitle)
                    .bold()
                
                LinkInfoCard(payload: appState.lastPayload)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Navigation Test")
                        .font(.headline)
                    
                    Text("This screen can be opened via LinkMe deep links with path 'profile'")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("Track: 'profile_viewed'") {
                        LinkMe.shared.track(event: "profile_viewed")
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
                    NavigationLink(value: "settings") {
                        Text("Go to Settings")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    NavigationLink(destination: SettingsView()) {
                        Text("Go to Settings")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: 1))
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Profile")
    }
}

